"""Atomic cache and cancellation tests against the production Swift store."""
from test_device_access import production_sources, shared_sources
from test_prototype_startup_cancellation import method
from pathlib import Path
import fcntl
import select
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = '''
@main struct Checks {
 @MainActor static func main() async throws {
  let directory = URL(fileURLWithPath: CommandLine.arguments[1])
  let cache = directory.appendingPathComponent("snapshot.json")
  let store = PrototypeSubscriptionStore(cacheURL: cache, download: { source in
   if source == "fail" { throw PrototypeSubscriptionError.invalidResponse }
   // Deliberately ignore cancellation to reproduce an uncooperative late response.
   if source == "old" { try? await Task.sleep(for: .milliseconds(150)) }
   let doc = try PrototypeUIDocument.decode(Data(#"{"schemaVersion":1,"blocks":[],"pages":[]}"#.utf8))
   return PrototypeSubscription(uiURL: "http://localhost/ui", uiDocument: doc, updatedAt: Date(), sourceURL: source)
  })
  _ = try await store.update("first", replacing: true)
  let baseline = try Data(contentsOf: cache)
  do { _ = try await store.update("fail", replacing: true); fatalError("failure accepted") } catch {}
  let afterFailure = try Data(contentsOf: cache)
  precondition(afterFailure == baseline, "failed request changed cache")
  let old = Task { try await store.update("old", replacing: false) }
  try await Task.sleep(for: .milliseconds(20))
  let coalesced = try await store.update("ignored", replacing: false)
  precondition(coalesced == nil, "duplicate refresh was started")
  _ = try await store.update("new", replacing: true)
  _ = try await old.value
  precondition(store.snapshot.sourceURL == "new", "late response replaced new link")
  let pending = Task { try await store.update("old", replacing: true) }
  try await Task.sleep(for: .milliseconds(20))
  store.cancel()
  _ = try await pending.value
  precondition(store.snapshot.sourceURL == "new", "cancelled replacement was saved")
  let restored = PrototypeSubscriptionStore(cacheURL: cache)
  try restored.load()
  precondition(restored.snapshot.isComplete && restored.snapshot.sourceURL == "new")
  let persisted = try Data(contentsOf: cache)
  do {
   _ = try await store.update("blocked", replacing: true, authorizeCommit: { throw PrototypeSubscriptionError.stopBeforeImport })
   fatalError("commit authorization ignored")
  } catch {}
  let afterDenied = try Data(contentsOf: cache)
  precondition(afterDenied == persisted)
  try Data(#"{"sourceURL":"legacy","warnings":[]}"#.utf8).write(to: cache)
  try restored.load()
  precondition(!restored.snapshot.isComplete, "legacy cache permitted VPN start")
  let validDocument = try Data(contentsOf: directory.appendingPathComponent("provisioning.json"))
  let provisioned = try PrototypeSubscription.decodeVLESSProvisioning(validDocument)
  var snapshot = store.snapshot
  snapshot.vlessProvisioning = provisioned
  try JSONEncoder().encode(snapshot).write(to: cache)
  try restored.load()
  precondition(restored.snapshot.vlessProvisioning?.failover?.primary == "n1")
  let reserved = PrototypeServiceWDTT(revision: 9, link: "wdtt://fixture.invalid:443:51820:1080:test:call")
  snapshot.serviceWDTT = reserved
  try JSONEncoder().encode(snapshot).write(to: cache)
  let rotating = PrototypeSubscriptionStore(cacheURL: cache, download: { source in
   let doc = try PrototypeUIDocument.decode(Data(#"{"schemaVersion":1,"blocks":[],"pages":[]}"#.utf8))
   return PrototypeSubscription(serviceWDTT: PrototypeServiceWDTT(revision: 2, link: reserved.link), uiDocument: doc, updatedAt: Date(), sourceURL: source)
  })
  try rotating.load()
  _ = try await rotating.update("new", replacing: false)
  precondition(rotating.snapshot.serviceWDTT?.revision == 9, "late response rolled back service access")
  _ = try await rotating.update("other", replacing: true)
  precondition(rotating.snapshot.serviceWDTT?.revision == 2, "service access leaked between sources")
  let clock = Date(timeIntervalSince1970: 1_800_000_000)
  _ = try await store.update("first", replacing: true, now: clock)
  let throttled = try await store.update("first", replacing: false, automatic: true, now: clock.addingTimeInterval(3599))
  precondition(throttled == nil, "automatic refresh bypassed the hourly interval")
  let reloaded = PrototypeSubscriptionStore(cacheURL: cache)
  try reloaded.load()
  let afterRelaunch = try await reloaded.update("first", replacing: false, automatic: true, now: clock.addingTimeInterval(3599))
  precondition(afterRelaunch == nil, "relaunch bypassed the hourly interval")
  let due = try await store.update("first", replacing: false, automatic: true, now: clock.addingTimeInterval(3600))
  precondition(due != nil, "hourly automatic refresh did not run")
  let manual = try await store.update("first", replacing: false, now: clock.addingTimeInterval(3601))
  precondition(manual != nil, "manual refresh was throttled")
  do {
   _ = try await store.update("fail", replacing: false, automatic: true, now: clock.addingTimeInterval(7201))
   fatalError("failed download unexpectedly succeeded")
  } catch {}
  let retry = try await store.update("first", replacing: false, automatic: true, now: clock.addingTimeInterval(7202))
  precondition(retry == nil, "failed automatic request was retried too early")
  let late = Task { try await store.update("old", replacing: true) }
  try await Task.sleep(for: .milliseconds(20))
  try await store.reset()
  _ = try await late.value
  precondition(!store.snapshot.isComplete && !FileManager.default.fileExists(atPath: cache.path), "reset retained subscription or late download")
  let resetReloaded = PrototypeSubscriptionStore(cacheURL: cache)
  try resetReloaded.load()
  precondition(!resetReloaded.snapshot.isComplete, "reset did not persist")
  _ = try await store.update("first", replacing: true)
  snapshot = store.snapshot
  snapshot.vlessProvisioning = provisioned
  try JSONEncoder().encode(snapshot).write(to: cache)
  var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
  var provisioning = raw["vlessProvisioning"] as! [String: Any]
  var nodes = provisioning["outbounds"] as! [[String: Any]]
  nodes[0]["detour"] = "direct"
  provisioning["outbounds"] = nodes
  raw["vlessProvisioning"] = provisioning
  try JSONSerialization.data(withJSONObject: raw).write(to: cache)
  do { try restored.load(); fatalError("corrupt cached outbound accepted") } catch {}
  // A fresh process must be able to report an incompatible cache and import again.
  for unsupported in [false, "legacy", 1, []] as [Any] {
   raw["vlessProvisioning"] = unsupported
   let incompatible = try JSONSerialization.data(withJSONObject: raw)
   try incompatible.write(to: cache)
   let reopened = PrototypeSubscriptionStore(cacheURL: cache)
   do { try reopened.load(); fatalError("invalid provisioning shape accepted") }
   catch PrototypeSubscriptionError.invalidVLESS {}
   precondition(!reopened.snapshot.isComplete)
   let untouched = try Data(contentsOf: cache)
   precondition(untouched == incompatible)
  }
  _ = try await store.update("first", replacing: true)
  try restored.load()
  precondition(restored.snapshot.isComplete && restored.snapshot.sourceURL == "first")
  raw["vlessProvisioning"] = NSNull()
  try JSONSerialization.data(withJSONObject: raw).write(to: cache)
  try restored.load()
  precondition(restored.snapshot.isComplete && restored.snapshot.vlessProvisioning == nil)
  print("PASS")
 }
}
'''


