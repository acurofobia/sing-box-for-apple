"""Run production VPN startup methods with delayed system preferences and tunnel calls."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_prototype_startup_cancellation import method

ROOT = Path(__file__).resolve().parents[2]

HARNESS = r'''
import Foundation
enum NEVPNStatus: CaseIterable { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
enum PrototypeConnectionMode: String { case vless, vkTurn = "vk-turn" }
enum PrototypeRouting { static func sourceID(_ value: String) -> String { value } }
enum PrototypeSubscriptionError: Error { case notReady, stopBeforeImport, missingConfiguration }
enum AppConfiguration { static let extensionBundleID = "test.extension" }
enum ServiceSetup { static func apply(crashReportSource: String) throws {} }
@MainActor enum VPNDiagnostics {
    static var starts = 0
    static func app(_ message: String) { if message.hasPrefix("user start requested") { starts += 1 } }
    static func applicationError(_ message: String, error: Error) {}
    static func expectStop() {}
}
enum FilePath { static var sharedDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[1]) } }
enum VKTurnConfiguration { static func importLink(_ value: String) throws -> String { value } }
enum VKTurnConfigurationStore {
    static func clear() throws {}
    static func save(_ value: String) throws {}
}
@MainActor final class DeviceAccessStore {
    struct Lock { func close() throws {} }
    var contended = false
    var waiter: CheckedContinuation<Void, Never>?
    func acquireLock() async throws -> Lock {
        if contended { await withCheckedContinuation { waiter = $0 } }
        return Lock()
    }
    func checkWDTTAccessWhileLocked(source: String?) throws {}
}
struct Provisioning: Encodable { var isAvailable = true }
struct Subscription {
    var vlessProvisioning: Provisioning?
    var vlessOutbound: Data? = Data("{}".utf8)
    var vkTurnLink: String?
    var sourceURL: String?
    func validateVLESS() throws {}
}
final class NETunnelProviderProtocol {
    var providerBundleIdentifier: String? = AppConfiguration.extensionBundleID
    var providerConfiguration: [String: Any]?
    var serverAddress: String?
}
@MainActor final class Connection {
    var status = NEVPNStatus.disconnected
    var connectedDate: Date?
    var starts = 0
    func startVPNTunnel() throws { starts += 1; status = .connecting }
    func stopVPNTunnel() { status = .disconnected }
}
@MainActor final class NETunnelProviderManager {
    let connection = Connection()
    var protocolConfiguration: Any? = NETunnelProviderProtocol()
    var localizedDescription: String?
    var isEnabled = false
    var saves = 0
    var failSave = false
    func saveToPreferences() async throws {
        saves += 1
        // Model an uncooperative system callback, including after cancellation.
        try? await Task.sleep(for: .milliseconds(80))
        if failSave { throw URLError(.unknown) }
    }
    func loadFromPreferences() async throws { await Task.yield() }
}
@MainActor final class Model {
    var busy = false
    var managersLoaded = true
    var pendingRecovery: String?
    var vpnLoadTask: Task<Void, Never>?
    var startingConnection = false
    var resetting = false
    var hasSelectedMode = true
    var replacingSubscription = false
    var connectionGeneration: UInt64 = 0
    var connectionMode = PrototypeConnectionMode.vless
    var routingMode = false
    let connections = 30
    var footprint = "—"
    var error: String?
    var subscription = Subscription()
    let deviceAccessStore = DeviceAccessStore()
    var manager: NETunnelProviderManager? = NETunnelProviderManager()
    var loads = 0
    var connectedAt: Date?
    func loadManagers() async throws -> [NETunnelProviderManager] {
        loads += 1
        try await Task.sleep(for: .milliseconds(80))
        return [manager!]
    }
    func refreshVPNState() { connectedAt = manager?.connection.connectedDate }
    func synchronizeDeviceAccess() async {}
    func isAvailable(_ mode: PrototypeConnectionMode) -> Bool { true }
    func prepareRouting(_ mode: Bool) throws -> Data { Data() }
    func writeRouting(_ data: Data) throws {}
    func removeRuntimeVLESS() throws {}
    // PRODUCTION_METHODS
}
@main struct Checks {
    @MainActor static func main() async throws {
        let scenario = CommandLine.arguments[2]
        let model = Model()
        let manager = model.manager!
        switch scenario {
        case "cold-open":
            model.managersLoaded = false
            manager.connection.status = .connected
            let originalDate = Date(timeIntervalSince1970: 1000)
            manager.connection.connectedDate = originalDate
            let initial = Task { await model.loadVPN() }
            while model.loads == 0 { await Task.yield() }
            initial.cancel()
            await model.loadVPN()
            await initial.value
            precondition(model.managersLoaded && model.connectedAt == originalDate, "opening did not restore the active session")
            precondition(model.loads == 1 && manager.connection.starts == 0)
        case "preferences":
            model.managersLoaded = false
            let first = Task { await model.loadVPN() }
            try await Task.sleep(for: .milliseconds(10))
            let second = Task { await model.loadVPN() }
            precondition(model.busy, "duplicate preferences load released another operation's busy state")
            await second.value
            precondition(model.managersLoaded, "second caller returned before discovery completed")
            await first.value
            precondition(model.loads == 1, "system VPN preferences loaded concurrently")
            precondition(!model.busy && model.managersLoaded)
        case "active":
            for state in [NEVPNStatus.connecting, .connected, .reasserting, .disconnecting] {
                manager.connection.status = state
                model.error = "Previous error"
                await model.start()
                precondition(manager.saves == 0 && manager.connection.starts == 0, "active VPN restarted")
                precondition(model.error == "Previous error", "ignored duplicate start generated an error")
            }
            precondition(VPNDiagnostics.starts == 0, "active VPN start entered configuration mutation")
        case "concurrent":
            let first = Task { await model.startConnection() }
            try await Task.sleep(for: .milliseconds(10))
            await model.startConnection()
            precondition(model.busy, "duplicate start released another operation's busy state")
            await first.value
            precondition(manager.saves == 1 && manager.connection.starts == 1, "VPN started twice across a suspended save")
            precondition(!model.busy)
        case "retry":
            manager.failSave = true
            await model.start()
            precondition(!model.busy && model.error != nil)
            manager.failSave = false
            await model.start()
            precondition(manager.saves == 2 && manager.connection.starts == 1, "failed startup prevented retry")
            precondition(!model.busy && model.error == nil)
        case "stop":
            let starting = Task { await model.start() }
            try await Task.sleep(for: .milliseconds(10))
            model.stop()
            await starting.value
            precondition(manager.connection.starts == 0, "late preferences callback restarted a stopped VPN")
            precondition(!model.busy)
        case "contended-stop":
            model.deviceAccessStore.contended = true
            let starting = Task { await model.start() }
            while model.deviceAccessStore.waiter == nil { await Task.yield() }
            model.stop()
            model.deviceAccessStore.waiter?.resume()
            await starting.value
            precondition(manager.saves == 0 && manager.connection.starts == 0)
            precondition(!model.busy && model.error == nil)
        case "reset":
            model.resetting = true
            await model.start()
            precondition(manager.saves == 0 && manager.connection.starts == 0, "VPN started during reset")
        case "external":
            let starting = Task { await model.start() }
            try await Task.sleep(for: .milliseconds(10))
            manager.connection.status = .connecting
            await starting.value
            precondition(manager.connection.starts == 0, "VPN started again after an external start during preferences save")
        case "restart":
            // Mode and routing switches already own busy when they restart a stopped tunnel.
            model.busy = true
            await model.startConnection()
            precondition(manager.connection.starts == 1, "mode/routing restart was blocked by its own busy state")
        default: fatalError("unknown scenario")
        }
        print("PASS")
    }
}
'''


class ConnectionStartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.folder = Path(cls.temporary.name)
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        methods = '\n'.join(method(app, marker).replace('private func', 'func') for marker in [
            '    func loadVPN() async', '    private func loadSystemVPNPreferences() async',
            '    private func ensureStopped()', '    func start() async',
            '    private func startConnection() async', '    func stop()'])
        source = cls.folder / 'checks.swift'
        source.write_text(HARNESS.replace('// PRODUCTION_METHODS', methods))
        cls.executable = cls.folder / 'checks'
        result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                 str(cls.folder / 'modules'), str(source), '-o', str(cls.executable)],
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_scenario(self, scenario):
        result = subprocess.run([str(self.executable), str(self.folder), scenario],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS', result.stdout)

    def test_preferences_are_loaded_once_while_the_system_callback_is_pending(self):
        self.run_scenario('preferences')

    def test_cold_open_keeps_active_session_when_first_view_task_is_cancelled(self):
        self.run_scenario('cold-open')

    def test_start_ignores_running_and_transitioning_tunnels_without_new_errors(self):
        self.run_scenario('active')

    def test_concurrent_start_calls_do_not_save_or_start_twice(self):
        self.run_scenario('concurrent')

    def test_failed_start_releases_the_guard_for_retry(self):
        self.run_scenario('retry')

    def test_stop_during_preferences_save_prevents_late_start(self):
        self.run_scenario('stop')

    def test_stop_while_waiting_for_subscription_lock_prevents_preparing_vpn(self):
        self.run_scenario('contended-stop')

    def test_start_is_ignored_during_reset(self):
        self.run_scenario('reset')

    def test_tunnel_state_is_checked_again_after_preferences_save(self):
        self.run_scenario('external')

    def test_mode_and_routing_can_restart_a_stopped_tunnel_while_busy(self):
        self.run_scenario('restart')
