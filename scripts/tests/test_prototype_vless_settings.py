"""Exercise VLESS start from system Settings using the packet tunnel startup code."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_device_access import production_sources


ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import Network

func settingsStart(directory: URL, settings: [String: Any]) async throws -> [String: Any] {
    let serviceHost: String? = nil
    let vless = true
    // ROUTING
    var input: [String: Any] = ["route": route]
    // VLESS
    return input
}

@main struct Checks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let cache = directory.appendingPathComponent("prototype-subscription.json")
        let source = "https://subscription.invalid/test"
        let bundle = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        let package = try JSONSerialization.data(withJSONObject: bundle["routing"]!)
        let routing = try PrototypeRouting.install(package, snapshotURL: cache, source: source)
        let selection = try PrototypeRouting.selection(mode: .enabled, routing: routing, source: source, snapshotURL: cache, bundle: .main)
        let savedRoute = directory.appendingPathComponent("prototype-routing.json")
        try selection.write(to: savedRoute)
        let oldRuntime = directory.appendingPathComponent("prototype-vless.json")
        let access = SubscriptionDeviceAccessStore(cacheURL: cache)
        let settings: [String: Any] = ["routingSource": PrototypeRouting.sourceID(source)]
        func node(_ host: String) -> [String: Any] {
            ["type": "vless", "server": host, "server_port": 443, "uuid": "00000000-0000-4000-8000-000000000001"]
        }
        try JSONSerialization.data(withJSONObject: node("old.invalid")).write(to: oldRuntime)
        let latest = try JSONSerialization.data(withJSONObject: node("new.invalid"))
        let item: [String: Any] = ["id": "option01", "state": "available"]
        let block: [String: Any] = ["id": "block04", "type": "selectionList", "items": [item]]
        func publish(blocks: [[String: Any]], node: Data? = nil, provisioning: [String: Any]? = nil, bundledRouting: Bool = false) async throws {
            var root: [String: Any] = ["sourceURL": source, "updatedAt": 1000,
                                       "uiDocument": ["schemaVersion": 1, "blocks": blocks]]
            if !bundledRouting { root["routing"] = routing.base64EncodedString() }
            root["vlessOutbound"] = node?.base64EncodedString()
            root["vlessProvisioning"] = provisioning
            _ = try await access.commitSnapshot(JSONSerialization.data(withJSONObject: root))
        }
        try await publish(blocks: [block], node: latest)
        let result = try await settingsStart(directory: directory, settings: settings)
        guard (result["vless"] as? [String: Any])?["server"] as? String == "new.invalid" else {
            print("FAIL: system VPN start loaded obsolete VLESS settings after refresh")
            exit(1)
        }

        // A saved selection and single-node snapshot from an older app still start.
        try Data(#"{"rules":[],"rule_set":[]}"#.utf8).write(to: savedRoute)
        let migrated = try await settingsStart(directory: directory, settings: [:])
        precondition((migrated["vless"] as? [String: Any])?["server"] as? String == "new.invalid")

        try await publish(blocks: [block], node: latest, bundledRouting: true)
        let offline = try await settingsStart(directory: directory, settings: settings)
        precondition((offline["vless"] as? [String: Any])?["server"] as? String == "new.invalid")
        let offlineRoute = offline["route"] as? [String: Any]
        let offlineRules = offlineRoute?["rule_set"] as? [[String: Any]]
        precondition(offlineRules?.isEmpty == false)

        let tls: [String: Any] = ["enabled": true, "server_name": "tls.invalid",
                                  "utls": ["enabled": true, "fingerprint": "chrome"],
                                  "reality": ["enabled": true, "public_key": String(repeating: "A", count: 43), "short_id": "abcd"]]
        let nodes = (1...4).map { node("group\($0).invalid").merging(["tag": "n\($0)", "tls": tls]) { _, new in new } }
        let policy: [String: Any] = ["selector": "vk-wg", "primary": "n1", "backups": ["n2", "n3", "n4"],
                                     "intervalMilliseconds": 10000, "timeoutMilliseconds": 5000, "failureThreshold": 2, "recoveryThreshold": 3]
        let provision: [String: Any] = ["schemaVersion": 1, "kind": "vless-failover", "state": "available", "outbounds": nodes, "failover": policy]
        try await publish(blocks: [block], provisioning: provision)
        let failover = try await settingsStart(directory: directory, settings: settings)
        precondition(failover["vless_primary"] as? String == "n1")
        let activeNodes = failover["vless_outbounds"] as? [[String: Any]]
        precondition(activeNodes?.first?["server"] as? String == "group1.invalid")

        func expectDisabled(_ scenario: String) async throws {
            if (try? await settingsStart(directory: directory, settings: settings)) != nil {
                print("FAIL: system VPN start accepted \(scenario)")
                exit(1)
            }
        }
        try await publish(blocks: [block])
        try await expectDisabled("missing transport")
        try await publish(blocks: [block], provisioning: ["schemaVersion": 1, "kind": "vless-failover", "state": "restricted",
                                                    "reason": "not_allowed", "outbounds": []])
        try await expectDisabled("restricted transport")
        try await publish(blocks: [block], node: latest, provisioning: provision)
        try await expectDisabled("conflicting transport configurations")
        try await publish(blocks: [block.merging(["visible": false]) { _, rhs in rhs }], node: latest)
        try await expectDisabled("hidden mode list")
        try await publish(blocks: [block.merging(["items": [item.merging(["visible": false]) { _, rhs in rhs }]]) { _, rhs in rhs }], node: latest)
        try await expectDisabled("hidden mode")
        try await publish(blocks: [block.merging(["items": [["id": "option01", "state": "unavailable"]]]) { _, rhs in rhs }], node: latest)
        try await expectDisabled("unavailable mode")
        try await publish(blocks: [], node: latest)
        try await expectDisabled("missing mode")
    }
}
'''


class VLESSSettingsTests(unittest.TestCase):
    def test_settings_start_uses_latest_available_transport(self):
        provider = (ROOT / 'Extension/PacketTunnelProvider.swift').read_text()
        routing = provider.split('        capture.start()\n        do {\n', 1)[1].split('            let cache =', 1)[0]
        vless = provider[provider.index('            var priorityFailoverJSON:'):provider.index('            } else if !baseline {')] + '    }'
        harness = HARNESS.replace('    // ROUTING', routing).replace('    // VLESS', vless)
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            shutil.copyfile(ROOT / 'PrototypeApp/routing.json', folder / 'routing.json')
            shutil.copytree(ROOT / 'PrototypeApp/RuleSets', folder / 'RuleSets')
            source = folder / 'checks.swift'
            source.write_text(production_sources() + '\n' + harness)
            executable = folder / 'checks'
            build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                                    str(source), '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            network = ROOT / 'scripts/tests/fixtures/vipin-v2-routing.json'
            run = subprocess.run([str(executable), str(folder), str(network)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
