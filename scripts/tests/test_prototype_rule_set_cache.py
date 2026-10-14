"""Characterize the native cache/fallback lifecycle used by the application.

Build build/sing-box-check from the pinned core to enable this integration test.
The test uses a loopback proxy and never creates a TUN or changes system routes.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'build/sing-box-check'


@unittest.skipUnless(CORE.exists(), 'Build build/sing-box-check to test the native cache lifecycle')
class RuleSetCacheTests(unittest.TestCase):
    def test_native_cache_keeps_last_valid_update_after_corrupt_download_and_restart(self):
        payload = (ROOT / 'PrototypeApp/RuleSets/geosite-github.srs').read_bytes()

        class Source(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_):
                pass

        source = ThreadingHTTPServer(('127.0.0.1', 0), Source)

        class Proxy(BaseHTTPRequestHandler):
            def do_CONNECT(self):
                # Refuse destinations outside this test's loopback source server.
                if self.path != f'127.0.0.1:{source.server_port}':
                    self.send_error(403)
                    return
                with socket.create_connection(('127.0.0.1', source.server_port), timeout=5) as remote:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.flush()
                    peers = [self.connection, remote]
                    while True:
                        ready, _, _ = select.select(peers, [], [], 5)
                        if not ready:
                            return
                        for peer in ready:
                            chunk = peer.recv(65536)
                            if not chunk:
                                return
                            (remote if peer is self.connection else self.connection).sendall(chunk)

            def log_message(self, *_):
                pass

        proxy = ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
        for server in (source, proxy):
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            initial = directory / 'initial.srs'
            initial.write_bytes((ROOT / 'PrototypeApp/RuleSets/geosite-youtube.srs').read_bytes())
            config = {
                'log': {'level': 'info'},
                'outbounds': [{'type': 'http', 'tag': 'vk-wg', 'server': '127.0.0.1',
                               'server_port': proxy.server_port}],
                'route': {'final': 'vk-wg', 'rule_set': [{
                    'type': 'remote', 'tag': 'geosite-youtube', 'format': 'binary',
                    'url': f'http://127.0.0.1:{source.server_port}/rules.srs',
                    'initial_path': str(initial), 'update_interval': '100ms',
                    'http_client': {'detour': 'vk-wg', 'version': 1}}],
                    'rules': [{'rule_set': 'geosite-youtube', 'outbound': 'vk-wg'}]},
                'experimental': {'cache_file': {'enabled': True, 'path': str(directory / 'cache.db')}}
            }
            path = directory / 'config.json'

            def run_until(marker, name):
                path.write_text(json.dumps(config))
                log = directory / (name + '.log')
                with log.open('w') as output:
                    process = subprocess.Popen([str(CORE), 'run', '-c', str(path)],
                                               stdout=output, stderr=subprocess.STDOUT)
                    try:
                        deadline = time.monotonic() + 10
                        while marker not in log.read_text():
                            if process.poll() is not None or time.monotonic() >= deadline:
                                self.fail(log.read_text())
                            time.sleep(0.05)
                    finally:
                        if process.poll() is None:
                            process.send_signal(signal.SIGINT)
                        process.wait(timeout=10)
                self.assertEqual(process.returncode, 0, log.read_text())
                return log.read_text()

            first = run_until('updated rule-set geosite-youtube', 'download')
            self.assertIn('sing-box started', first)
            self.assertIn('outbound/http[vk-wg]', first)
            self.assertTrue((directory / 'cache.db').exists())

            payload = b'invalid rule set'
            invalid = run_until('invalid sing-box rule-set file', 'invalid-update')
            self.assertIn('sing-box started', invalid)

            # The only usable data on this restart must come from the native cache.
            initial.unlink()
            config['route']['rule_set'][0]['update_interval'] = '1d'
            restored = run_until('sing-box started', 'cached-restart')
            self.assertNotIn('restore cached rule-set', restored)
            self.assertNotIn('load initial rule-set', restored)
            self.assertNotIn('fetch rule-set', restored)
