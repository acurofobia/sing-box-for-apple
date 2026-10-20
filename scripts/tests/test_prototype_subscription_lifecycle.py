"""Atomic cache and cancellation tests against the production Swift store."""
from pathlib import Path
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
  var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
  var provisioning = raw["vlessProvisioning"] as! [String: Any]
  var nodes = provisioning["outbounds"] as! [[String: Any]]
  nodes[0]["detour"] = "direct"
  provisioning["outbounds"] = nodes
  raw["vlessProvisioning"] = provisioning
  try JSONSerialization.data(withJSONObject: raw).write(to: cache)
  do { try restored.load(); fatalError("corrupt cached outbound accepted") } catch {}
  print("PASS")
 }
}
'''


class LifecycleTests(unittest.TestCase):
    def test_atomic_snapshot_cancelled_and_stale_responses_and_legacy_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / 'main.swift'
            files = ['Library/Network/VKTurnConfiguration.swift', 'PrototypeApp/SubscriptionUIDocument.swift',
                     'PrototypeApp/Subscription.swift', 'PrototypeApp/SubscriptionLoader.swift',
                     'PrototypeApp/SubscriptionStore.swift']
            source.write_text('\n'.join((ROOT / name).read_text().replace('import Library\n', '') for name in files) + HARNESS)
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
