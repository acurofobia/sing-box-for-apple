"""Exercise cold launch with a real saved subscription and a stuck iOS VPN callback."""
from pathlib import Path
import subprocess
import fcntl
import tempfile
import unittest

from test_device_access import production_sources
from test_prototype_startup_cancellation import method

ROOT = Path(__file__).resolve().parents[2]


class InitialLoadTests(unittest.TestCase):
    def test_saved_subscription_loads_before_system_vpn_responds(self):
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        load = method(app, '    func load() async')
        harness = r'''
@MainActor enum VPNDiagnostics {
    static var environment = "test"
    static func app(_ message: String) {}
    static func applicationError(_ message: String, error: Error) {}
}
enum ServiceSetup { static func apply(crashReportSource: String) throws {} }
enum AppConfiguration { static let extensionBundleID = "test.extension" }
enum PrototypeConnectionMode: String { case vkTurn = "vk-turn", vless }
class NETunnelProviderProtocol {
    var providerBundleIdentifier: String? = "test.extension"
    var providerConfiguration: [String: Any]? = [:]
}
enum State { case connected, connecting, disconnected }
class Connection { var status = State.disconnected }
@MainActor class NETunnelProviderManager {
    static var requests = 0
    static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        requests += 1
        try await Task.sleep(for: .seconds(60))
        return []
    }
    var protocolConfiguration: Any? = NETunnelProviderProtocol()
    let connection = Connection()
}
@MainActor final class Model {
    var loaded = false
    var busy = true
    var managersLoaded = false
    var hasInitializedSelection = false
    var hasSelectedMode = false
    var connectionMode = PrototypeConnectionMode.vkTurn
    var routingPreferenceKey = "test.routing"
    var routingMode = PrototypeRoutingMode.enabled
    var manager: NETunnelProviderManager?
    var error: String?
    let preferences = UserDefaults(suiteName: "InitialLoadTests")!
    let cacheURL: URL
    let store: PrototypeSubscriptionStore
    var subscription = PrototypeSubscription()
    init(_ cache: URL) {
        cacheURL = cache
        store = PrototypeSubscriptionStore(cacheURL: cache)
    }
    func chooseInitialMode() {}
    func refreshVPNState() {}
''' + load + r'''
}
@main struct Checks {
    @MainActor static func main() async throws {
        let cache = URL(fileURLWithPath: CommandLine.arguments[1])
        let document = try PrototypeUIDocument.decode(Data(#"{"schemaVersion":1,"blocks":[],"pages":[]}"#.utf8))
        let saved = PrototypeSubscription(uiURL: "https://offline.invalid/ui", uiDocument: document,
                                          updatedAt: Date(), sourceURL: "https://offline.invalid/sub")
        try JSONEncoder().encode(saved).write(to: cache)
        let original = try Data(contentsOf: cache)
        let model = Model(cache)
        let loading = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(50))
        precondition(model.subscription.isComplete, "saved subscription waits for system VPN callback")
        precondition(model.subscription.sourceURL == saved.sourceURL)
        let retained = try Data(contentsOf: cache)
        precondition(retained == original, "cold launch rewrote saved subscription")
        loading.cancel()
        await loading.value
        let incompatible = Data(#"{"warnings":[],"vlessProvisioning":false}"#.utf8)
        try incompatible.write(to: cache)
        for _ in 0..<2 {
            let reopened = Model(cache)
            await reopened.load()
            precondition(reopened.loaded && !reopened.subscription.isComplete)
            precondition(reopened.error?.contains("«Логи»") == true)
        }
        let afterRecovery = try Data(contentsOf: cache)
        precondition(afterRecovery == incompatible)
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            source = folder / 'checks.swift'
            source.write_text(production_sources() + harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(source), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable), str(folder / 'snapshot.json')],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)


class CacheLockTests(unittest.TestCase):
    def test_cache_read_does_not_wait_for_writer_and_still_applies_revocation(self):
        harness = r'''
