"""Run the real Swift capture with a controlled clock, without starting a VPN."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

HARNESS = r'''
import Darwin
import Foundation

private var testUptime = 0.0
private enum VPNDiagnostics { static func event(_ message: String) {} }
private enum ConnectionStatus { case connected, connecting, disconnecting, reasserting, disconnected, invalid }
private enum ConnectionMode { case vless, vkTurn }
private struct TestConnection { var status: ConnectionStatus; var connectedDate: Date? = nil }
private struct TestManager { var connection: TestConnection }
private enum FilePath { static var sharedDirectory = FileManager.default.temporaryDirectory }
private struct UIStatus: Encodable {
    let footprintBytes: UInt64 = 41_943_040
    var phase = "combined"
    let error: String?
    let updatedAt: Date
    var failover: TestFailover? = nil
    var health: Bool? = nil
    var healthUpdatedAt: Date? = nil
}
private struct TestFailover: Encodable {
 let mode = "automatic"; let selected = "b2"; let primaryHealth = "down"; let allDown = true
}
private struct TestStats {
    let activeConnections: Int = 30
    let txBytes: Int = 10
    let rxBytes: Int = 20
}
private final class LibboxCommandServer {
 var state = #"{"mode":"automatic","selected":"b2","primaryHealth":"down","allDown":true}"#
 let lock = NSLock()
 var healthy = true
 var probeCount = 0
 var release: DispatchSemaphore?
 let entered = DispatchSemaphore(value: 0)
 func waitForProbe() -> Bool { entered.wait(timeout: .now() + 1) == .success }
 func priorityFailoverStatus(_ error: inout NSError?) -> String { state }
 func probeOutbound(_ tag: String, timeoutMilliseconds: Int32, ret0_: inout ObjCBool) throws {
  precondition(tag == "vk-wg" && timeoutMilliseconds == 5000, "Probe must use the selected transport with a deadline")
  lock.withLock { probeCount += 1 }
  entered.signal()
  if let release { precondition(release.wait(timeout: .now() + 2) == .success) }
  ret0_ = ObjCBool(lock.withLock { healthy })
 }
}
private func LibboxGetVKTurnPrototypeStats(_ id: Int64) -> TestStats? { TestStats() }
'''

CHECKS = r'''
extension PrototypeMemoryCapture {
    func tick(at time: Double, phase: String = "combined") {
        testUptime = time
        setPhase(phase)
        queue.sync { sample() }
    }
    func flushHealth() {
        healthQueue.sync {}
        queue.sync {}
    }
}

func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
private let capture = try PrototypeMemoryCapture(directory: directory, baseline: false, connections: 30)
let statusURL = directory.appendingPathComponent("prototype-status.json")
func status() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: statusURL)) as! [String: Any]
}
func csvTimes() throws -> [Double] {
    let cache = directory.appendingPathComponent("Library/Caches/Prototype")
    let file = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first!
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").dropFirst().map {
        Double($0.split(separator: ",")[0])!
    }
}
func waitForHealth(_ expected: Bool) throws {
    for _ in 0..<200 {
        if try status()["health"] as? Bool == expected { return }
        Thread.sleep(forTimeInterval: 0.005)
    }
    expect(false, "Health result was not published")
}

switch CommandLine.arguments[1] {
case "disconnected_error", "stale", "connected", "all_down", "stale_all_down", "healthy", "unhealthy", "expired_health", "old_session", "future_sample", "future_health":
    let scenario = CommandLine.arguments[1]
    FilePath.sharedDirectory = directory
    var payload = UIStatus(error: scenario == "disconnected_error" ? "Bootstrap failed" : nil,
                           updatedAt: Date(timeIntervalSinceNow: ["stale", "stale_all_down"].contains(scenario) ? -10 : 0))
    if ["all_down", "stale_all_down"].contains(scenario) { payload.failover = TestFailover(); payload.phase = "vless" }
    if ["healthy", "unhealthy", "expired_health", "old_session", "stale", "future_sample", "future_health"].contains(scenario) {
        payload.phase = "vless"
        payload.health = scenario != "unhealthy"
        payload.healthUpdatedAt = Date(timeIntervalSinceNow: scenario == "expired_health" ? -30 : 0)
    }
    if scenario == "future_sample" { payload = UIStatus(error: nil, updatedAt: Date(timeIntervalSinceNow: 10), health: true, healthUpdatedAt: Date()) }
    if scenario == "future_health" { payload.healthUpdatedAt = Date(timeIntervalSinceNow: 10) }
    if scenario == "old_session" { payload.healthUpdatedAt = Date(timeIntervalSinceNow: -2) }
    try JSONEncoder().encode(payload).write(to: statusURL)
    let model = TestModel()
    model.manager = TestManager(connection: TestConnection(status: scenario == "disconnected_error" ? .disconnected : .connected,
                                                         connectedDate: scenario == "old_session" ? Date(timeIntervalSinceNow: -1) : nil))
    await model.refresh()
    if scenario == "all_down" {
        expect(model.status == "Туннель поднят · все выходы недоступны", "All-down presented as connected internet")
    } else if scenario == "stale_all_down" {
        expect(model.status != "Подключено", "Stale status presented as working internet")
    } else if scenario == "healthy" {
        expect(model.status == "Подключено", "Successful outbound check not displayed")
    } else if scenario == "unhealthy" {
        expect(model.status == "Сервер недоступен", "Failed outbound check presented as connected")
    } else if scenario == "expired_health" {
        expect(model.status != "Подключено", "Expired outbound check presented as current")
    } else if ["old_session", "future_sample", "future_health"].contains(scenario) {
        expect(model.status != "Подключено", "Invalid or previous-session health accepted")
    } else if scenario == "disconnected_error" {
        expect(model.footprint == "—", "Disconnected VPN shows memory")
        expect(model.error == "Bootstrap failed", "Disconnected VPN hides startup error")
    } else if scenario == "stale" {
        expect(model.footprint == "—", "Stale status presented as live memory")
        expect(model.status != "Подключено", "Stale sampler kept a successful check alive")
    } else {
        expect(model.footprint == "40.0 МиБ", "Fresh connected memory missing")
        expect(model.status != "Подключено", "Tunnel without a successful check presented as working internet")
    }
case "connecting_failover", "expired_failover", "previous_failover", "disconnected_failover":
    let scenario = CommandLine.arguments[1]
    FilePath.sharedDirectory = directory
    let date = Date(timeIntervalSinceNow: scenario == "expired_failover" ? -10 : scenario == "previous_failover" ? -2 : 0)
    let payload = UIStatus(phase: "vless-startup", error: nil, updatedAt: date, failover: TestFailover())
    try JSONEncoder().encode(payload).write(to: statusURL)
    let model = TestModel()
    model.failoverStatus = try JSONDecoder().decode(PriorityFailoverStatus.self, from: JSONEncoder().encode(TestFailover()))
    model.manager = TestManager(connection: TestConnection(status: scenario == "disconnected_failover" ? .disconnected : .connecting,
        connectedDate: scenario == "previous_failover" ? Date(timeIntervalSinceNow: -1) : nil))
    await model.refresh()
    if scenario == "connecting_failover" {
        expect(model.failoverStatus?.selected == "b2", "Startup failover snapshot not published")
    } else {
        expect(model.failoverStatus == nil, "Stale or disconnected failover status retained")
    }
case "failover":
    let server = LibboxCommandServer()
    capture.setFailoverServer(server)
    capture.tick(at: 0, phase: "vless")
    let failover = try status()["failover"] as? [String: Any]
    expect(failover?["selected"] as? String == "b2", "Missing live selector status")
    expect(failover?["allDown"] as? Bool == true, "All-down hidden by tunnel state")
    capture.setFailoverServer(nil)
    capture.tick(at: 1, phase: "vless")
    expect(try status()["failover"] == nil, "Stopped server retained")
case "health":
    let server = LibboxCommandServer()
    server.release = DispatchSemaphore(value: 0)
    capture.setHealthServer(server)
    capture.tick(at: 0, phase: "vless")
    expect(server.waitForProbe(), "Initial check never started")
    expect(try status()["health"] == nil, "Unchecked transport reported as healthy")
    capture.tick(at: 1, phase: "vless")
    capture.tick(at: 9, phase: "vless")
    expect(server.lock.withLock { server.probeCount } == 1, "Overlapping probes started")
    server.release?.signal()
    try waitForHealth(true)
    expect(try status()["healthUpdatedAt"] is Double, "Health freshness was not recorded")
    server.release = nil
    server.lock.withLock { server.healthy = false }
    capture.tick(at: 20, phase: "vless")
    try waitForHealth(false)
    server.lock.withLock { server.healthy = true }
    capture.tick(at: 40, phase: "vless")
    try waitForHealth(true)
case "health_stop":
    let server = LibboxCommandServer()
    server.release = DispatchSemaphore(value: 0)
    capture.setHealthServer(server)
    capture.tick(at: 0, phase: "vless")
    expect(server.waitForProbe(), "Probe never started")
    let before = ContinuousClock.now
    capture.setHealthServer(nil)
    capture.stop()
    expect(before.duration(to: .now) < .milliseconds(200), "Sampler stop blocked on a network check")
    let saved = try Data(contentsOf: statusURL)
    server.release?.signal()
    capture.flushHealth()
    expect(try Data(contentsOf: statusURL) == saved, "Late healthy result overwrote stopped status")
case "live":
    capture.tick(at: 719)
    capture.tick(at: 721, phase: "after_limit")
    expect(try status()["phase"] as? String == "after_limit", "Live status stopped after 12 minutes")
    expect((try status()["footprintBytes"] as? UInt64 ?? 0) > 0, "No actual footprint recorded")
case "cadence":
    for time in [0.0, 1, 719, 720, 721, 779, 780, 781, 839, 840] { capture.tick(at: time) }
    expect(try csvTimes() == [0, 1, 719, 720, 780, 840], "CSV must switch from seconds to minutes")
case "stop":
    capture.tick(at: 0)
    capture.tick(at: 780)
    testUptime = 781
    capture.stop()
    expect(try status()["phase"] as? String == "stopped", "Stop status was not recorded")
    expect(try csvTimes() == [0, 780, 781], "Final CSV sample missing")
    let saved = try Data(contentsOf: statusURL)
    capture.tick(at: 900)
    expect(try Data(contentsOf: statusURL) == saved, "Sampling continued after stop")
    expect(try csvTimes() == [0, 780, 781], "CSV changed after stop")
default: fatalError("Unknown test")
}
print("PASS")
'''


class CaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        source = (ROOT / 'Extension/PacketTunnelProvider.swift').read_text()
        capture = 'private final class PrototypeMemoryCapture' + source.split(
            'private final class PrototypeMemoryCapture', 1)[1]
        # Replace only the platform clock; execute the production sampler and real I/O.
        capture = capture.replace('ProcessInfo.processInfo.systemUptime', 'testUptime')
        swift = directory / 'main.swift'
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        refresh = '    func refresh() async {' + app.split('    func refresh() async {', 1)[1].rsplit('\n}', 1)[0]
        model = ('private final class TestModel {\n'
                 '    var manager: TestManager?\n    var footprint = "—"\n    var resetting = false\n'
                 '    var connectionMode: ConnectionMode = .vless\n    var failoverStatus: PriorityFailoverStatus?\n'
                 '    var vpnState: ConnectionStatus = .disconnected\n    var connectedAt: Date?\n    var status = "Отключено"\n    var error: String?\n' + refresh + '}\n')
        swift.write_text(HARNESS + capture + model + CHECKS)
        cls.executable = directory / 'capture-tests'
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(directory / 'modules'),
                        str(ROOT / 'Library/Network/PriorityFailoverStatus.swift'), str(swift),
                        '-o', str(cls.executable)], check=True, text=True)

    def run_scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failover_status_uses_existing_sampler_and_releases_server(self):
        self.run_scenario("failover")

    def test_failover_is_visible_during_startup_and_cleared_when_stale(self):
        for scenario in ['connecting_failover', 'expired_failover', 'previous_failover', 'disconnected_failover']:
            with self.subTest(scenario=scenario):
                self.run_scenario(scenario)

    def test_health_checks_publish_failure_and_recovery_without_overlapping(self):
        self.run_scenario('health')

    def test_stop_does_not_wait_for_health_check_or_publish_its_late_result(self):
        self.run_scenario('health_stop')

    def test_all_down_is_distinct_from_tunnel_connected_and_expires(self):
        self.run_scenario("all_down")
        self.run_scenario("stale_all_down")

    def test_live_status_continues_after_twelve_minutes(self):
        self.run_scenario('live')

    def test_csv_switches_to_one_sample_per_minute(self):
        self.run_scenario('cadence')

    def test_stop_records_final_sample_and_ends_updates(self):
        self.run_scenario('stop')

    def test_disconnected_vpn_keeps_startup_error_but_clears_memory(self):
        self.run_scenario('disconnected_error')

    def test_stale_status_is_not_displayed_as_live_memory(self):
        self.run_scenario('stale')

    def test_connected_vpn_displays_fresh_memory(self):
        self.run_scenario('connected')

    def test_connected_requires_a_recent_successful_outbound_check(self):
        for scenario in ['healthy', 'unhealthy', 'expired_health', 'stale', 'old_session', 'future_sample', 'future_health']:
            with self.subTest(scenario=scenario):
                self.run_scenario(scenario)
