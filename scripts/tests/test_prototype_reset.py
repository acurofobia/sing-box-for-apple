"""Exercise the model's partial reset, local cleanup and diagnostic cancellation."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_prototype_startup_cancellation import method

ROOT = Path(__file__).resolve().parents[2]


class ResetDiagnosticsTests(unittest.TestCase):
    def test_reset_releases_controls_on_missing_replies_and_partial_failures(self):
        source = (ROOT / 'PrototypeApp/Application.swift').read_text()
        reset = method(source, '    func resetApplication()')
        can_stop = method(source, '    var canStop: Bool')
        discover = method(source, '    private func loadManagers()') + '\n' + method(source, '    private func withVPNPreferenceTimeout')
        record = method(source, '    func recordVPNState(')
        harness = r'''
import Foundation
enum NEVPNStatus: Int { case connected, disconnected, invalid }
enum PrototypeConnectionMode { case vkTurn }
enum PrototypeRoutingMode { case enabled }
enum AppConfiguration {
    static let extensionBundleID = "fixture.app"
    static let vkTurnExtensionBundleID = "fixture.turn"
    static let appGroupID = "fixture.group"
}
enum FilePath { static var sharedDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[1]) } }
enum ServiceSetup { static func apply(crashReportSource _: String) throws {} }
enum VKTurnConfigurationStore { static func clear() throws {} }
enum VPNDiagnostics {
    static var events: [String] = []
    static func observeConnection(disconnected: Bool) {}
    static func app(_ message: String) { events.append(message) }
    static func applicationError(_ message: String, error: Error) { events.append(message) }
    static func expectStop() {}
    static func reset() throws {}
}
struct PrototypeSubscription {}
class NETunnelProviderProtocol {
    var providerBundleIdentifier: String? = AppConfiguration.extensionBundleID
    var disconnectOnSleep = false
}
class TestConnection {
    var status = NEVPNStatus.connected
    var connectedDate: Date?
    var diagnostic: CheckedContinuation<Void, Error>?
    @MainActor func fetchLastDisconnectError() async throws {
        try await withCheckedThrowingContinuation { diagnostic = $0 }
    }
    func stopVPNTunnel() { status = .disconnected }
}
class NETunnelProviderManager {
    static let existing = NETunnelProviderManager()
    static let unrelated = NETunnelProviderManager()
    static var heldReply: (([NETunnelProviderManager]?, Error?) -> Void)?
    static var holdDiscovery = false
    static var heldMutation: ((Error?) -> Void)?
    static var holdMutation = true
    let connection = TestConnection()
    let protocolConfiguration: NETunnelProviderProtocol? = NETunnelProviderProtocol()
    var isEnabled = true, isOnDemandEnabled = true
    static func loadAllFromPreferences(completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void) {
        if holdDiscovery { heldReply = completionHandler }
        else { completionHandler([existing, unrelated], nil) }
    }
    static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        await withCheckedContinuation { continuation in
            loadAllFromPreferences { managers, _ in continuation.resume(returning: managers ?? []) }
        }
    }
    func saveToPreferences(completionHandler: @escaping (Error?) -> Void) {
        if Self.holdMutation && CommandLine.arguments[2] == "save-timeout" { Self.heldMutation = completionHandler }
        else { completionHandler(nil) }
    }
    func removeFromPreferences(completionHandler: @escaping (Error?) -> Void) {
        if Self.holdMutation && CommandLine.arguments[2] == "remove-timeout" { Self.heldMutation = completionHandler }
        else { completionHandler(CommandLine.arguments[2] == "profile" ? CocoaError(.fileWriteNoPermission) : nil) }
    }

}
class Store {
    var resetAttempts = 0
    func cancel() {}
    func reset() async throws {
        resetAttempts += 1
        throw CocoaError(.fileWriteNoPermission)
    }
}
@MainActor final class Model {
    var manager: NETunnelProviderManager? = NETunnelProviderManager.existing
    var busy = false, resetting = false, managersLoaded = true
    var recoveryOfferSequence: UInt64 = 0, connectionGeneration: UInt64 = 0
    var error: String?, subscriptionError: String?, retainedModeTitle: String?
    var subscriptionLoading = false, replacingSubscription = false, hasSelectedMode = true, hasInitializedSelection = true
    var subscription = PrototypeSubscription()
    var connectionMode = PrototypeConnectionMode.vkTurn
    var routingMode = PrototypeRoutingMode.enabled
    var footprint = "8.0 МиБ", status = "Подключено"
    var vpnState = NEVPNStatus.connected
    var connectedAt: Date? = .now
    var failoverStatus: String? = "active"
    func refreshVPNState() { vpnState = manager?.connection.status ?? .disconnected }
    let store = Store()
    var lastDiagnosticState: NEVPNStatus?
    var disconnectDiagnosticTask: Task<Void, Never>?
''' + '\n'.join([can_stop, discover, record, reset]) + r'''
}
@main struct Checks {
    @MainActor static func main() async {
        let model = Model()
        let scenario = CommandLine.arguments[2]
        let existing = NETunnelProviderManager.existing
        let unrelated = NETunnelProviderManager.unrelated
        unrelated.protocolConfiguration?.providerBundleIdentifier = "other.extension"
        NETunnelProviderManager.holdDiscovery = scenario == "discovery"
        var diagnostic: Task<Void, Never>?
        if scenario == "late-diagnostic" {
            model.recordVPNState(force: true)
            while existing.connection.diagnostic == nil { await Task.yield() }
            diagnostic = model.disconnectDiagnosticTask
            VPNDiagnostics.events.removeAll()
        }
        await model.resetApplication()
        guard model.error != nil, !model.busy, !model.resetting else {
            print("FAIL: expected a reported reset error and released controls")
            exit(1)
        }
        if scenario == "discovery" {
            precondition(model.canStop && existing.isOnDemandEnabled && model.store.resetAttempts == 0,
                         "failed discovery must preserve the active profile and local subscription")
            NETunnelProviderManager.heldReply?([existing], nil)
            NETunnelProviderManager.holdDiscovery = false
            await model.resetApplication()
            precondition(model.store.resetAttempts == 1, "retry did not reach local cleanup")
        }
        if scenario.hasSuffix("-timeout") {
            precondition(model.store.resetAttempts == 0 && !model.managersLoaded,
                         "unconfirmed profile mutation allowed local cleanup or reuse of stale preferences")
            precondition(model.canStop == (scenario == "save-timeout"), "incorrect state after partial reset")
            let late = NETunnelProviderManager.heldMutation
            NETunnelProviderManager.holdMutation = false
            await model.resetApplication()
            late?(nil)
            await Task.yield()
            precondition(model.store.resetAttempts == 1 && !model.busy && !model.resetting,
                         "retry or late completion resumed the wrong reset")
        }
        if scenario == "late-diagnostic" {
            existing.connection.diagnostic?.resume(throwing: CocoaError(.fileReadUnknown))
            await diagnostic?.value
            precondition(VPNDiagnostics.events.isEmpty, "late disconnect error recreated diagnostics")
        }
        precondition(unrelated.isOnDemandEnabled && unrelated.connection.status == .connected,
                     "reset modified a different app's VPN")
        guard model.vpnState == .disconnected, !model.canStop, model.connectedAt == nil,
              model.status == "Отключено", model.failoverStatus == nil, model.footprint == "—" else {
            print("FAIL: partial reset left the stopped VPN displayed as active")
            exit(1)
        }
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            swift = folder / 'checks.swift'
            swift.write_text(harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(ROOT / 'Library/Shared/BlockingIO.swift'),
                                     str(swift), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for failure_stage in ('profile', 'storage', 'late-diagnostic', 'discovery', 'save-timeout', 'remove-timeout'):
                with self.subTest(failure_stage=failure_stage):
                    try:
                        result = subprocess.run([str(executable), str(folder), failure_stage], capture_output=True,
                                                text=True, timeout=8 if failure_stage in ('discovery', 'save-timeout', 'remove-timeout') else 3)
                    except subprocess.TimeoutExpired:
                        self.fail(f'reset still waits for a missing {failure_stage} reply')
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reset_preserves_container_metadata_and_removes_app_files(self):
        source = (ROOT / 'PrototypeApp/Application.swift').read_text()
        cleanup = method(source, '            for file in try fm.contentsOfDirectory(')
        cleanup += '\n' + method(source, '            for directory in directories where')
        harness = r'''
import Foundation
enum FilePath {
    static let sharedDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
}
func resetSharedFiles() throws {
    let fm = FileManager.default
    let directories = [FilePath.sharedDirectory.appendingPathComponent("Library/Caches")]
''' + cleanup + r'''
}
@main struct Checks {
    static func main() throws {
        let fm = FileManager.default
        let root = FilePath.sharedDirectory
        let metadata = root.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        let originalMetadata = Data("system-owned metadata".utf8)
        try originalMetadata.write(to: metadata)
        let preserved = ["Library", "device-access.lock", "device-access-record.lock", "device-access-fixture.json"]
        try fm.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        let caches = root.appendingPathComponent("Library/Caches")
        let systemCache = caches.appendingPathComponent("com.apple.dyld")
        let temporaryData = caches.appendingPathComponent("Prototype")
        try fm.createDirectory(at: systemCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: temporaryData, withIntermediateDirectories: true)
        for name in preserved.dropFirst() { try Data("persistent".utf8).write(to: root.appendingPathComponent(name)) }
        let deleted = ["prototype-subscription.json", "prototype-subscription.json.refresh", "stderr.log", ".app-private-state", "runtime"]
        for name in deleted.dropLast() { try Data("app data".utf8).write(to: root.appendingPathComponent(name)) }
        try fm.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: root.appendingPathComponent("runtime/config.json"))
        try resetSharedFiles()
        precondition(fm.fileExists(atPath: systemCache.path), "reset removed the system cache")
        precondition(!fm.fileExists(atPath: temporaryData.path), "reset retained application data")
        guard fm.fileExists(atPath: metadata.path) else {
            throw NSError(domain: "ResetTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "reset deleted iOS container metadata"])
        }
        let retainedMetadata = try Data(contentsOf: metadata)
        precondition(retainedMetadata == originalMetadata)
        for name in preserved { precondition(fm.fileExists(atPath: root.appendingPathComponent(name).path), name) }
        for name in deleted { precondition(!fm.fileExists(atPath: root.appendingPathComponent(name).path), name) }
        try resetSharedFiles()
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            container = folder / 'container'
            container.mkdir()
            swift = folder / 'checks.swift'
            swift.write_text(harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(swift), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(executable), str(container)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)

    def test_reset_suppresses_notifications_and_cancelled_diagnostics(self):
        source = (ROOT / 'PrototypeApp/Application.swift').read_text()
        callback = method(source, '    func recordVPNState(')
        harness = r'''
import Foundation
enum State: Int { case disconnected, invalid, connected }
@MainActor enum VPNDiagnostics {
    static var events: [String] = []
    static func observeConnection(disconnected: Bool) { events.append("observed") }
    static func app(_ message: String) { events.append(message) }
    static func applicationError(_ message: String, error: Error) { events.append(message) }
}
@MainActor final class Connection {
    var status: State = .disconnected
    var connectedDate: Date?
    var fails = false
    func fetchLastDisconnectError() async throws {
        try? await Task.sleep(for: .milliseconds(20))
        if fails { throw NSError(domain: "OldDisconnect", code: 1) }
    }
}
struct Configuration { var disconnectOnSleep = false }
@MainActor final class Manager {
    let connection = Connection()
    var isEnabled = true
    var isOnDemandEnabled = false
    var protocolConfiguration: Configuration? = Configuration()
}
@MainActor final class Model {
    var manager: Manager? = Manager()
    var resetting = false
    var connectionGeneration: UInt64 = 0
    var lastDiagnosticState: State?
    var disconnectDiagnosticTask: Task<Void, Never>?
''' + callback + r'''
}
@main struct Checks {
    @MainActor static func main() async {
        let model = Model()
        model.resetting = true
        model.recordVPNState(force: true)
        await model.disconnectDiagnosticTask?.value
        precondition(VPNDiagnostics.events.isEmpty, "reset recorded a VPN status notification")
        model.resetting = false
        for fails in [false, true] {
            model.manager?.connection.fails = fails
            model.recordVPNState(force: true)
            VPNDiagnostics.events.removeAll()
            model.disconnectDiagnosticTask?.cancel()
            await model.disconnectDiagnosticTask?.value
            precondition(VPNDiagnostics.events.isEmpty, "cancelled diagnostic task recreated old logs")
        }
        model.recordVPNState(force: true)
        let previous = model.disconnectDiagnosticTask
        model.recordVPNState(force: true)
        let latest = model.disconnectDiagnosticTask
        VPNDiagnostics.events.removeAll()
        model.connectionGeneration += 1
        latest?.cancel()
        await previous?.value
        await latest?.value
        precondition(VPNDiagnostics.events.isEmpty, "an older diagnostic task survived reset")
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            swift = folder / 'checks.swift'
            swift.write_text(harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(swift), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
