"""Exercise routing preparation and persistent cache configuration with real Swift."""
import json
from pathlib import Path
import subprocess
import tempfile
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
        if CommandLine.arguments[1] == "cache" {
            result = try PrototypeRouting.configurationWithPersistentCache(source, directory: directory)
        } else {
            let mode = PrototypeRoutingMode(rawValue: CommandLine.arguments[1])!
            result = try PrototypeRouting.route(from: source, mode: mode, initialDirectory: directory)
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
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'input.json'
            initial = Path(directory) / 'initial'
            source.write_text(json.dumps(payload))
            result = subprocess.run([str(self.executable), mode, str(source), str(initial)],
                                    capture_output=True, text=True)
            if not success:
                self.assertNotEqual(result.returncode, 0)
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout), initial

    def test_russia_inside_only_routes_listed_domains_through_vpn(self):
        route = json.loads((ROOT / 'PrototypeApp/routing.json').read_text())
        result, initial = self.run_configuration(route, 'disabled')
        self.assertEqual(result['final'], 'direct')
        self.assertEqual(result['rules'], [{'action': 'sniff'}, {'protocol': 'dns', 'action': 'hijack-dns'},
                                           {'rule_set': 'russia-inside', 'outbound': 'vk-wg'}])
        self.assertEqual(len(result['rule_set']), 1)
        self.assertEqual(result['rule_set'][0]['tag'], 'russia-inside')
        self.assertEqual(result['rule_set'][0]['initial_path'], str(initial / 'russia-inside.srs'))
        self.assertEqual(result['rule_set'][0]['http_client'], {'detour': 'vk-wg'})
        self.assertEqual(result['rule_set'][0]['update_interval'], '1d')

    def test_enabled_routing_preserves_rule_order_and_uses_absolute_fallback_paths(self):
        route = {'rules': [{'domain': ['example.org'], 'outbound': 'direct'},
                           {'port': 443, 'action': 'reject'}], 'final': 'vk-wg',
                 'rule_set': [{'type': 'remote', 'tag': 'geosite-test', 'format': 'binary',
                               'url': 'https://example.org/test.srs', 'initial_path': 'old.srs',
                               'update_interval': '1d', 'http_client': {'detour': 'vk-wg'}}]}
        result, initial = self.run_configuration(route)
        self.assertEqual(result['rules'], route['rules'])
        self.assertEqual(result['final'], 'vk-wg')
        descriptor = result['rule_set'][0]
        self.assertEqual(descriptor['initial_path'], str(initial / 'geosite-test.srs'))
        self.assertEqual(descriptor['url'], 'https://example.org/test.srs')
        self.assertEqual(descriptor['http_client'], {'detour': 'vk-wg'})

    def test_shipped_route_can_update_every_bundled_rule_set_without_losing_rules(self):
        route = json.loads((ROOT / 'PrototypeApp/routing.json').read_text())
        result, directory = self.run_configuration(route)
        self.assertEqual(result['rules'], route['rules'])
        self.assertEqual({entry['tag'] for entry in result['rule_set']},
                         {path.stem for path in (ROOT / 'PrototypeApp/RuleSets').glob('*.srs')} - {'russia-inside'})
        for entry in result['rule_set']:
            with self.subTest(tag=entry['tag']):
                self.assertEqual(entry['type'], 'remote')
                self.assertTrue(entry['url'].startswith('https://'))
                self.assertEqual(entry['http_client']['detour'], 'vk-wg')
                self.assertEqual(entry['initial_path'], str(directory / (entry['tag'] + '.srs')))
                self.assertNotIn('path', entry)

    def test_rule_set_tag_cannot_escape_initial_directory(self):
        for tag in ['../outside', '/absolute', '', 'folder/name']:
            with self.subTest(tag=tag):
                self.run_configuration({'rule_set': [{'type': 'remote', 'tag': tag}], 'rules': []}, success=False)

    def test_remote_updates_are_explicitly_sent_through_selected_vpn(self):
        route = {'rules': [], 'rule_set': [{'type': 'remote', 'tag': 'geoip-test',
                                           'url': 'https://example.org/geoip.srs',
                                           'download_detour': 'direct'}]}
        result, _ = self.run_configuration(route)
        descriptor = result['rule_set'][0]
        self.assertEqual(descriptor['http_client'], {'detour': 'vk-wg'})
        self.assertEqual(descriptor['update_interval'], '1d')
        self.assertNotIn('download_detour', descriptor)

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
                result, _ = self.run_configuration(config, 'cache')
                self.assertTrue(result['dns'].get('reverse_mapping', False))
                self.assertEqual(result['dns']['servers'], dns['servers'])
                self.assertEqual(result['dns']['final'], dns['final'])
                self.assertEqual(result['dns']['strategy'], dns['strategy'])
                self.assertEqual(result['outbounds'], config['outbounds'])

    def test_invalid_route_is_rejected(self):
        for route in [[], None, {'rules': 'invalid'}, {'rule_set': 'invalid', 'rules': []}]:
            with self.subTest(route=route):
                self.run_configuration(route, success=False)
