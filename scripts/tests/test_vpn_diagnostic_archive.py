"""Exercise durable incident snapshots and application errors using real Swift file I/O."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VPNDiagnosticArchiveTests(unittest.TestCase):
    def test_incidents_survive_rotation_and_errors_survive_until_explicit_clear(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            harness = folder / 'main.swift'
            harness.write_text(r'''import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let archive = VPNDiagnosticArchive(directory: root)
func session(_ name: String) throws -> URL {
    let url = root.appendingPathComponent("sessions/" + name, isDirectory: true)
    try fm.createDirectory(at: url.appendingPathComponent("core"), withIntermediateDirectories: true)
    try Data("core-\(name)\n".utf8).write(to: url.appendingPathComponent("core/0001.log"))
    try archive.track(url)
    return url
}
let failed = try session("001-failed")
try archive.recordStop(failed, reason: 2)
let pinned = root.appendingPathComponent("incidents/001-failed/core/0001.log")
precondition(fm.fileExists(atPath: pinned.path), "Provider failure did not preserve core logs")
try Data("changed".utf8).write(to: failed.appendingPathComponent("core/0001.log"))
try archive.preserveIfUnexpected(failed, detail: "duplicate detection")
let original = try String(contentsOf: pinned, encoding: .utf8)
precondition(original == "core-001-failed\n", "Pinned incident was overwritten")
try archive.appendIncidentEvent(failed, message: "startup failed after stop callback")
let late = try String(contentsOf: root.appendingPathComponent("incidents/001-failed/subsequent-events/00000000000000.log"), encoding: .utf8)
precondition(late.contains("startup failed after stop callback"), "Late shutdown error missing from preserved report")
try fm.removeItem(at: failed)
for index in 2...8 {
    let normal = try session(String(format: "%03d-normal", index))
    try archive.recordStop(normal, reason: 1)
    try fm.removeItem(at: normal)
}
precondition(fm.fileExists(atPath: pinned.path), "New connections removed the incident")
let orphan = try session("009-orphan")
let active = try session("010-active")
try archive.recover(excluding: active)
precondition(fm.fileExists(atPath: root.appendingPathComponent("incidents/009-orphan/core/0001.log").path), "Abrupt process termination was lost")
precondition(!fm.fileExists(atPath: root.appendingPathComponent("incidents/010-active").path), "Live session was classified as a crash")
let requested = try session("011-requested")
try archive.expectStop(requested)
try archive.recordStop(requested, reason: 1)
precondition(!fm.fileExists(atPath: root.appendingPathComponent("incidents/011-requested").path), "Intentional app stop was reported as unexpected")
let stalled = try session("012-stalled-stop")
try archive.expectStop(stalled)
try archive.preserveIfUnexpected(stalled, detail: "stop request failed; process subsequently vanished")
precondition(fm.fileExists(atPath: root.appendingPathComponent("incidents/012-stalled-stop").path), "Unconfirmed stop intent swallowed later unexpected termination")
try archive.appendError("first-error https://user:password@example.com/private?token=secret")
for index in 0..<100 { try archive.appendError("error-\(index) " + String(repeating: "x", count: 6000)) }
let errors = try fm.contentsOfDirectory(at: root.appendingPathComponent("application-errors"), includingPropertiesForKeys: nil)
let text = try errors.sorted { $0.path < $1.path }.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
precondition(errors.count > 1 && text.contains("first-error") && text.contains("error-99"), "Error log rotation deleted earlier errors")
precondition(!text.contains("password") && !text.contains("token=secret"), "Error journal exposed credentials")
try archive.clearPreservedReports()
try archive.recover(excluding: active)
precondition(!fm.fileExists(atPath: root.appendingPathComponent("incidents/009-orphan").path), "Cleared report was re-created")
let remainingErrors = try fm.contentsOfDirectory(at: root.appendingPathComponent("application-errors"), includingPropertiesForKeys: nil)
precondition(remainingErrors.isEmpty, "Explicit clear did not clear error files")
try archive.appendError("after-clear")
let fresh = try fm.contentsOfDirectory(at: root.appendingPathComponent("application-errors"), includingPropertiesForKeys: nil)
precondition(fresh.count == 1, "Error writer failed after clearing")
print("PASS")
''')
            executable = folder / 'check'
            compiled = subprocess.run([
                'xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'),
                str(ROOT / 'Library/Shared/RollingDiagnosticLog.swift'),
                str(ROOT / 'Library/Shared/VPNDiagnosticArchive.swift'), str(harness), '-o', str(executable)
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            checked = subprocess.run([str(executable), str(folder / 'data')], capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