class LifecycleTests(unittest.TestCase):
    def test_contended_save_keeps_main_actor_responsive_and_rechecks_authorization(self):
        harness = r'''
@main struct Checks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let scenario = CommandLine.arguments[2]
        let cache = directory.appendingPathComponent("snapshot.json")
        let document = try PrototypeUIDocument.decode(Data(#"{"schemaVersion":1,"blocks":[],"pages":[]}"#.utf8))
        let previous = PrototypeSubscription(uiDocument: document, updatedAt: Date(), sourceURL: "previous")
        let original = try JSONEncoder().encode(previous)
        try original.write(to: cache)
        let store = PrototypeSubscriptionStore(cacheURL: cache) { source in
            PrototypeSubscription(uiDocument: document, updatedAt: Date(), sourceURL: source)
        }
        try store.load()
        var authorized = true
        let (downloaded, signal) = AsyncStream<Void>.makeStream()
        let save = Task {
            try await store.update("next", replacing: false, automatic: true, now: .distantFuture,
                didDownload: { signal.yield(()) }, authorizeCommit: {
                    if !authorized { throw PrototypeSubscriptionError.stopBeforeImport }
                })
        }
        for await _ in downloaded { break }
        // Let the save reach the lock, then exercise a UI action while the other process holds it.
        try await Task.sleep(for: .milliseconds(75))
        switch scenario {
        case "cancel": store.cancel()
        case "reset": try await store.reset()
        case "deny": authorized = false
        default: break
        }
        if scenario == "cancel" || scenario == "reset" {
            let cancelled = try await save.value
            precondition(cancelled == nil)
        }
        print("responsive"); fflush(stdout)
        if scenario == "deny" {
            do { _ = try await save.value; fatalError("stale authorization accepted") }
            catch PrototypeSubscriptionError.stopBeforeImport {}
        } else if scenario == "timeout" {
            do { _ = try await save.value; fatalError("save completed despite the held lock") }
            catch let error as POSIXError { precondition(error.code == .ETIMEDOUT) }
            precondition(!store.isLoading)
        } else if scenario == "save" {
            let updated = try await save.value
            precondition(updated?.sourceURL == "next")
        }
        if scenario == "reset" {
            precondition(!FileManager.default.fileExists(atPath: cache.path) && !store.snapshot.isComplete)
        } else {
            let data = try Data(contentsOf: cache)
            let saved = try JSONDecoder().decode(PrototypeSubscription.self, from: data)
            precondition(saved.sourceURL == store.snapshot.sourceURL)
            precondition(scenario == "save" || data == original)
        }
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / 'main.swift'
            source.write_text(production_sources() + harness)
            executable = folder / 'checks'
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                            str(source), '-o', str(executable)], check=True, capture_output=True, text=True)
            for scenario in ('save', 'cancel', 'reset', 'deny', 'timeout'):
                data = folder / scenario
                data.mkdir()
                with self.subTest(scenario=scenario), (data / 'device-access.lock').open('a') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    with subprocess.Popen([str(executable), str(data), scenario], stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, text=True) as process:
                        try:
                            ready, _, _ = select.select([process.stdout], [], [], 3)
                            self.assertTrue(ready, 'main actor or cancellation waited for the external lock')
                            self.assertEqual(process.stdout.readline().strip(), 'responsive')
                            if scenario != 'timeout':
                                fcntl.flock(lock, fcntl.LOCK_UN)
                            process.wait(timeout=20 if scenario == 'timeout' else 5)
                            self.assertEqual(process.returncode, 0, process.stderr.read())
                            self.assertIn('PASS', process.stdout.read())
                        finally:
                            if process.poll() is None:
                                process.kill()

    def test_atomic_snapshot_cancelled_and_stale_responses_and_legacy_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / 'main.swift'
            files = ['Library/Network/VKTurnConfiguration.swift', 'PrototypeApp/SubscriptionUIDocument.swift',
                     'PrototypeApp/Subscription.swift', 'PrototypeApp/SubscriptionLoader.swift',
                     'PrototypeApp/SubscriptionStore.swift']
            source.write_text(shared_sources() + '\n'.join((ROOT / name).read_text().replace('import Library\n', '') for name in files) + HARNESS)
            import json
            from test_prototype_subscription import NODE
            nodes = [dict(NODE, tag=tag, tls={'enabled': True, 'server_name': 'example.org',
                     'utls': {'enabled': True, 'fingerprint': 'chrome'},
                     'reality': {'enabled': True, 'public_key': 'A' * 43, 'short_id': 'abcd'}}) for tag in ['n1','n2','n3','n4']]
            (folder / 'provisioning.json').write_text(json.dumps({'schemaVersion':1,'kind':'vless-failover','state':'available',
                'outbounds':nodes,'failover':{'selector':'vk-wg','primary':'n1','backups':['n2','n3','n4'],
                'intervalMilliseconds':10000,'timeoutMilliseconds':5000,'failureThreshold':2,'recoveryThreshold':3}}))
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                                     str(source), '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable), directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)


class SubscriptionModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        methods = '\n'.join(method(app, marker) for marker in [
            '    struct ImportProgress', '    enum RecoveryStep', '    enum StepState', '    struct Recovery {',
            '    private func ensureStopped()', '    func refreshSubscription(',
            '    @discardableResult func replaceSubscription(', '    func cancelSubscriptionReplacement()',
            '    static func canRecover(', '    private static func networkMessage(',
        ])
        for marker in ('    @discardableResult private func fetchSubscription(', '    private func updateSubscription('):
            fetch = app[app.index(marker):]
            signature_end = fetch.index(' async -> Bool {')
            methods += '\n' + fetch[:signature_end] + method(fetch, ' async -> Bool {')
        harness = r'''
