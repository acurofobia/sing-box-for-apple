"""Run the production Swift importer and HTTP client with synthetic credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
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
PAYLOAD = {'sing_box_url': 'http://localhost/config', 'vk_turn_link': LINK}
HARNESS = r'''
@main
struct Checks {
    static func main() async throws {
        let result: PrototypeSubscription
        if CommandLine.arguments[1] == "download" {
            result = try await PrototypeSubscription.download(CommandLine.arguments[2])
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
        let output: [String: Any] = ["node": node, "vk": cached.vkTurnLink ?? "", "warnings": cached.warnings.count, "configURL": (try JSONSerialization.jsonObject(with: JSONEncoder().encode(cached)) as? [String: Any])?["singBoxURL"] as? String ?? ""]
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
        source.write_text(vk + importer + HARNESS)
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
                if self.path in ['/config', '/config-invalid', '/config-direct']:
                    payload = CONFIG
                    if self.path == '/config-invalid':
                        payload = {'outbounds': [dict(NODE, server_port=0)]}
                    elif self.path == '/config-direct':
                        payload = {'outbounds': [{'type': 'direct'}]}
                else:
                    suffix = self.path.rsplit('/', 1)[-1]
                    config_path = '/config' if suffix == 'test-token' else '/' + suffix
                    payload = dict(PAYLOAD, sing_box_url=f'http://localhost:{self.server.server_port}' + config_path)
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


if __name__ == '__main__':
    # Optional localhost fixture for native iOS UI tests. Contains synthetic data only.
    class UIFixture(BaseHTTPRequestHandler):
        def do_GET(self):
            name = self.path.rsplit('/', 1)[-1]
            payload = dict(PAYLOAD, sing_box_url='http://localhost:18081/config')
            status = 200
            if name == 'config':
                payload = CONFIG
            elif name == 'config-error':
                payload['sing_box_url'] = 'http://localhost:18081/unavailable'
            elif name == 'empty':
                payload.update(sing_box_url=None, vk_turn_link=None)
            elif name == 'vk':
                payload['sing_box_url'] = None
            elif name == 'vless':
                payload['vk_turn_link'] = None
            elif name != 'both':
                payload = {'error': 'Not found'}
                status = 404
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    ThreadingHTTPServer(('127.0.0.1', 18081), UIFixture).serve_forever()
