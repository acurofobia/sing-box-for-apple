"""Exercise the production manual restart method with controlled VPN states."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r"""
import Foundation

private enum ConnectionStatus { case connected, disconnected, invalid, connecting, disconnecting, reasserting }
private var events: [String] = []
private final class TestConnection {
    var status: ConnectionStatus = .connected
    func stopVPNTunnel() {
        events.append("stop")
        status = .disconnecting
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            status = .disconnected
            events.append("disconnected")
        }
    }
}
private final class TestManager { let connection = TestConnection() }
private enum VKTurnError: Error { case missingConfiguration }
private enum UserDefaults {
    static let standard = TestDefaults()
    final class TestDefaults {
        func set(_ value: String, forKey key: String) { events.append("saved:" + value) }
    }
}
func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}
"""
CHECKS = r"""
private let model = TestModel()
switch CommandLine.arguments[1] {
case "connected":
    await model.switchConnection(to: .vless)
    expect(model.connectionMode == .vless, "mode did not change")
    expect(events == ["stop", "disconnected", "saved:vless", "start:vless"], "restart began before disconnection")
case "offline":
    model.setStatus(.disconnected)
    await model.switchConnection(to: .vless)
    expect(events == ["saved:vless"], "offline selection started VPN")
case "busy":
    model.setStatus(.connecting)
    await model.switchConnection(to: .vless)
    expect(events.isEmpty, "switch during connecting altered VPN")
    expect(model.connectionMode == .vkTurn, "mode changed during connecting")
case "missing_link":
    model.setMode(.vless)
    model.setHasLink(false)
    await model.switchConnection(to: .vkTurn)
    expect(events.isEmpty, "missing TURN link stopped working VLESS")
    expect(model.connectionMode == .vless, "missing TURN link changed mode")
case "offline_missing_link":
    model.setStatus(.disconnected)
    model.setMode(.vless)
    model.setHasLink(false)
    await model.switchConnection(to: .vkTurn)
    expect(events.isEmpty, "unavailable offline mode was selected")
    expect(model.connectionMode == .vless, "unavailable offline mode changed selection")
case "not_loaded":
    model.managersLoaded = false
    await model.switchConnection(to: .vless)
    expect(events.isEmpty, "uninitialized model changed the existing VPN")
    expect(model.connectionMode == .vkTurn, "uninitialized model changed selection")
case "same":
    await model.switchConnection(to: .vkTurn)
    expect(events.isEmpty, "selecting active mode restarted VPN")
default: fatalError("Unknown scenario")
}
expect(model.busy == false, "busy state leaked")
print("PASS")
"""


class SwitchingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        mode = 'enum PrototypeConnectionMode' + app.split('enum PrototypeConnectionMode', 1)[1].split('@main', 1)[0]
        switch = '    func switchConnection(to mode: PrototypeConnectionMode) async {' + app.split(
            '    func switchConnection(to mode: PrototypeConnectionMode) async {', 1)[1].split('    func start()', 1)[0]
        model = r"""
@MainActor
private final class TestModel {
    var manager: TestManager? = TestManager()
    var connectionMode: PrototypeConnectionMode = .vkTurn
    var busy = false
    var managersLoaded = true
    var baseline = false
    var hasLink = true
    var hasVLESS = true
    var error: String?
    func setStatus(_ status: ConnectionStatus) { manager?.connection.status = status }
    func setMode(_ mode: PrototypeConnectionMode) { connectionMode = mode }
    func setHasLink(_ value: Bool) { hasLink = value }
    func start() async {
        expect(manager?.connection.status == .disconnected, "old tunnel still active")
        events.append("start:" + connectionMode.rawValue)
    }
""" + switch + '}\n'
        source = directory / 'main.swift'
        source.write_text(HARNESS + mode + model + CHECKS)
        cls.executable = directory / 'switch-tests'
        result = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(directory / 'modules'),
                        str(source), '-o', str(cls.executable)], capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)

    def test_connected_switch_waits_for_old_tunnel(self):
        self.run_scenario('connected')

    def test_offline_selection_does_not_start_vpn(self):
        self.run_scenario('offline')

    def test_connecting_tunnel_cannot_be_switched(self):
        self.run_scenario('busy')

    def test_missing_turn_link_preserves_running_vless(self):
        self.run_scenario('missing_link')

    def test_offline_turn_selection_requires_imported_link(self):
        self.run_scenario('offline_missing_link')

    def test_initialization_blocks_switching_until_vpn_state_is_known(self):
        self.run_scenario('not_loaded')

    def test_selecting_same_mode_does_not_restart(self):
        self.run_scenario('same')

    def run_scenario(self, scenario):
        result = subprocess.run([str(self.executable), scenario], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