enum VPNDiagnostics {
    static func applicationError(_ message: String, error: Error? = nil) {}
}
enum VPNState { case disconnected, invalid, connected }
struct Manager { var connection: Connection; struct Connection { var status: VPNState } }
struct Preferences {
    func string(forKey key: String) -> String? { nil }
    func set(_ value: String, forKey key: String) {}
}
@MainActor final class Model {
    var managersLoaded = true
    var discovering = false
    var discovery: CheckedContinuation<Void, Never>?
    var manager: Manager?
    var resetting = false
    var recovery: Recovery?
    var pendingRecovery: String?
    var recoveryRequest: (source: String, replacing: Bool)?
    var recoveryOfferSequence: UInt64 = 0
    var importProgress: ImportProgress?
    var subscriptionLoading = false
    var replacingSubscription = false
    var subscriptionError: String?
    var recoveryCancelled = false
    var subscription: PrototypeSubscription
    var retainedModeTitle: String?
    var modeTitle = "Test"
    var routingMode = PrototypeRoutingMode.enabled
    let routingPreferenceKey = "test.routing"
    let preferences = Preferences()
    let store: PrototypeSubscriptionStore
    init(_ cache: URL, saved: PrototypeSubscription) throws {
        subscription = saved
        try JSONEncoder().encode(saved).write(to: cache)
        store = PrototypeSubscriptionStore(cacheURL: cache, download: { source in
            if source == saved.sourceURL { throw URLError(.timedOut) }
            return PrototypeSubscription(uiDocument: saved.uiDocument, updatedAt: Date(), sourceURL: source)
        })
        try store.load()
    }
    func loadVPN() async {
        discovering = true
        await withCheckedContinuation { discovery = $0 }
        managersLoaded = true
    }
    func synchronizeDeviceAccess() async {}
    func advanceRecovery(from: RecoveryStep, to: RecoveryStep) {}
    func chooseInitialMode() {}
    static func hasNetworkPath() async -> Bool { true }
''' + methods + r'''
}
@main struct Checks {
    @MainActor static func main() async throws {
        let cache = URL(fileURLWithPath: CommandLine.arguments[1])
        let document = try PrototypeUIDocument.decode(Data(#"{"schemaVersion":1,"blocks":[],"pages":[]}"#.utf8))
        let saved = PrototypeSubscription(serviceWDTT: .init(revision: 1, link: "wdtt://fixture.invalid:443:51820:1080:test:call"),
                                          uiDocument: document, updatedAt: .distantPast, sourceURL: "https://fixture.invalid/saved")
        let model = try Model(cache, saved: saved)
        if CommandLine.arguments[2] == "cancel-replacement" {
            let original = try Data(contentsOf: cache)
            model.managersLoaded = false
            let submit = Task { await model.replaceSubscription("https://fixture.invalid/replacement") }
            while !model.discovering { await Task.yield() }
            model.cancelSubscriptionReplacement()
            model.discovery?.resume()
            let savedReplacement = await submit.value
            precondition(!savedReplacement, "cancelled replacement succeeded after discovery")
            let persisted = try Data(contentsOf: cache)
            precondition(persisted == original, "cancelled replacement changed the saved subscription")
            let retry = await model.replaceSubscription("https://fixture.invalid/replacement")
            precondition(retry, "a new submission was blocked after cancellation")
        } else {
            model.manager = Manager(connection: .init(status: .connected))
            await model.refreshSubscription()
            precondition(model.recovery == nil, "automatic refresh offered blocking recovery")
            precondition(model.subscriptionError != nil, "automatic refresh did not report its failure")
            await model.refreshSubscription(force: true)
            precondition(model.recovery?.offered == true, "manual refresh did not offer service recovery")
        }
        print("PASS")
    }
}
'''
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        folder = Path(temporary.name)
        source = folder / 'checks.swift'
        source.write_text(production_sources() + harness)
        cls.executable = folder / 'checks'
        result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                                 str(source), '-o', str(cls.executable)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_case(self, case):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary) / 'snapshot.json'
            result = subprocess.run([str(self.executable), str(cache), case], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS', result.stdout)

    def test_cancelling_replacement_while_discovering_vpn_preserves_saved_subscription(self):
        self.run_case('cancel-replacement')

    def test_only_manual_refresh_can_offer_blocking_recovery(self):
        self.run_case('refresh-recovery')
