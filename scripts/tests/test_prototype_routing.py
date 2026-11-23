"""Exercise routing preparation and persistent cache configuration with real Swift."""
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import select
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import Foundation

@main
struct Checks {
    static func main() throws {
        let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let result: Data
        if CommandLine.arguments[1] == "dns" {
            // The standalone Swift harness has no gomobile framework. Supply the
            // classification of the actual fixture bytes at the native boundary.
            let ipAsset = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))
            result = try PrototypeRouting.configurationWithDNSPolicy(source) { path in
                try Data(contentsOf: URL(fileURLWithPath: path)) == ipAsset
            }
        } else if CommandLine.arguments[1].hasPrefix("cache") {
            result = try PrototypeRouting.configurationWithPersistentCache(source, directory: directory, reverseMapping: CommandLine.arguments[1] == "cache-reverse" ? true : nil)
        } else {
            let mode = PrototypeRoutingMode(rawValue: CommandLine.arguments[1])!
            result = try PrototypeRouting.stage(source, directory: directory)[mode]!.route
        }
        print(String(decoding: result, as: UTF8.self))
    }
}
'''


class RoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        source = directory / 'checks.swift'
        implementation = ROOT / 'Library/Network/PrototypeRouting.swift'
        source.write_text((implementation.read_text() if implementation.exists() else '') + HARNESS)
        cls.executable = directory / 'routing-tests'
        result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                 str(directory / 'modules'), str(source), '-o', str(cls.executable)],
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_configuration(self, payload, mode='enabled', success=True):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        source = Path(directory.name) / 'input.json'
        initial = Path(directory.name) / 'initial'
        source.write_text(json.dumps(payload))
        result = subprocess.run([str(self.executable), mode, str(source), str(initial),
                                 str(ROOT / 'PrototypeApp/RuleSets/geoip-direct.srs')],
                                capture_output=True, text=True)
        if not success:
            self.assertNotEqual(result.returncode, 0)
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout), initial

    def packaged(self):
        package = json.loads((ROOT / 'PrototypeApp/routing.json').read_text())
        for asset in package['assets'].values():
            data = (ROOT / 'PrototypeApp/RuleSets' / asset.pop('file')).read_bytes()
            asset['data'] = base64.b64encode(data).decode()
        return package

    def test_both_profiles_keep_order_and_only_use_verified_local_assets(self):
        package = self.packaged()
        self.assertEqual(len(package['assets']), 22)
        for mode, name in [('enabled', 'roskomvpn'), ('disabled', 'russia_inside')]:
            result, _ = self.run_configuration(package, mode)
            profile = package['profiles'][name]
            self.assertEqual(result['rules'], profile['rules'])
            self.assertEqual(result['final'], profile['final'])
            for descriptor in result['rule_set']:
                self.assertEqual(set(descriptor), {'type', 'format', 'path', 'tag'})
                self.assertEqual(descriptor['type'], 'local')
                self.assertTrue(Path(descriptor['path']).is_absolute())

    @unittest.skipUnless((ROOT / 'build/sing-box-check').exists(), 'Build the native sing-box test executable')
    def test_manual_rule_overrides_youtube_udp_block_until_removed(self):
        fixture = ROOT / 'scripts/tests/fixtures/vipin-v2-routing.json'
        package = json.loads(fixture.read_text())['routing']

        def free_port(kind):
            with socket.socket(socket.AF_INET, kind) as reserve:
                reserve.bind(('127.0.0.1', 0))
                return reserve.getsockname()[1]

        with tempfile.TemporaryDirectory() as tmp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            directory = Path(tmp)
            receiver.bind(('127.0.0.1', 0))
            receiver.settimeout(2)
            probe_port = free_port(socket.SOCK_DGRAM)
            relay_port = free_port(socket.SOCK_STREAM)
            for manual in [True, False]:
                with self.subTest(manual=manual):
                    if not manual:
                        package['profiles']['roskomvpn']['rules'].remove(
                            {'domain': ['video.routing.invalid'], 'outbound': 'vk-wg'})
                    wire = directory / 'wire.json'
                    wire.write_text(json.dumps(package))
                    route = json.loads(subprocess.check_output(
                        [str(self.executable), 'enabled', str(wire), str(directory / 'assets')]))
                    # Only the local relay forwards to the test receiver. The probe uses the published rules.
                    route['rules'].insert(0, {'inbound': 'relay', 'outbound': 'direct',
                                              'override_address': '127.0.0.1', 'override_port': receiver.getsockname()[1]})
                    config = {
                        'log': {'level': 'debug'}, 'route': route,
                        'inbounds': [
                            {'type': 'direct', 'tag': 'probe', 'listen': '127.0.0.1', 'listen_port': probe_port,
                             'network': 'udp', 'override_address': 'video.routing.invalid', 'override_port': 443},
                            {'type': 'socks', 'tag': 'relay', 'listen': '127.0.0.1', 'listen_port': relay_port}],
                        'outbounds': [{'type': 'direct', 'tag': 'direct'},
                                      {'type': 'socks', 'tag': 'vk-wg', 'server': '127.0.0.1', 'server_port': relay_port}]}
                    path = directory / 'config.json'
                    path.write_text(json.dumps(config))
                    log = directory / 'engine.log'
                    with log.open('w') as output, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                        process = subprocess.Popen([str(ROOT / 'build/sing-box-check'), 'run', '-c', str(path)],
                                                   stdout=output, stderr=output)
                        try:
                            deadline = time.monotonic() + 5
                            while 'sing-box started' not in log.read_text():
                                if process.poll() is not None or time.monotonic() >= deadline:
                                    self.fail(log.read_text())
                                time.sleep(.03)
                            client.sendto(b'test datagram', ('127.0.0.1', probe_port))
                            if manual:
                                self.assertEqual(receiver.recvfrom(100)[0], b'test datagram')
                            else:
                                with self.assertRaises(socket.timeout):
                                    receiver.recvfrom(100)
                                self.assertIn('reject', log.read_text())
                        finally:
                            process.terminate()
                            process.wait(timeout=10)

    def test_invalid_asset_hash_reference_action_and_path_are_rejected(self):
        for mutation in ['checksum', 'reference', 'action', 'path', 'version', 'reverse']:
            payload = self.packaged()
            rules = payload['profiles']['roskomvpn']['rules']
            if mutation == 'checksum':
                next(iter(payload['assets'].values()))['sha256'] = '0' * 64
            elif mutation == 'reference':
                rules.append({'rule_set': 'missing', 'outbound': 'vk-wg'})
            elif mutation == 'action':
                rules.append({'domain': 'example.org', 'action': 'route-options'})
            elif mutation == 'path':
                payload['assets']['../outside'] = next(iter(payload['assets'].values()))
            elif mutation == 'version':
                payload['schemaVersion'] = True
            else:
                payload['profiles']['russia_inside']['reverse_mapping'] = 1
            with self.subTest(mutation=mutation):
                self.run_configuration(payload, success=False)

    def test_persistent_cache_preserves_dns_transport_and_other_experimental_settings(self):
        config = {'dns': {'final': 'dns'}, 'outbounds': [{'type': 'vless', 'tag': 'vk-wg'}],
                  'experimental': {'clash_api': {'external_controller': '127.0.0.1:9090'},
                                   'cache_file': {'enabled': True, 'path': 'prototype-cache.db'}}}
        result, directory = self.run_configuration(config, 'cache')
        self.assertEqual(result['dns'], config['dns'])
        self.assertEqual(result['outbounds'], config['outbounds'])
        self.assertEqual(result['experimental']['clash_api'], config['experimental']['clash_api'])
        self.assertEqual(result['experimental']['cache_file']['path'], str(directory / 'cache.db'))
        self.assertTrue(result['experimental']['cache_file']['enabled'])

    def test_russia_inside_maps_dns_answers_to_domains_for_opaque_traffic(self):
        for transport in ['vless', 'wireguard']:
            with self.subTest(transport=transport):
                dns = {'servers': [{'type': 'udp', 'tag': 'dns', 'server': '1.1.1.1', 'detour': 'vk-wg'}],
                       'final': 'dns', 'strategy': 'ipv4_only'}
                config = {'dns': dns, 'route': {'final': 'direct',
                                              'rule_set': [{'tag': 'russia-inside'}]},
                          'outbounds': [{'type': transport, 'tag': 'vk-wg'}]}
                result, _ = self.run_configuration(config, 'cache-reverse')
                self.assertTrue(result['dns'].get('reverse_mapping', False))
                self.assertEqual(result['dns']['servers'], dns['servers'])
                self.assertEqual(result['dns']['final'], dns['final'])
                self.assertEqual(result['dns']['strategy'], dns['strategy'])
                self.assertEqual(result['outbounds'], config['outbounds'])

    def test_invalid_route_is_rejected(self):
        for route in [[], None, {'rules': 'invalid'}, {'rule_set': 'invalid', 'rules': []}]:
            with self.subTest(route=route):
                self.run_configuration(route, success=False)

    def dns_configuration(self, mode='enabled', transport='vless'):
        route = self.packaged()
        route, _ = self.run_configuration(route, mode)
        config = {'route': route, 'dns': {'servers': [
            {'tag': 'dns', 'type': 'udp', 'server': '1.1.1.1', 'detour': 'vk-wg'},
            {'tag': 'bootstrap', 'type': 'udp', 'server': '1.1.1.1'}],
            'final': 'dns', 'strategy': 'ipv4_only'},
            'outbounds': [{'type': 'direct', 'tag': 'direct'},
                          {'type': transport, 'tag': 'vk-wg',
                           'domain_resolver': {'server': 'bootstrap', 'strategy': 'ipv4_only'}}]}
        result, _ = self.run_configuration(config, 'dns')
        return config, result

    def test_dns_uses_verified_doh_with_explicit_direct_and_proxy_paths(self):
        for transport in ['vless', 'selector', 'vk-turn-transport']:
            with self.subTest(transport=transport):
                source, result = self.dns_configuration(transport=transport)
                servers = {server['tag']: server for server in result['dns']['servers']}
                for tag, address, detour in [('dns-direct', '77.88.8.8', None),
                                              ('dns', '8.8.8.8', 'vk-wg'),
                                              ('bootstrap', '77.88.8.8', None)]:
                    server = servers[tag]
                    self.assertEqual(server['type'], 'https')
                    self.assertEqual(server['server'], address)
                    self.assertEqual(server['path'], '/dns-query')
                    self.assertEqual(server.get('detour'), detour)
                    self.assertFalse(server.get('tls', {}).get('insecure', False))
                self.assertEqual(result['dns']['strategy'], 'ipv4_only')
                self.assertEqual(result['route'], source['route'])
                self.assertEqual(result['outbounds'], source['outbounds'])

    def test_dns_follows_domain_rule_order_without_blocking_youtube_dns(self):
        source, result = self.dns_configuration()
        rules = result['dns']['rules']
        domain_routes = [rule for rule in source['route']['rules']
                         if 'rule_set' in rule and 'network' not in rule
                         and rule['rule_set'] != 'geoip-direct']
        self.assertEqual(len(domain_routes), 3)
        for route, dns in zip(domain_routes, rules):
            self.assertEqual(dns['rule_set'], route['rule_set'])
            if route.get('action') == 'reject':
                self.assertEqual(dns['action'], 'reject')
            else:
                self.assertEqual(dns['action'], 'route')
                self.assertEqual(dns['server'], 'dns-direct' if route['outbound'] == 'direct' else 'dns')
        self.assertEqual(result['dns']['final'], 'dns')
        self.assertFalse(any('network' in rule or 'port' in rule for rule in rules))

    def test_dns_ip_rules_inspect_google_answer_before_reresolving_direct_destinations(self):
        _, result = self.dns_configuration()
        rules = result['dns']['rules']
        evaluate = next(index for index, rule in enumerate(rules) if rule['action'] == 'evaluate')
        self.assertEqual(rules[evaluate]['server'], 'dns')
        self.assertEqual(rules[evaluate + 1], {'ip_is_private': True, 'match_response': True,
                                              'action': 'route', 'server': 'dns-direct'})
        self.assertEqual(rules[evaluate + 2], {'rule_set': 'geoip-direct', 'match_response': True,
                                              'action': 'route', 'server': 'dns-direct'})
        self.assertEqual(rules[-1], {'action': 'respond'})

    def test_dns_uses_rule_set_contents_after_tags_are_renamed(self):
        directory = ROOT / 'PrototypeApp/RuleSets'
        descriptors = [
            {'type': 'local', 'format': 'binary', 'tag': tag, 'path': str(directory / name)}
            for tag, name in [('office-prefixes', 'geoip-direct.srs'), ('geoip-sites', 'geosite-apple.srs')]]
        config = {'route': {'rule_set': descriptors, 'final': 'vk-wg', 'rules': [
            {'rule_set': 'geoip-sites', 'outbound': 'direct'},
            {'rule_set': 'office-prefixes', 'outbound': 'direct'}]},
            'outbounds': [{'type': 'direct', 'tag': tag} for tag in ('direct', 'vk-wg')]}
        result, _ = self.run_configuration(config, 'dns')
        rules = result['dns']['rules']
        self.assertNotIn('match_response', next(r for r in rules if r.get('rule_set') == 'geoip-sites'))
        self.assertTrue(next(r for r in rules if r.get('rule_set') == 'office-prefixes')['match_response'])
        native = ROOT / 'build/sing-box-check'
        if native.exists():
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / 'config.json'
                path.write_text(json.dumps(result))
                subprocess.run([str(native), 'check', '-c', str(path)], check=True, capture_output=True)

    def test_russia_inside_dns_uses_google_only_for_vpn_domains(self):
        _, result = self.dns_configuration('disabled')
        self.assertEqual(result['dns']['final'], 'dns-direct')
        self.assertEqual(result['dns']['rules'], [
            {'rule_set': 'russia-inside', 'action': 'route', 'server': 'dns'}])
        cached, _ = self.run_configuration(result, 'cache-reverse')
        self.assertTrue(cached['dns']['reverse_mapping'])
        self.assertEqual(cached['dns']['servers'], result['dns']['servers'])

    def test_dns_policy_rejects_missing_or_invalid_routing(self):
        for route in [None, {'rules': 'invalid'}, {'rules': [], 'final': 'unknown'}]:
            with self.subTest(route=route):
                self.run_configuration({'route': route}, 'dns', success=False)

    @unittest.skipUnless((ROOT / 'build/sing-box-check').exists(), 'Build build/sing-box-check for native DNS checks')
    def test_native_core_sends_queries_to_the_matching_doh_server(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            cert, key = directory / 'cert.pem', directory / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(key), '-out', str(cert), '-days', '1',
                            '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1'],
                           check=True, capture_output=True)
            requests, proxy_connections = [], []

            class DoH(BaseHTTPRequestHandler):
                def do_POST(self):
                    query = self.rfile.read(int(self.headers['Content-Length']))
                    offset, labels = 12, []
                    while query[offset]:
                        size = query[offset]
                        labels.append(query[offset + 1:offset + 1 + size].decode())
                        offset += size + 1
                    name = '.'.join(labels)
                    requests.append((self.server.label, name))
                    # An otherwise unknown domain resolves into the direct-IP rule.
                    address = ('127.0.0.1' if name == 'proxy.example' else
                               '192.168.1.2' if name == 'ip-direct.example' else '198.51.100.2' if name == 'reject-ip.example' else '203.0.113.10')
                    answer = (query[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0)
                              + query[12:offset + 5] + b'\xc0\x0c'
                              + struct.pack('!HHIH', 1, 1, 60, 4) + socket.inet_aton(address))
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/dns-message')
                    self.send_header('Content-Length', str(len(answer)))
                    self.end_headers()
                    self.wfile.write(answer)

                def log_message(self, *_):
                    pass

            servers = {}
            for label in ['direct', 'proxy']:
                server = ThreadingHTTPServer(('127.0.0.1', 0), DoH)
                server.label = label
                tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                tls.load_cert_chain(cert, key)
                server.socket = tls.wrap_socket(server.socket, server_side=True)
                servers[label] = server

            class Proxy(BaseHTTPRequestHandler):
                def do_CONNECT(self):
                    expected = f'127.0.0.1:{servers["proxy"].server_port}'
                    if self.path != expected:
                        self.send_error(403)
                        return
                    proxy_connections.append(self.path)
                    with socket.create_connection(('127.0.0.1', servers['proxy'].server_port), timeout=5) as remote:
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.flush()
                        while True:
                            ready, _, _ = select.select([self.connection, remote], [], [], 5)
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
            for server in [*servers.values(), proxy]:
                server.daemon_threads = True
                threading.Thread(target=server.serve_forever, daemon=True).start()
                self.addCleanup(server.server_close)
                self.addCleanup(server.shutdown)

            for mode in ['enabled', 'disabled']:
                with self.subTest(mode=mode):
                    source, config = self.dns_configuration(mode)
                    if mode == 'disabled':
                        source['route']['rules'][2:2] = [
                            {'ip_cidr': '198.51.100.2/32', 'action': 'reject'},
                            {'domain': 'forced-direct.example', 'outbound': 'direct'},
                            {'domain_suffix': 'forced-direct.example', 'outbound': 'vk-wg'}]
                        config, _ = self.run_configuration(source, 'dns')
                    for server in config['dns']['servers']:
                        destination = servers['proxy' if server['tag'] == 'dns' else 'direct']
                        server.update(server='127.0.0.1', server_port=destination.server_port,
                                      tls={'certificate': cert.read_text()})
                    for descriptor in config['route']['rule_set']:
                        tag = descriptor['tag']
                        descriptor.clear()
                        rule = {'ip_cidr': ['192.168.0.0/16']} if tag == 'geoip-direct' else {
                            'domain': ['vpn.example', 'overlap.example', 'reject-ip.example'] if tag in ['geosite-youtube', 'russia-inside']
                            else ['direct.example', 'overlap.example'] if tag == 'geosite-category-ru'
                            else ['blocked.example'] if tag == 'geosite-category-ads' else [tag + '.example']}
                        descriptor.update(type='inline', tag=tag, rules=[rule])
                    config['outbounds'] = [
                        {'type': 'direct', 'tag': 'direct'},
                        {'type': 'http', 'tag': 'proxy-node', 'server': 'proxy.example', 'server_port': proxy.server_port,
                         'domain_resolver': {'server': 'bootstrap'}},
                        {'type': 'selector', 'tag': 'vk-wg', 'outbounds': ['proxy-node']}]
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reserve:
                        reserve.bind(('127.0.0.1', 0))
                        dns_port = reserve.getsockname()[1]
                    config['inbounds'] = [{'type': 'direct', 'listen': '127.0.0.1', 'listen_port': dns_port,
                                           'network': 'udp'}]
                    config['log'] = {'level': 'debug'}
                    config_path = directory / 'config.json'
                    config_path.write_text(json.dumps(config))
                    with (directory / f'{mode}.log').open('w+') as log:
                        process = subprocess.Popen([str(ROOT / 'build/sing-box-check'), 'run', '-c', str(config_path)],
                                                   cwd=directory, stdout=log, stderr=log)
                        try:
                            deadline = time.monotonic() + 10
                            while time.monotonic() < deadline:
                                log.seek(0)
                                output = log.read()
                                if 'sing-box started' in output or process.poll() is not None:
                                    break
                                time.sleep(0.02)
                            self.assertIn('sing-box started', output, output)
                            cases = [('direct.example', ['direct']), ('vpn.example', ['proxy']),
                                     ('overlap.example', ['proxy']),
                                     ('unknown.example', ['proxy'] if mode == 'enabled' else ['direct']),
                                     ('ip-direct.example', ['proxy', 'direct'] if mode == 'enabled' else ['direct']),
                                     ('blocked.example', [] if mode == 'enabled' else ['direct'])]
                            if mode == 'disabled':
                                cases.extend([('reject-ip.example', ['proxy']), ('forced-direct.example', ['direct']),
                                              ('sub.forced-direct.example', ['proxy'])])
                            for name, expected in cases:
                                before = len(requests)
                                query = (struct.pack('!HHHHHH', 123, 0x0100, 1, 0, 0, 0)
                                         + b''.join(bytes([len(label)]) + label.encode() for label in name.split('.'))
                                         + b'\0' + struct.pack('!HH', 1, 1))
                                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                                    client.settimeout(5)
                                    client.sendto(query, ('127.0.0.1', dns_port))
                                    answer = client.recv(65536)
                                self.assertEqual(struct.unpack('!H', answer[2:4])[0] & 0xF,
                                                 5 if (name == 'blocked.example' and mode == 'enabled') or name == 'reject-ip.example' else 0)
                                self.assertEqual([label for label, domain in requests[before:] if domain == name],
                                                 expected, name)
                            self.assertTrue(proxy_connections)
                            self.assertIn(('direct', 'proxy.example'), requests)
                            self.assertNotIn(('proxy', 'proxy.example'), requests)
                        finally:
                            process.terminate()
                            process.wait(timeout=10)