@main struct Checks {
    static func main() throws {
        let cache = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = SubscriptionDeviceAccessStore(cacheURL: cache)
        let source = "https://offline.invalid/sub"
        let hwid = String(repeating: "a", count: 64)
        let decision = try SubscriptionDeviceAccessDecision.decode(Data("{\"schemaVersion\":1,\"hwid\":\"\(hwid)\",\"state\":\"device_revoked\",\"revision\":1}".utf8), hwid: hwid)
        let decisionURL = cache.deletingLastPathComponent().appendingPathComponent("device-access-" + SubscriptionDeviceIdentity.digest(source) + ".json")
        try JSONEncoder().encode(decision).write(to: decisionURL, options: .atomic)
        let snapshot = try JSONSerialization.data(withJSONObject: ["sourceURL": source, "vkTurnLink": "secret"])
        let sanitized = try store.sanitizedSnapshot(snapshot)
        let root = try JSONSerialization.jsonObject(with: sanitized) as! [String: Any]
        precondition(root["vkTurnLink"] == nil, "lock-free read bypassed revocation")
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            source = folder / 'checks.swift'
            source.write_text(production_sources() + harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(source), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with (folder / 'device-access.lock').open('w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                try:
                    result = subprocess.run([str(executable), str(folder / 'snapshot.json')],
                                            capture_output=True, text=True, timeout=3)
                except subprocess.TimeoutExpired:
                    self.fail('saved subscription read blocks on another process holding the lock')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('PASS', result.stdout)


class VPNPreferencesTests(unittest.TestCase):
    def test_missing_callback_times_out_and_late_callback_cannot_replace_retry(self):
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        marker = '    private func loadManagers() async throws'
        loader = method(app, marker) + '\n' + method(app, '    private func withVPNPreferenceTimeout')
        harness = r'''
import Foundation
final class NETunnelProviderManager: @unchecked Sendable {
    static var reply: (([NETunnelProviderManager]?, Error?) -> Void)?
    static var responds = false
    static var fails = false
    static func loadAllFromPreferences(completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void) {
        reply = completionHandler
        if responds { completionHandler(fails ? nil : [NETunnelProviderManager()], fails ? URLError(.unknown) : nil) }
    }
    static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: managers ?? []) }
            }
        }
    }
}
@MainActor final class Model {
''' + loader.replace('private func', 'func') + r'''
}
@main struct Checks {
    @MainActor static func main() async throws {
        let model = Model()
        do {
            _ = try await model.loadManagers()
            fatalError("missing VPN callback succeeded")
        } catch {
            precondition((error as? URLError)?.code == .timedOut, "missing callback did not time out")
        }
        let late = NETunnelProviderManager.reply
        NETunnelProviderManager.responds = true
        let managers = try await model.loadManagers()
        precondition(managers.count == 1, "retry after timeout failed")
        late?([], nil)
        NETunnelProviderManager.fails = true
        do { _ = try await model.loadManagers(); fatalError("VPN error ignored") } catch {}
        NETunnelProviderManager.responds = false
        let cancelled = Task { try await model.loadManagers() }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled request succeeded") } catch {}
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            source = folder / 'checks.swift'
            source.write_text(harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(source), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            try:
                result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=8)
            except subprocess.TimeoutExpired:
                self.fail('system VPN callback has no bounded timeout')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)


class InitialRevocationTests(unittest.TestCase):
    def test_revocation_while_loading_managers_stops_discovered_wdtt_but_keeps_vless(self):
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        load = method(app, '    func loadVPN() async')
        load += '\n' + method(app, '    private func loadSystemVPNPreferences() async')
        synchronize = method(app, '    private func synchronizeDeviceAccess()').replace('private func', 'func')
        harness = r'''
@MainActor enum VPNDiagnostics {
    static func app(_ message: String) {}
    static func applicationError(_ message: String, error: Error) {}
    static func expectStop() {}
}
enum ServiceSetup { static func apply(crashReportSource: String) throws {} }
enum AppConfiguration { static let extensionBundleID = "test.extension" }
enum PrototypeConnectionMode: String { case vkTurn = "vk-turn", vless }
enum State { case connected, connecting, disconnected }
@MainActor class Connection {
    var status = State.connected
    var stops = 0
    func stopVPNTunnel() { stops += 1 }
}
class NETunnelProviderProtocol {
    let providerBundleIdentifier: String? = "test.extension"
    var providerConfiguration: [String: Any]?
    init(_ mode: String) { providerConfiguration = ["mode": mode] }
}
@MainActor class NETunnelProviderManager {
    var protocolConfiguration: Any?
    let connection = Connection()
    init(_ mode: String) { protocolConfiguration = NETunnelProviderProtocol(mode) }
}
@MainActor final class Model {
    var busy = true
    var managersLoaded = false
    var pendingRecovery: String?
    var vpnLoadTask: Task<Void, Never>?
    var resetting = false
    var connectionMode = PrototypeConnectionMode.vkTurn
    var hasSelectedMode = true
    var connectionGeneration: UInt64 = 0
    var error: String?
    var subscriptionError: String?
    var manager: NETunnelProviderManager?
    var vpnState = State.disconnected
    var canStop: Bool { vpnState == .connected }
    let discovered: NETunnelProviderManager
    let store: PrototypeSubscriptionStore
    let deviceAccessStore: SubscriptionDeviceAccessStore
    var subscription: PrototypeSubscription
    init(_ cache: URL, mode: String) throws {
        discovered = NETunnelProviderManager(mode)
        store = PrototypeSubscriptionStore(cacheURL: cache)
        deviceAccessStore = SubscriptionDeviceAccessStore(cacheURL: cache)
        try store.load()
        subscription = store.snapshot
    }
    func loadManagers() async throws -> [NETunnelProviderManager] {
        try await Task.sleep(for: .milliseconds(80))
        return [discovered]
    }
    func refreshVPNState() { vpnState = manager?.connection.status ?? .disconnected }
''' + load + '\n' + synchronize + r'''
}
@main struct Checks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let contended = CommandLine.arguments.contains("contended")
        for mode in contended ? ["vk-turn"] : ["vk-turn", "vless"] {
            let cache = directory.appendingPathComponent(mode + ".json")
            let source = "https://offline.invalid/sub"
            let document = try PrototypeUIDocument.decode(Data(#"{"schemaVersion":1,"blocks":[],"pages":[]}"#.utf8))
            let saved = PrototypeSubscription(uiURL: "https://offline.invalid/ui", uiDocument: document,
                                              updatedAt: Date(), sourceURL: source)
            try JSONEncoder().encode(saved).write(to: cache)
            let model = try Model(cache, mode: mode)
            let initializing = Task { await model.loadVPN() }
            try await Task.sleep(for: .milliseconds(10))
            let hwid = String(repeating: "a", count: 64)
            let decision = try SubscriptionDeviceAccessDecision.decode(Data("{\"schemaVersion\":1,\"hwid\":\"\(hwid)\",\"state\":\"device_revoked\",\"revision\":1}".utf8), hwid: hwid)
            if contended {
                let ledger = directory.appendingPathComponent("device-access-" + SubscriptionDeviceIdentity.digest(source) + ".json")
                try JSONEncoder().encode(decision).write(to: ledger, options: .atomic)
            } else {
                _ = try await model.deviceAccessStore.record(decision, source: source)
                await model.synchronizeDeviceAccess()
                precondition(model.manager == nil, "revocation did not race system discovery")
            }
            await initializing.value
            precondition(model.discovered.connection.stops == (mode == "vk-turn" ? 1 : 0), "startup revocation left WDTT running or stopped VLESS")
            precondition(!model.busy && model.managersLoaded)
            if contended {
                precondition(model.subscriptionError != nil && model.subscription.wdttAccessState == .revoked)
                precondition(model.subscription.isComplete && model.subscription.vkTurnLink == nil)
            }
        }
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            source = folder / 'checks.swift'
            source.write_text(production_sources() + harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(source), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable), str(folder)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)
            with (folder / 'device-access.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                result = subprocess.run([str(executable), str(folder), 'contended'],
                                        capture_output=True, text=True, timeout=22)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('PASS', result.stdout)
