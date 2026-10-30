"""Run the production Swift importer and HTTP client with synthetic credentials."""
from test_device_access import shared_sources
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
NODE = {'type': 'vless', 'tag': 'R3-N1', 'server': 'example.org', 'server_port': 443,
        'uuid': 'bf000d23-0752-40b4-affe-68f7707a9661', 'tls': {'enabled': True}}
LINK = 'wdtt://example.org:443:a:b:password:call'
CONFIG = {'route': {'final': 'discard'}, 'dns': {'final': 'discard'},
          'inbounds': [{'type': 'tun'}], 'outbounds': [NODE]}
PAYLOAD = {'sing_box_url': 'http://localhost/config', 'vk_turn_link': LINK, 'ui_url': 'http://localhost/ui', 'ui_token': 'synthetic_ui_token_123'}
UI_DOCUMENT = {'schemaVersion': 1, 'blocks': [], 'pages': []}
HARNESS = r'''
@main
struct Checks {
    static func main() async throws {
        let result: PrototypeSubscription
        if CommandLine.arguments[1] == "deeplink" {
            do {
                guard let link = URL(string: CommandLine.arguments[2]) else { exit(1) }
                print(try PrototypeDeepLink.subscriptionSource(from: link))
            } catch { print("invalid"); exit(1) }
            return
        }
        if CommandLine.arguments[1] == "policy" {
            let doc = try PrototypeUIDocument.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let snapshot = PrototypeSubscription(uiURL: "http://localhost/ui", uiDocument: doc, updatedAt: Date(), sourceURL: "synthetic", vlessOutbound: Data(), vkTurnLink: "synthetic")
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["vless": snapshot.isAvailable(optionID: "option01"), "vk": snapshot.isAvailable(optionID: "option02"), "auto": snapshot.isAvailable(optionID: "option03")]), as: UTF8.self))
            return
        }
        if CommandLine.arguments[1] == "provisioning" {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let doc = try PrototypeSubscription.decodeVLESSProvisioning(data)
            print(String(decoding: try JSONEncoder().encode(doc), as: UTF8.self))
            return
        }
        if CommandLine.arguments[1] == "download" {
            result = try await PrototypeSubscriptionLoader.download(CommandLine.arguments[2], deviceHeaders: ["x-hwid": String(repeating: "a", count: 64), "x-device-os": "iOS", "x-ver-os": "27.0", "x-device-model": "iPhone14,5"])
        } else {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            if CommandLine.arguments[1] == "outbound" {
                result = PrototypeSubscription(vlessOutbound: try PrototypeSubscription.extractVLESS(data))
            } else {
                result = try PrototypeSubscription.decode(data)
            }
        }
        // Exercise the cache representation as well as response decoding.
        let cached = try JSONDecoder().decode(PrototypeSubscription.self, from: JSONEncoder().encode(result))
        let node = try cached.vlessOutbound.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        let output: [String: Any] = ["provisioningState": cached.vlessProvisioning?.state ?? "", "node": node, "vk": cached.vkTurnLink ?? "", "complete": cached.isComplete, "warnings": cached.warnings.count, "configURL": (try JSONSerialization.jsonObject(with: JSONEncoder().encode(cached)) as? [String: Any])?["singBoxURL"] as? String ?? ""]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
    }
}
'''


class SubscriptionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        importer = (ROOT / 'PrototypeApp/Subscription.swift').read_text().replace('import Library\n', '')
        vk = (ROOT / 'Library/Network/VKTurnConfiguration.swift').read_text()
        source = directory / 'checks.swift'
        source.write_text(vk + shared_sources() + (ROOT / 'PrototypeApp/SubscriptionUIDocument.swift').read_text() + (ROOT / 'PrototypeApp/SubscriptionLoader.swift').read_text().replace('import Library\n', '') + importer + (ROOT / 'PrototypeApp/PrototypeDeepLink.swift').read_text() + HARNESS)
        cls.executable = directory / 'checks'
        result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(directory / 'modules'),
                                 str(source), '-o', str(cls.executable)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_payload(self, payload, mode='decode', success=True):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'input.json'
            source.write_text(json.dumps(payload))
            result = subprocess.run([str(self.executable), mode, str(source)], capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def test_subscription_deep_link_decodes_url_once_and_preserves_its_query(self):
        from urllib.parse import quote
        for source in ['https://example.org/subscription/synthetic-token',
                       'https://example.org/sub?token=a+b%2Fc&device=phone',
                       'http://localhost:18081/subscription/both']:
            with self.subTest(source=source):
                link = 'vipin://add-subscription?url=' + quote(source, safe='')
                result = subprocess.run([str(self.executable), 'deeplink', link], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), source)

    def test_subscription_deep_link_rejects_unknown_actions_and_invalid_sources(self):
        from urllib.parse import quote
        links = ['vipin://add-subscription', 'vipin://add-subscription?url=',
                 'vipin://connect?url=https%3A%2F%2Fexample.org',
                 'other://add-subscription?url=https%3A%2F%2Fexample.org',
                 'vipin://add-subscription/path?url=https%3A%2F%2Fexample.org',
                 'vipin://user@add-subscription?url=https%3A%2F%2Fexample.org',
                 'vipin://add-subscription:123?url=https%3A%2F%2Fexample.org',
                 'vipin://add-subscription?url=https%3A%2F%2Fexample.org#fragment',
                 'vipin://add-subscription?url=https%3A%2F%2Fexample.org&url=https%3A%2F%2Fother.org',
                 'vipin://add-subscription?url=https%3A%2F%2Fexample.org&extra=value']
        for source in ['file:///tmp/config', 'javascript:alert(1)', 'https://',
                       'https://user:password@example.org/sub', 'https://example.org/sub#fragment',
                       'https://example.org/sub\nheader', 'https://example.org/a b']:
            links.append('vipin://add-subscription?url=' + quote(source, safe=''))
        for link in links:
            with self.subTest(link=link):
                result = subprocess.run([str(self.executable), 'deeplink', link], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)

    def test_four_node_provisioning_validation(self):
        import copy
        nodes = [dict(NODE, tag=tag, tls={'enabled': True, 'server_name': 'example.org',
                 'utls': {'enabled': True, 'fingerprint': 'chrome'},
                 'reality': {'enabled': True, 'public_key': 'A' * 43, 'short_id': 'abcd'}})
                 for tag in ['n1', 'n2', 'n3', 'n4']]
        doc = {'schemaVersion': 1, 'kind': 'vless-failover', 'state': 'available', 'reason': None,
               'outbounds': nodes, 'failover': {'selector': 'vk-wg', 'primary': 'n1', 'backups': ['n2', 'n3', 'n4'],
               'intervalMilliseconds': 10000, 'timeoutMilliseconds': 5000, 'failureThreshold': 2, 'recoveryThreshold': 3}}
        self.assertEqual(self.run_payload(doc, mode='provisioning')['failover']['primary'], 'n1')
        for key, value in [('kind', 'other'), ('schemaVersion', 2), ('outbounds', nodes[:3])]:
            self.run_payload(dict(doc, **{key: value}), mode='provisioning', success=False)
        for key, value in [('tag', 'vk-wg'), ('tag', 'n2'), ('server_port', True), ('uuid', 'bad'), ('detour', 'direct'), ('type', 'selector')]:
            bad = copy.deepcopy(doc); bad['outbounds'][0][key] = value
            self.run_payload(bad, mode='provisioning', success=False)
        for key, value in [('primary', 'missing'), ('backups', ['n2', 'n2', 'n4']), ('failureThreshold', 1), ('selector', 'direct')]:
            bad = copy.deepcopy(doc); bad['failover'][key] = value
            self.run_payload(bad, mode='provisioning', success=False)
        for state in ['restricted', 'unavailable']:
            disabled = dict(doc, state=state, reason='not_allowed', outbounds=[], failover=None)
            self.assertEqual(self.run_payload(disabled, mode='provisioning')['outbounds'], [])
            self.run_payload(dict(disabled, outbounds=nodes), mode='provisioning', success=False)

    def test_native_failover_document_is_transactional_and_disables_explicitly(self):
        import copy
        nodes = [dict(NODE, tag=tag, tls={'enabled': True, 'server_name': 'example.org',
                 'utls': {'enabled': True, 'fingerprint': 'chrome'},
                 'reality': {'enabled': True, 'public_key': 'A' * 43, 'short_id': 'abcd'}}) for tag in ['n1','n2','n3','n4']]
        provisioning = {'schemaVersion':1,'kind':'vless-failover','state':'available','outbounds':nodes,
                       'failover':{'selector':'vk-wg','primary':'n1','backups':['n2','n3','n4'],
                       'intervalMilliseconds':10000,'timeoutMilliseconds':5000,'failureThreshold':2,'recoveryThreshold':3}}
        state = ['valid']
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/subscription':
                    payload = dict(PAYLOAD, sing_box_url=base+'/config', ui_url=base+'/ui')
                elif self.path == '/config':
                    payload = copy.deepcopy(provisioning)
                    if state[0] == 'broken': payload['failover']['primary'] = 'missing'
                    if state[0] == 'unknown': payload['kind'] = 'unsupported'
                    if state[0] == 'disabled': payload.update(state='unavailable', reason='traffic_limited', outbounds=[], failover=None)
                    if state[0] == 'error':
                        self.send_response(503); self.end_headers(); return
                else: payload = UI_DOCUMENT
                self.send_response(200)
                self.send_header('X-Subscription-Format','vipin-v1'); self.end_headers()
                self.wfile.write(json.dumps(payload).encode())
            def log_message(self,*_): pass
        server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        base = f'http://127.0.0.1:{server.server_port}'
        try:
            for variant in ['valid','broken','unknown','error','disabled']:
                state[0] = variant
                result = subprocess.run([str(self.executable),'download',base+'/subscription'],capture_output=True,text=True)
                self.assertEqual(result.returncode == 0, variant in ['valid','disabled'], variant)
                if result.returncode == 0:
                    output = json.loads(result.stdout)
                    self.assertTrue(output['complete']); self.assertIsNone(output['node'])
                    self.assertEqual(output['vk'], LINK)
                    self.assertEqual(output['provisioningState'], 'available' if variant == 'valid' else 'unavailable')
        finally:
            server.shutdown(); server.server_close()

    @unittest.skipUnless(os.environ.get('VPN_BACKEND_PYTHON'), 'Set VPN_BACKEND_PYTHON to run cross-repository contract fixture')
    def test_backend_two_users_group_change_through_swift_and_libbox(self):
        backend = Path(os.environ.get('VPN_BACKEND_ROOT', str(ROOT.parent / 'VPN/backend')))
        producer = r"""
import json
from unittest.mock import patch
from app.models.user import User
from tests.test_app_vless_subscription import VLESSSubscriptionTests, CAPS
from tests.test_xray_subscription_adapter import graph
case = VLESSSubscriptionTests('test_native_descriptor_config_ui_and_free_access')
case.setUp()
try:
    documents = []
    other = User(start_bot_date='2026-10-20', short_uuid='second-key', uuid='second-uuid', subscription_active=True,
                 subscription_type_id=case.free_id)
    case.session.add(other); case.session.commit()
    original = case.identity.return_value.model_copy(deep=True)
    async def remote(uuid):
        value=original.model_copy(deep=True)
        if uuid=='second-uuid': value.uuid=uuid; value.short_uuid='second-key'; value.external_squad_uuid='group-b'
        return value
    case.identity.side_effect=remote
    orders={'synthetic-key':('n1','n2','n3','n4'), 'second-key':('n5','n6','n7','n8')}
    async def fetch(key, **kwargs): return json.dumps(graph(orders[key])).encode()
    with patch('app.subscriptions.service.fetch_xray_subscription',side_effect=fetch):
        for key in ['synthetic-key','second-key','synthetic-key']:
            d=case.client.get('/api/sub/'+key,headers=CAPS).json()
            r=case.client.get(d['sing_box_url'],headers={**CAPS,'Authorization':'Bearer '+d['ui_token']})
            assert r.status_code==200
            documents.append(r.json())
            if key=='second-key': orders['synthetic-key']=('n3','n4','n1','n2')
        case.user.short_uuid='revoked';case.session.commit()
        assert case.client.get(d['sing_box_url'],headers={**CAPS,'Authorization':'Bearer '+d['ui_token']}).status_code==404
    print(json.dumps(documents))
finally: case.tearDown()
"""
        result = subprocess.run([os.environ['VPN_BACKEND_PYTHON'], '-c', producer], cwd=backend, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        documents = json.loads(result.stdout)
        self.assertEqual([d['failover']['primary'] for d in documents], ['n1','n5','n3'])
        for doc in documents:
            self.assertEqual(self.run_payload(doc, mode='provisioning')['failover']['primary'], doc['failover']['primary'])
        consumer = r'''
package main
import (
 "encoding/json"
 "os"
 "fmt"
 "github.com/sagernet/sing-box/protocol/vkturn"
 "github.com/sagernet/sing-box/experimental/libbox"
)
func main() {
 data,err:=os.ReadFile(os.Args[1]);if err!=nil {panic(err)}
 var docs []struct { Outbounds []json.RawMessage `json:"outbounds"`; Failover json.RawMessage `json:"failover"` }
 if err=json.Unmarshal(data,&docs);err!=nil {panic(err)}
 for _,doc:=range docs {
  var policy struct { Primary string `json:"primary"` };json.Unmarshal(doc.Failover,&policy)
  config,err:=vkturn.BuildVLESSFailoverConfiguration(json.RawMessage(`{"final":"vk-wg"}`),doc.Outbounds,policy.Primary)
  if err!=nil {panic(err)}
  if err=libbox.ValidatePriorityFailover(config,string(doc.Failover));err!=nil {panic(err)}
 }
 fmt.Println("PASS 3 personalized snapshots")
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory)
            (folder/'check.go').write_text(consumer)
            (folder/'documents.json').write_text(json.dumps(documents))
            result=subprocess.run(['go','run','-ldflags=-checklinkname=0','-tags',
                'with_wireguard,with_gvisor,with_utls,with_clash_api,with_low_memory,badlinkname,tfogo_checklinkname0',
                str(folder/'check.go'),str(folder/'documents.json')],cwd=ROOT/'upstream/sing-box',capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('PASS 3 personalized snapshots',result.stdout)

    def test_client_availability_uses_ids_and_never_activates_auto(self):
        choices = [{'id': identifier, 'title': 'renamed', 'text': '', 'state': 'available', 'buttons': []}
                   for identifier in ['option01', 'option02', 'option03']]
        doc = {'schemaVersion': 1, 'blocks': [{'id': 'block04', 'type': 'selectionList', 'items': choices}], 'pages': []}
        self.assertEqual(self.run_payload(doc, mode='policy'), {'vless': True, 'vk': True, 'auto': False})
        choices[0]['state'] = 'restricted'
        choices[1]['visible'] = False
        self.assertEqual(self.run_payload(doc, mode='policy'), {'vless': False, 'vk': False, 'auto': False})
        doc['blocks'][0]['visible'] = False
        self.assertEqual(self.run_payload(doc, mode='policy'), {'vless': False, 'vk': False, 'auto': False})

    def test_import_keeps_only_connection_parameters(self):
        result = self.run_payload(PAYLOAD)
        self.assertIsNone(result['node'])
        self.assertEqual(result['configURL'], 'http://localhost/config')
        self.assertEqual(result['vk'], LINK)
        self.assertEqual(result['warnings'], 0)

    def test_missing_connections_and_null_disable_independently(self):
        for config, link in [(None, LINK), (PAYLOAD['sing_box_url'], None), (None, None), ('', '')]:
            with self.subTest(config=config, link=link):
                result = self.run_payload(dict(PAYLOAD, sing_box_url=config, vk_turn_link=link))
                self.assertEqual(bool(result['configURL']), bool(config))
                self.assertEqual(bool(result['vk']), bool(link))
        payload = {key: value for key, value in PAYLOAD.items() if key not in ('sing_box_url', 'vk_turn_link')}
        result = self.run_payload(payload)
        self.assertIsNone(result['node'])
        self.assertEqual(result['vk'], '')

    def test_invalid_connection_does_not_disable_other_mode(self):
        result = self.run_payload(dict(PAYLOAD, vk_turn_link='invalid-link'))
        self.assertEqual(result['configURL'], 'http://localhost/config')
        self.assertEqual(result['vk'], '')
        self.assertEqual(result['warnings'], 1)
        result = self.run_payload(dict(PAYLOAD, sing_box_url='file:///private/config.json'))
        self.assertIsNone(result['node'])
        self.assertEqual(result['vk'], LINK)
        self.assertEqual(result['warnings'], 1)

    def test_ui_token_rejects_trailing_newline(self):
        self.run_payload(dict(PAYLOAD, ui_token='synthetic_ui_token_123\n'), success=False)

    def test_response_must_be_an_object(self):
        for payload in [[], None, 'invalid']:
            with self.subTest(payload=payload):
                self.run_payload(payload, success=False)

    def test_metadata_is_ignored(self):
        # Extra server metadata is ignored, never required.
        result = self.run_payload(dict(PAYLOAD, plan_name='', remaining_days=-1, schema_version=2))
        self.assertEqual(result['configURL'], 'http://localhost/config')

    def test_config_url_rejects_credentials_fragments_and_non_http_schemes(self):
        for url in ['file:///config', 'http://user:password@example.org/config',
                    'https://example.org/config#secret', 'relative/config', 42]:
            with self.subTest(url=url):
                result = self.run_payload(dict(PAYLOAD, sing_box_url=url))
                self.assertEqual(result['configURL'], '')
                self.assertEqual(result['vk'], LINK)
                self.assertEqual(result['warnings'], 1)

    def test_raw_outbound_and_single_vless_with_arbitrary_tag(self):
        self.assertEqual(self.run_payload(NODE, mode='outbound')['node'], NODE)
        node = dict(NODE, tag='my-server')
        self.assertEqual(self.run_payload({'outbounds': [node]}, mode='outbound')['node'], node)

    def test_rejects_ambiguous_or_incomplete_vless(self):
        for config in [[], {}, {'outbounds': [dict(NODE, tag='a'), dict(NODE, tag='b')]},
                       {'outbounds': [NODE, NODE]}, dict(NODE, server_port=True), dict(NODE, server_port=1.5),
                       dict(NODE, server_port=65536), dict(NODE, uuid='invalid'), dict(NODE, detour='missing')]:
            with self.subTest(config=config):
                self.run_payload(config, mode='outbound', success=False)

    def test_download_fetches_config_and_rejects_http_errors_and_redirects(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path in ['/redirect', '/config-redirect']:
                    self.send_response(302)
                    self.send_header('Location', '/config')
                    self.end_headers()
                    return
                if self.path == '/config-error':
                    self.send_response(503)
                    self.end_headers()
                    return
                if self.path == '/ui':
                    self.assert_auth = self.headers.get('Authorization')
                    payload = UI_DOCUMENT
                elif self.path in ['/config', '/config-invalid', '/config-direct']:
                    payload = CONFIG
                    if self.path == '/config-invalid':
                        payload = {'outbounds': [dict(NODE, server_port=0)]}
                    elif self.path == '/config-direct':
                        payload = {'outbounds': [{'type': 'direct'}]}
                else:
                    suffix = self.path.rsplit('/', 1)[-1]
                    config_path = '/config' if suffix == 'test-token' else '/' + suffix
                    payload = dict(PAYLOAD, sing_box_url=f'http://localhost:{self.server.server_port}' + config_path, ui_url=f'http://localhost:{self.server.server_port}/ui')
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f'http://localhost:{server.server_port}'
            result = subprocess.run([str(self.executable), 'download', url + '/subscription/test-token'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertEqual(output['node'], NODE)
            self.assertTrue(output['complete'])
            self.assertEqual(output['vk'], LINK)
            for path in ['/redirect', '/subscription/config-redirect', '/subscription/config-error']:
                with self.subTest(path=path):
                    result = subprocess.run([str(self.executable), 'download', url + path], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
            for path, warnings in [('/subscription/config-invalid', 1), ('/subscription/config-direct', 0)]:
                with self.subTest(path=path):
                    result = subprocess.run([str(self.executable), 'download', url + path], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    output = json.loads(result.stdout)
                    self.assertIsNone(output['node'])
                    self.assertEqual(output['vk'], LINK)
                    self.assertEqual(output['warnings'], warnings)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


    def test_ui_authentication_isolated_and_invalid_responses_rejected(self):
        events = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                events.append((self.path, self.headers.get('Authorization')))
                if self.path.startswith('/subscription/'):
                    endpoint = self.path.rsplit('/', 1)[-1]
                    payload = dict(PAYLOAD, sing_box_url=base + '/config', ui_url=base + '/' + endpoint)
                elif self.path == '/config': payload = CONFIG
                elif self.path == '/ui': payload = UI_DOCUMENT
                elif self.path == '/invalid': payload = dict(UI_DOCUMENT, schemaVersion=2)
                elif self.path == '/legacy': payload = {'sing_box_url': None, 'vk_turn_link': None}
                elif self.path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location', base + '/leak')
                    self.end_headers()
                    return
                elif self.path == '/unauthorized':
                    self.send_response(401)
                    self.end_headers()
                    return
                elif self.path == '/large':
                    self.send_response(200)
                    self.end_headers()
                    try: self.wfile.write(b' ' * (1024 * 1024 + 1))
                    except (BrokenPipeError, ConnectionResetError): pass
                    return
                else: payload = UI_DOCUMENT
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        base = f'http://localhost:{server.server_port}'
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for endpoint in ['ui', 'invalid', 'redirect', 'unauthorized', 'large']:
                result = subprocess.run([str(self.executable), 'download', base + '/subscription/' + endpoint], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, endpoint == 'ui', endpoint)
            for path, authorization in events:
                self.assertEqual(authorization, None if path.startswith('/subscription/') or path == '/config' else 'Bearer synthetic_ui_token_123')
            self.assertNotIn('/leak', [path for path, _ in events])
            result = subprocess.run([str(self.executable), 'download', base + '/legacy'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


    def test_native_contract_headers_and_scoped_authorization(self):
        events = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                events.append((self.path, self.headers.get('User-Agent'), self.headers.get('X-Subscription-Format'), self.headers.get('Authorization'), self.headers.get('X-Subscription-Capabilities'), self.headers.get('x-hwid')))
                if self.path == '/api/sub/key':
                    payload = dict(PAYLOAD, sing_box_url=base + '/api/sub/key/app/v1/config', ui_url=base + '/api/sub/key/app/v1/ui')
                elif self.path.endswith('/config'): payload = CONFIG
                else: payload = UI_DOCUMENT
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header('X-Subscription-Format', 'vipin-v1')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f'http://127.0.0.1:{server.server_port}'
        try:
            result = subprocess.run([str(self.executable), 'download', base + '/api/sub/key'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout)['complete'])
            self.assertEqual(len(events), 3)
            for path, agent, fmt, auth, capabilities, hwid in events:
                self.assertRegex(hwid or "", r"^[a-zA-Z0-9=-]{10,64}$")
                self.assertEqual(capabilities, "vless-failover-v1 device-access-v1")
                self.assertTrue(agent.startswith('VipinApp/'), events)
                self.assertEqual(fmt, 'vipin-v1')
                self.assertEqual(auth, None if path == '/api/sub/key' else 'Bearer synthetic_ui_token_123')
        finally:
            server.shutdown()
            server.server_close()

    def test_native_contract_never_sends_bearer_to_another_origin(self):
        leaked = []
        class Foreign(BaseHTTPRequestHandler):
            def do_GET(self):
                leaked.append(self.headers.get('Authorization'))
                body = json.dumps(UI_DOCUMENT).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_): pass
        foreign = ThreadingHTTPServer(('127.0.0.1', 0), Foreign)
        threading.Thread(target=foreign.serve_forever, daemon=True).start()
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                payload = dict(PAYLOAD, sing_box_url=None, ui_url=f'http://127.0.0.1:{foreign.server_port}/ui')
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header('X-Subscription-Format', 'vipin-v1')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            result = subprocess.run([str(self.executable), 'download', f'http://127.0.0.1:{server.server_port}/api/sub/key'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(leaked, [])
        finally:
            server.shutdown()
            server.server_close()
            foreign.shutdown()
            foreign.server_close()


if __name__ == '__main__':
    # Keep the original fixture command working with the complete UI contract.
    from prototype_ui_fixture import Handler
    ThreadingHTTPServer(('127.0.0.1', 18081), Handler).serve_forever()
