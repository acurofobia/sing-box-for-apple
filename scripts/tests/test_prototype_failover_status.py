"""Exercise the real failover status decoding and user-visible server states."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FailoverStatusTests(unittest.TestCase):
    def test_attempts_selection_background_checks_and_unavailable_servers(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            harness = folder / 'main.swift'
            harness.write_text(r'''import Foundation
func status(_ fields: [String: Any]) throws -> PriorityFailoverStatus {
    let base: [String: Any] = ["mode": "automatic", "allDown": false, "total": 4]
    return try JSONDecoder().decode(PriorityFailoverStatus.self, from:
        JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new }))
}
let trying = try status(["checking": "node-b", "checkingIndex": 2, "selected": "node-a", "selectedIndex": 1, "selectedHealth": "down"])
precondition(trying.serverDescription(connected: false) == "Подключение: node-b (2 из 4)")
let connected = try status(["selected": "node-b", "selectedIndex": 2, "selectedHealth": "up", "checking": "node-a", "checkingIndex": 1])
precondition(connected.serverDescription(connected: true) == "Подключён: node-b (2 из 4)", "background primary probe replaced active backup")
let changing = try status(["selected": "node-b", "selectedIndex": 2, "selectedHealth": "down", "checking": "node-c", "checkingIndex": 3])
precondition(changing.serverDescription(connected: true) == "Подключение: node-c (3 из 4)")
let down = try status(["allDown": true, "selected": "node-b", "selectedIndex": 2, "selectedHealth": "down"])
precondition(down.serverDescription(connected: true) == "Все серверы недоступны")
let legacy = try JSONDecoder().decode(PriorityFailoverStatus.self, from: Data(#"{"mode":"automatic","selected":"node-b","primaryHealth":"up","allDown":false}"#.utf8))
precondition(legacy.serverDescription(connected: true) == "Проверка соединения…", "legacy snapshot claimed a healthy selected server")
let pending = try status(["selected": "node-b", "selectedIndex": 2])
precondition(pending.serverDescription(connected: true) == "Проверка: node-b (2 из 4)")
let invalid = try status(["checking": "unknown", "checkingIndex": 5])
precondition(invalid.serverDescription(connected: false) == "Проверка соединения…")
let rows = try status(["selected": "b", "selectedHealth": "up", "checking": "d", "servers": [
    ["tag": "a", "health": "down"], ["tag": "b", "health": "up"],
    ["tag": "c", "health": "unknown"], ["tag": "d", "health": "down"]]])
precondition(rows.state(for: "a", connected: true) == .unavailable)
precondition(rows.state(for: "b", connected: true) == .connected)
precondition(rows.state(for: "c", connected: true) == .reserve)
precondition(rows.state(for: "d", connected: true) == .checking)
precondition(rows.state(for: "b", connected: false) != .connected)
precondition(legacy.state(for: "node-b", connected: true) == .checking)
print("PASS")
''')
            executable = folder / 'checks'
            compiled = subprocess.run([
                'xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'),
                str(ROOT / 'Library/Network/PriorityFailoverStatus.swift'), str(harness),
                '-o', str(executable)
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
