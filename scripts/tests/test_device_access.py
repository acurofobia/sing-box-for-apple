"""Exercise production access decisions and cross-process credential redaction."""
import json
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import select
import threading
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHARED = ['Library/Shared/BlockingIO.swift', 'Library/Network/PrototypeRouting.swift',
          'Library/Network/SubscriptionDeviceIdentity.swift',
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
        if CommandLine.arguments.dropFirst(2).first == "record-lock" {
            let source = "https://example.org/sub/a"
            let action = CommandLine.arguments[3]
            if action == "read" {
                let data = try store.sanitizedSnapshot(Data(contentsOf: cache))
                let snapshot = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                precondition(snapshot["vkTurnLink"] == nil && snapshot["wdttAccessState"] as? String == "device_revoked")
            } else if action == "purge" {
                do {
                    try await store.withAllowedWDTT(source: source) { fatalError("WDTT was permitted after relaunch") }
                } catch SubscriptionDeviceAccessError.denied {}
                try await store.purgeRuntimeIfDenied(source: source)
            } else if action == "read-key" {
                do {
                    _ = try await store.withAllowedWDTT(source: source) {
                        print("reading")
                        fflush(stdout)
                        _ = readLine()
                        return "fixture"
                    }
                    fatalError("returned a key after a concurrent revocation")
                } catch SubscriptionDeviceAccessError.denied {}
            } else {
                let state = action == "allow" || action == "writer-timeout" ? "allowed" : "device_revoked"
                let revision = CommandLine.arguments[4]
                let decision = try SubscriptionDeviceAccessDecision.decode(Data("{\"schemaVersion\":1,\"hwid\":\"\(hwid)\",\"state\":\"\(state)\",\"revision\":\(revision)}".utf8), hwid: hwid)
                if action == "cancel-denial" {
                    let pending = Task {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return try await store.record(decision, source: source)
                    }
                    do { _ = try await pending.value; fatalError("cancellation did not interrupt cleanup") }
                    catch is CancellationError {}
                } else if action == "writer-timeout" || action == "runtime-timeout" {
                    do {
                        if action == "writer-timeout" {
                            _ = try await store.record(decision, source: source)
                        } else {
                            try await store.withAllowedWDTT(source: source) { fatalError("acquired a busy lock") }
                        }
                        fatalError("expected the busy lock to time out")
                    } catch let error as POSIXError where error.code == .ETIMEDOUT {}
                } else {
                    _ = try await store.record(decision, source: source)
                }
            }
            return
        }
        if CommandLine.arguments.count > 2 {
            let base = CommandLine.arguments[2]
            let headers = ["x-hwid":hwid, "x-device-os":"iOS", "x-ver-os":"27.0", "x-device-model":"iPhone14,5"]
            let applicationStore = await PrototypeSubscriptionStore(cacheURL:cache, download: { source in
                try await PrototypeSubscriptionLoader.download(source, deviceHeaders:headers, accessStore:store)
            })
            if CommandLine.arguments.last == "check-io-error" {
                do {
                    try await store.withAllowedWDTT(source: base + "/sub") { fatalError("unreadable record permitted WDTT") }
                } catch is CocoaError {}
                do {
                    _ = try await applicationStore.update(base + "/sub", replacing: true)
                    fatalError("unreadable record was replaced")
                } catch is CocoaError {}
                return
            }
            if CommandLine.arguments.last == "check-quarantine" {
                do { try await applicationStore.load() } catch { print("Could not restore subscription"); exit(1) }
                let saved = await applicationStore.snapshot
                precondition(saved.isComplete && saved.isAvailable(optionID: "option01"))
                precondition(saved.vkTurnLink == nil && saved.wdttAccessState?.isDenied == true)
                precondition(!saved.isAvailable(optionID: "option02"))
                precondition(saved.uiDocument?.block("block04")?.items?.last?.state == .unavailable)
                do {
                    try await store.withAllowedWDTT(source: base + "/sub") { fatalError("WDTT was permitted") }
                    fatalError("missing WDTT denial")
                } catch SubscriptionDeviceAccessError.denied {}
                return
            }
            if CommandLine.arguments.last == "routing" {
                // Migrate a cache created by an app with unbound system VPN preferences.
                try JSONSerialization.data(withJSONObject: ["sourceURL": base + "/sub", "warnings": []]).write(to: cache)
                try await applicationStore.load()
            }
            _ = try await applicationStore.update(base + "/sub", replacing:true)
            if CommandLine.arguments.last == "routing" {
                let source = base + "/sub"
                let subscription = await applicationStore.snapshot
                guard let original = subscription.routing else { fatalError("missing fixture routing") }
                let selected = try PrototypeRouting.selection(mode: .enabled, routing: original, source: source, snapshotURL: cache, bundle: .main)
                let saved = try PrototypeRouting.runtime(selection: selected, snapshotURL: cache, bundle: .main, expectedSource: PrototypeRouting.sourceID(source))
                let legacyRoute = Data(#"{"rules":[],"rule_set":[]}"#.utf8)
                let migrated = try PrototypeRouting.runtime(selection: legacyRoute, snapshotURL: cache, bundle: .main)
                precondition(migrated.profile.route == saved.profile.route)
                let originalRoute = try JSONSerialization.jsonObject(with: saved.profile.route) as! [String: Any]
                let originalFiles = originalRoute["rule_set"] as! [[String: String]]
                let paths = originalFiles.map { URL(fileURLWithPath: $0["path"]!) }
                let frozen = try paths.map { try Data(contentsOf: $0) }
                do { _ = try await applicationStore.update(source, replacing: false); fatalError("revision collision accepted") } catch {}
                try FileManager.default.removeItem(at: paths[0])
                let manifestFile = paths[0].deletingLastPathComponent().appendingPathComponent("manifest.json")
                try Data("damaged".utf8).write(to: manifestFile)

                _ = try await applicationStore.update(source, replacing: false)
                let repaired = try Data(contentsOf: paths[0])
                precondition(repaired == frozen[0], "same revision did not repair missing SRS")
                let repairedManifest = try Data(contentsOf: manifestFile)
                precondition(repairedManifest == original, "same revision did not repair manifest")
                _ = try await applicationStore.update(source, replacing: false)
                let retainedPin = try paths.map { try Data(contentsOf: $0) }
                precondition(retainedPin == frozen, "active pinned revision was pruned")
                let refreshed = try PrototypeRouting.runtime(selection: selected, snapshotURL: cache, bundle: .main, expectedSource: PrototypeRouting.sourceID(source))
                precondition(saved.profile.route != refreshed.profile.route && !refreshed.profile.reverseMapping)
                let afterUpdate = try paths.map { try Data(contentsOf: $0) }
                precondition(frozen == afterUpdate)
                let updated = await applicationStore.snapshot
                _ = try await applicationStore.update(source, replacing: false)
                precondition(!FileManager.default.fileExists(atPath: paths[0].path), "unreferenced revision retained")
                let retained = await applicationStore.snapshot
                precondition(retained.routing == updated.routing, "legacy response dropped same-source policy")
                do { _ = try await applicationStore.update(source, replacing: false); fatalError("accepted bad routing") } catch {}
                let afterBad = try PrototypeRouting.runtime(selection: selected, snapshotURL: cache, bundle: .main, expectedSource: PrototypeRouting.sourceID(source))
                precondition(afterBad.profile.route == refreshed.profile.route)
                let access = try store.decision(forSource: source)
                precondition(access?.state == .revoked, "invalid routing masked revocation")
                _ = try await applicationStore.update(base + "/other", replacing: true)
                let other = await applicationStore.snapshot
                precondition(other.routing == nil, "previous subscription routing leaked")
                _ = try await applicationStore.update(base + "/other", replacing: false)
                let fresh = try PrototypeRouting.runtime(selection: legacyRoute, snapshotURL: cache, bundle: .main, expectedSource: PrototypeRouting.sourceID(base + "/other"))
                precondition(fresh.source == base + "/other")
                do { _ = try PrototypeRouting.runtime(selection: legacyRoute, snapshotURL: cache, bundle: .main); fatalError("old manager reused across replacement") } catch {}
                precondition(other.allowsLegacyTransport == false)

                do { _ = try PrototypeRouting.runtime(selection: selected, snapshotURL: cache, bundle: .main); fatalError("stale source selection accepted") } catch {}
            }
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
        _ = try await store.record(decision("device_revoked", 3), source: source)
        let redacted = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
        precondition(redacted["vkTurnLink"] == nil, "revoked credential retained")
        precondition(redacted["vlessOutbound"] as? String == "keep-vless")
        let late = try await store.record(decision("allowed", 2), source: source)
        precondition(late.state == .revoked, "stale allow restored access")
        _ = try await store.commitSnapshot(JSONSerialization.data(withJSONObject: original))
        let afterLateCommit = try JSONSerialization.jsonObject(with: Data(contentsOf:cache)) as! [String: Any]
        precondition(afterLateCommit["vkTurnLink"] == nil, "late provisioning restored credential")
        var downgraded = original
        downgraded.removeValue(forKey: "deviceAccess")
        _ = try await store.commitSnapshot(JSONSerialization.data(withJSONObject:downgraded))
        let afterDowngrade = try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String: Any]
        precondition(afterDowngrade["vkTurnLink"] == nil, "legacy response bypassed revocation")
        let restarted = SubscriptionDeviceAccessStore(cacheURL: cache)
        let restoredDecision = try restarted.decision(forSource: source)
        precondition(restoredDecision?.state == .revoked)
        let beforeOther = try Data(contentsOf: cache)
        _ = try await store.record(decision("device_revoked", 10), source: other)
        let afterOther = try Data(contentsOf: cache)
        precondition(beforeOther == afterOther, "other subscription rewrote cache")
        // Switching subscriptions must not drop the per-source denial.
        try JSONSerialization.data(withJSONObject:["sourceURL":other]).write(to:cache)
        try await store.purgeRuntimeIfDenied(source:source)
        var oldManifest = original
        oldManifest.removeValue(forKey:"deviceAccess")
        let returned = try await store.commitSnapshot(JSONSerialization.data(withJSONObject:oldManifest))
        let returnedRoot = try JSONSerialization.jsonObject(with:returned) as! [String: Any]
        precondition(returnedRoot["vkTurnLink"] == nil, "switching subscriptions bypassed denial")
        // Clearing a snapshot (settings reset) cannot erase the tombstone.
        try FileManager.default.removeItem(at:cache)
        let reimported = try await store.commitSnapshot(JSONSerialization.data(withJSONObject:oldManifest))
        let reimportedRoot = try JSONSerialization.jsonObject(with:reimported) as! [String: Any]
        precondition(reimportedRoot["vkTurnLink"] == nil, "reset and legacy reimport bypassed denial")
        do { try await store.withAllowedWDTT(source:source) { fatalError("revoked runtime prepared") }; fatalError("revoked runtime accepted") } catch {}
        _ = try await store.record(decision("allowed", 4), source: source)
        let allowedDecision = try store.decision(forSource: source)
        precondition(allowedDecision?.state == .allowed)

        let tariffMessage = "Смените тариф, чтобы получить доступ к обходу белых списков"
        let tariffButton = ["id": "button05", "title": "Сменить тариф"]
        var tariffSnapshot = original
        let choice: [String: Any] = ["id": "option02", "state": "restricted", "stateText": tariffMessage, "buttons": [tariffButton]]
        tariffSnapshot["uiDocument"] = ["blocks": [["id": "block04", "items": [choice]]]]
        let encodedTariff = try JSONSerialization.data(withJSONObject: tariffSnapshot)
        func renderedChoice(_ data: Data) throws -> [String: Any] {
            let snapshot = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(snapshot["vkTurnLink"] == nil, "denied credential retained")
            let document = snapshot["uiDocument"] as! [String: Any]
            let blocks = document["blocks"] as! [[String: Any]]
            let items = blocks[0]["items"] as! [[String: Any]]
            return items[0]
        }
        _ = try await store.record(decision("not_allowed", 5), source: source)
        let restricted = try await renderedChoice(store.commitSnapshot(encodedTariff))
        precondition(restricted["state"] as? String == "restricted", "tariff restriction overwritten")
        precondition(restricted["stateText"] as? String == tariffMessage)
        precondition(restricted["buttons"] as? [[String: String]] == [tariffButton])
        for (state, revision) in [("device_limit_reached", 6), ("device_revoked", 7)] {
            let denial = try await store.record(decision(state, revision), source: source)
            let blocked = try await renderedChoice(store.commitSnapshot(encodedTariff))
            precondition(blocked["state"] as? String == "unavailable")
            precondition(blocked["stateText"] as? String == denial.state.message)
            precondition((blocked["buttons"] as? [[String: String]])?.isEmpty == true)
        }
        for raw in ["{}", "{\"schemaVersion\":1,\"hwid\":\"wrong\",\"state\":\"device_revoked\",\"revision\":5}", "{\"schemaVersion\":1,\"hwid\":\"\(hwid)\",\"state\":\"allowed\",\"revision\":-1}"] {
            do { _ = try SubscriptionDeviceAccessDecision.decode(Data(raw.utf8), hwid: hwid); fatalError("invalid response accepted") } catch {}
        }

        print("PASS")
    }
}
'''


def production_sources(clear_runtime=''):
    files = ['Library/Network/VKTurnConfiguration.swift', 'PrototypeApp/SubscriptionUIDocument.swift',
             'PrototypeApp/Subscription.swift', 'PrototypeApp/SubscriptionLoader.swift', 'PrototypeApp/SubscriptionStore.swift']
    from test_prototype_startup_cancellation import method
    sources = [(ROOT / name).read_text().replace('import Library\n', '') for name in files]
    clear = method(sources[0], '    public static func clear() throws')
    sources[0] = sources[0].replace(clear, '    public static func clear() throws {' + clear_runtime + '}')
    return shared_sources() + '\n'.join(sources)


class DeviceAccessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.folder.cleanup)
        folder = Path(cls.folder.name)
        source = folder / 'checks.swift'
        # Observe key removal without touching the machine's Keychain.
        clear_runtime = '''
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try Data().write(to: directory.appendingPathComponent("runtime-cleared"))
        '''
        source.write_text(production_sources(clear_runtime) + HARNESS)
        cls.executable = folder / 'checks'
        result = subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(folder/'modules'),str(source),'-o',str(cls.executable)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def test_revocation_persists_redacts_only_matching_subscription_and_rejects_stale_allow(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([str(self.executable), directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)

    def test_runtime_lock_cannot_delay_decisions_and_cancelled_denial_is_enforced_on_relaunch(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            cache = directory / 'snapshot.json'
            marker = directory / 'runtime-cleared'
            original = json.dumps({'sourceURL': 'https://example.org/sub/a', 'vkTurnLink': 'fixture',
                                   'vlessOutbound': 'vless fixture'}).encode()
            cache.write_bytes(original)
            command = [str(self.executable), temporary, 'record-lock']

            def run(*arguments):
                result = subprocess.run(command + list(arguments), capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)

            with (directory / 'device-access.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                run('allow', '1')
                run('cancel-denial', '2')
                run('read')
                self.assertEqual(cache.read_bytes(), original)
                self.assertFalse(marker.exists())
            run('purge')
            self.assertNotIn('vkTurnLink', json.loads(cache.read_bytes()))
            self.assertEqual(json.loads(cache.read_bytes())['vlessOutbound'], 'vless fixture')
            self.assertTrue(marker.exists())

            marker.unlink()
            cache.write_bytes(original)
            ledger = next(directory.glob('device-access-*.json'))
            with (directory / 'device-access.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                with subprocess.Popen(command + ['deny', '3']) as pending:
                    try:
                        deadline = time.monotonic() + 3
                        while json.loads(ledger.read_bytes())['revision'] != 3 and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertEqual(json.loads(ledger.read_bytes())['revision'], 3)
                        run('allow', '4')
                    finally:
                        fcntl.flock(lock, fcntl.LOCK_UN)
                    self.assertEqual(pending.wait(timeout=3), 0)
            self.assertEqual(json.loads(ledger.read_bytes())['state'], 'allowed')
            self.assertEqual(cache.read_bytes(), original)
            self.assertFalse(marker.exists(), 'late cleanup cleared a newly allowed subscription')
            with subprocess.Popen(command + ['read-key'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as reading:
                try:
                    self.assertTrue(select.select([reading.stdout], [], [], 3)[0])
                    self.assertEqual(reading.stdout.readline().strip(), 'reading')
                    run('cancel-denial', '5')
                finally:
                    reading.communicate(input='done\n', timeout=3)
                self.assertEqual(reading.returncode, 0)

    def test_runtime_and_decision_lock_waits_have_deadlines(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            command = [str(self.executable), temporary, 'record-lock']
            with (directory / 'device-access.lock').open('a') as runtime, (directory / 'device-access-record.lock').open('a') as writer:
                fcntl.flock(runtime, fcntl.LOCK_EX)
                fcntl.flock(writer, fcntl.LOCK_EX)
                with subprocess.Popen(command + ['runtime-timeout', '1']) as r, subprocess.Popen(command + ['writer-timeout', '1']) as w:
                    try:
                        self.assertEqual(r.wait(timeout=21), 0)
                        self.assertEqual(w.wait(timeout=21), 0)
                    finally:
                        fcntl.flock(runtime, fcntl.LOCK_UN)
                        fcntl.flock(writer, fcntl.LOCK_UN)

    def test_independent_transports_survive_unverified_device_record_and_damaged_previous_snapshot(self):
        from copy import deepcopy
        from test_prototype_subscription import CONFIG, LINK
        from test_prototype_subscription_ui import DOCUMENT

        ui = deepcopy(DOCUMENT)
        ui['blocks'][1]['items'].append({'id': 'option02', 'title': 'WDTT', 'text': '',
                                         'state': 'available', 'buttons': []})
        decision = {'schemaVersion': 1, 'revision': 5, 'hwid': 'a' * 64, 'state': 'allowed'}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                payload = {'/config': CONFIG, '/ui': ui, '/sub': {
                    'sing_box_url': base + '/config', 'ui_url': base + '/ui', 'ui_token': 'synthetic_ui_token_123',
                    'vk_turn_link': LINK, 'device_access': decision}}[self.path]
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header('X-Subscription-Format', 'vipin-v1')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server, tempfile.TemporaryDirectory() as directory:
            base = f'http://127.0.0.1:{server.server_port}'
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                def run(mode):
                    result = subprocess.run([str(self.executable), directory, base, mode], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

                run('loader')
                cache = Path(directory) / 'snapshot.json'
                original = cache.read_bytes()
                record = next(Path(directory).glob('device-access-*.json'))
                verified = record.read_bytes()
                self.assertEqual(json.loads(original)['vkTurnLink'], LINK)
                oversized = verified.ljust(16 * 1024 + 1, b' ')
                for unknown in [b'{', json.dumps(dict(decision, schemaVersion=2)).encode(), oversized]:
                    with self.subTest(record=unknown[:20]):
                        cache.write_bytes(original)
                        record.write_bytes(unknown)
                        run('check-quarantine')
                        ui['blocks'][0]['title'] = 'Updated plan'
                        run('loader')
                        saved = json.loads(cache.read_bytes())
                        self.assertEqual(saved['uiDocument']['blocks'][0]['title'], 'Updated plan')
                        self.assertNotIn('vkTurnLink', saved)
                        self.assertEqual(record.read_bytes(), unknown)
                        run('check-quarantine')
                with self.subTest(snapshot='truncated'):
                    record.write_bytes(verified)
                    cache.write_bytes(b'{')
                    marker = Path(directory) / 'runtime-cleared'
                    marker.unlink(missing_ok=True)
                    decision.update(state='device_revoked', revision=6)
                    run('loader')
                    self.assertFalse(marker.exists(), 'cleared the runtime key without knowing the old snapshot owner')
                    self.assertEqual(json.loads(record.read_bytes()), decision)
                    run('check-quarantine')
                    run('loader')
                    self.assertTrue(marker.exists(), 'failed to clear the key for the verified snapshot owner')
                with self.subTest(record='unreadable'):
                    record.unlink()
                    record.mkdir()
                    original = cache.read_bytes()
                    run('check-io-error')
                    self.assertTrue(record.is_dir())
                    self.assertEqual(cache.read_bytes(), original)
            finally:
                server.shutdown()
                worker.join()

    def test_shared_v2_fixture_refresh_settings_start_revocation_and_scope(self):
        from copy import deepcopy
        fixture = json.loads((ROOT / 'scripts/tests/fixtures/vipin-v2-routing.json').read_text())
        updated = deepcopy(fixture)
        profile = updated['routing']['profiles']['roskomvpn']
        profile['rules'][3]['domain'] = ['updated.routing.invalid']
        updated['routing']['revision'] = 'f' * 64
        legacy = deepcopy(updated)
        del legacy['routing']
        bad = deepcopy(updated)
        bad['device_access'].update(state='device_revoked', revision=fixture['device_access']['revision'] + 1)
        next(iter(bad['routing']['assets'].values()))['sha256'] = '0' * 64
        collision = deepcopy(updated)
        collision['routing']['revision'] = fixture['routing']['revision']
        responses = iter([fixture, collision, fixture, updated, legacy, bad, legacy, fixture])

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps(next(responses)).encode()
                self.send_response(200)
                self.send_header('X-Subscription-Format', 'vipin-v2')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([str(self.executable), directory, f'http://127.0.0.1:{server.server_port}', 'routing'],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_revocation_removes_key_even_when_later_configuration_fails(self):
        from test_prototype_subscription import LINK, CONFIG, UI_DOCUMENT
        state = {'revoked':False, 'bad_url':False, 'status':200, 'bundle':False}
        events = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                events.append(self.path)
                status = state["status"]
                if self.path == '/sub':
                    payload = {'sing_box_url':base+'/config','ui_url':base+'/ui','ui_token':'synthetic_ui_token_123','vk_turn_link':LINK,
                               'device_access':{'schemaVersion':1,'hwid':'a'*64,'state':'device_revoked' if state['revoked'] else 'allowed','revision':3 if state['bundle'] else 2 if state['revoked'] else 1}}
                    if state['bad_url']: payload['sing_box_url']='https://foreign.example/config'
                elif self.path == '/config':
                    status = 503 if state['revoked'] else 200
                    payload = CONFIG
                else: payload = UI_DOCUMENT
                if state['bundle']:
                    payload = {'device_access': payload['device_access'], 'error': 'vless_temporarily_unavailable'}
                body = json.dumps(payload).encode()
                self.send_response(status); self.send_header('X-Subscription-Format','vipin-v2' if state['bundle'] else 'vipin-v1')
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
                state.update(bundle=True, status=503)
                cache.write_bytes(original)
                events.clear()
                self.assertNotEqual(run().returncode, 0)
                saved = json.loads(cache.read_text())
                record = next(Path(directory).glob('device-access-*.json'))
                self.assertEqual(json.loads(record.read_text())['revision'], 3)
                self.assertEqual(events, ['/sub'])
                self.assertEqual(saved['wdttAccessState'], 'device_revoked')
                self.assertNotIn('vkTurnLink', saved)
                self.assertIsNotNone(saved['vlessOutbound'])
        finally:
            server.shutdown(); server.server_close(); thread.join()
