"""Exercise production access decisions and cross-process credential redaction."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHARED = ['Library/Network/SubscriptionDeviceIdentity.swift',
          'Library/Network/SubscriptionDeviceAccess.swift']


def shared_sources():
    return '\n'.join((ROOT / name).read_text().replace('import Library\n', '') for name in SHARED)


HARNESS = r'''
@main struct Checks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let cache = directory.appendingPathComponent("snapshot.json")
        let store = SubscriptionDeviceAccessStore(cacheURL: cache)
        let hwid = String(repeating: "a", count: 64)
        if CommandLine.arguments.count > 2 {
            let base = CommandLine.arguments[2]
            let headers = ["x-hwid":hwid, "x-device-os":"iOS", "x-ver-os":"27.0", "x-device-model":"iPhone14,5"]
            let applicationStore = await PrototypeSubscriptionStore(cacheURL:cache, download: { source in
                try await PrototypeSubscriptionLoader.download(source, deviceHeaders:headers, accessStore:store)
            })
            _ = try await applicationStore.update(base + "/sub", replacing:true)
            print("DOWNLOADED")
            return
        }
        let source = "https://example.org/sub/a"
        let other = "https://example.org/sub/b"
        func decision(_ state: String, _ revision: Int) throws -> SubscriptionDeviceAccessDecision {
            try SubscriptionDeviceAccessDecision.decode(Data("{\"schemaVersion\":1,\"hwid\":\"\(hwid)\",\"state\":\"\(state)\",\"revision\":\(revision)}".utf8), hwid: hwid)
        }
        let original: [String: Any] = ["sourceURL":source, "vkTurnLink":"secret-wdtt", "vlessOutbound":"keep-vless", "uiToken":"keep-token"]
        try JSONSerialization.data(withJSONObject: original).write(to: cache)
        _ = try store.record(decision("device_revoked", 3), source: source)
        let redacted = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
        precondition(redacted["vkTurnLink"] == nil, "revoked credential retained")
        precondition(redacted["vlessOutbound"] as? String == "keep-vless")
        let late = try store.record(decision("allowed", 2), source: source)
        precondition(late.state == .revoked, "stale allow restored access")
        _ = try store.commitSnapshot(JSONSerialization.data(withJSONObject: original))
        let afterLateCommit = try JSONSerialization.jsonObject(with: Data(contentsOf:cache)) as! [String: Any]
        precondition(afterLateCommit["vkTurnLink"] == nil, "late provisioning restored credential")
        var downgraded = original
        downgraded.removeValue(forKey: "deviceAccess")
        _ = try store.commitSnapshot(JSONSerialization.data(withJSONObject:downgraded))
        let afterDowngrade = try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String: Any]
        precondition(afterDowngrade["vkTurnLink"] == nil, "legacy response bypassed revocation")
        let restarted = SubscriptionDeviceAccessStore(cacheURL: cache)
        let restoredDecision = try restarted.decision(forSource: source)
        precondition(restoredDecision?.state == .revoked)
        let beforeOther = try Data(contentsOf: cache)
        _ = try store.record(decision("device_revoked", 10), source: other)
        let afterOther = try Data(contentsOf: cache)
        precondition(beforeOther == afterOther, "other subscription rewrote cache")
        // Switching subscriptions must not drop the per-source denial.
        try JSONSerialization.data(withJSONObject:["sourceURL":other]).write(to:cache)
        try store.purgeRuntimeIfDenied(source:source)
        var oldManifest = original
        oldManifest.removeValue(forKey:"deviceAccess")
        let returned = try store.commitSnapshot(JSONSerialization.data(withJSONObject:oldManifest))
        let returnedRoot = try JSONSerialization.jsonObject(with:returned) as! [String: Any]
        precondition(returnedRoot["vkTurnLink"] == nil, "switching subscriptions bypassed denial")
        // Clearing a snapshot (settings reset) cannot erase the tombstone.
        try FileManager.default.removeItem(at:cache)
        let reimported = try store.commitSnapshot(JSONSerialization.data(withJSONObject:oldManifest))
        let reimportedRoot = try JSONSerialization.jsonObject(with:reimported) as! [String: Any]
        precondition(reimportedRoot["vkTurnLink"] == nil, "reset and legacy reimport bypassed denial")
        do { try store.withAllowedWDTT(source:source) { fatalError("revoked runtime prepared") }; fatalError("revoked runtime accepted") } catch {}
        _ = try store.record(decision("allowed", 4), source: source)
        let allowedDecision = try store.decision(forSource: source)
        precondition(allowedDecision?.state == .allowed)
        for raw in ["{}", "{\"schemaVersion\":1,\"hwid\":\"wrong\",\"state\":\"device_revoked\",\"revision\":5}", "{\"schemaVersion\":1,\"hwid\":\"\(hwid)\",\"state\":\"allowed\",\"revision\":-1}"] {
            do { _ = try SubscriptionDeviceAccessDecision.decode(Data(raw.utf8), hwid: hwid); fatalError("invalid response accepted") } catch {}
        }

        print("PASS")
    }
}
'''


def production_sources():
    files = ['Library/Network/VKTurnConfiguration.swift', 'PrototypeApp/SubscriptionUIDocument.swift',
             'PrototypeApp/Subscription.swift', 'PrototypeApp/SubscriptionLoader.swift', 'PrototypeApp/SubscriptionStore.swift']
    from test_prototype_startup_cancellation import method
    sources = [(ROOT / name).read_text().replace('import Library\n', '') for name in files]
    clear = method(sources[0], '    public static func clear() throws')
    sources[0] = sources[0].replace(clear, '    public static func clear() throws {}')
    return shared_sources() + '\n'.join(sources)


class DeviceAccessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.folder.cleanup)
        folder = Path(cls.folder.name)
        source = folder / 'checks.swift'
        source.write_text(production_sources() + HARNESS)
        cls.executable = folder / 'checks'
        result = subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(folder/'modules'),str(source),'-o',str(cls.executable)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def test_revocation_persists_redacts_only_matching_subscription_and_rejects_stale_allow(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([str(self.executable), directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)

    def test_revocation_removes_key_even_when_later_configuration_fails(self):
        from test_prototype_subscription import LINK, CONFIG, UI_DOCUMENT
        state = {'revoked':False, 'bad_url':False, 'status':200}
        events = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                events.append(self.path)
                status = state["status"]
                if self.path == '/sub':
                    payload = {'sing_box_url':base+'/config','ui_url':base+'/ui','ui_token':'synthetic_ui_token_123','vk_turn_link':LINK,
                               'device_access':{'schemaVersion':1,'hwid':'a'*64,'state':'device_revoked' if state['revoked'] else 'allowed','revision':2 if state['revoked'] else 1}}
                    if state['bad_url']: payload['sing_box_url']='https://foreign.example/config'
                elif self.path == '/config':
                    status = 503 if state['revoked'] else 200
                    payload = CONFIG
                else: payload = UI_DOCUMENT
                body = json.dumps(payload).encode()
                self.send_response(status); self.send_header('X-Subscription-Format','vipin-v1')
                self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
            def log_message(self,*_): pass
        server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        try:
            with tempfile.TemporaryDirectory() as directory:
                def run(): return subprocess.run([str(self.executable),directory,base,'loader'],capture_output=True,text=True)
                result=run(); self.assertEqual(result.returncode,0,result.stderr)
                cache=Path(directory)/'snapshot.json'
                self.assertEqual(json.loads(cache.read_text())['vkTurnLink'],LINK)
                self.assertEqual(events, ['/sub', '/config', '/ui'])
                original = cache.read_bytes()
                state['status'] = 503
                self.assertNotEqual(run().returncode,0)
                self.assertEqual(cache.read_bytes(), original)
                state['status'] = 200
                state['revoked']=True
                self.assertNotEqual(run().returncode,0)
                saved=json.loads(cache.read_text())
                self.assertNotIn('vkTurnLink',saved)
                self.assertEqual(saved['wdttAccessState'],'device_revoked')
                self.assertIsNotNone(saved.get('vlessOutbound'))
                state['bad_url']=True
                # A separate enrolled fixture verifies denial before unrelated URL validation.
                cache.write_text(json.dumps(dict(saved, vkTurnLink=LINK)))
                self.assertNotEqual(run().returncode,0)
                self.assertNotIn('vkTurnLink',json.loads(cache.read_text()))
        finally:
            server.shutdown(); server.server_close(); thread.join()
