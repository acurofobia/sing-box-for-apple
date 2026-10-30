"""Run the production rolling log against real files, including restart and limits."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VPNDiagnosticLogTests(unittest.TestCase):
    def test_export_preserves_three_latest_sessions_and_excludes_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            harness = folder / 'main.swift'
            harness.write_text(r'''import Foundation
import os
extension Logger { init(category: String) { self.init(subsystem: "diagnostic-test", category: category) } }
enum FilePath {
    static let sharedDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
    static let workingDirectory = sharedDirectory.appendingPathComponent("Library/Caches/Working")
}
enum CrashReportArchive { static let crashReportsDirectory = FilePath.workingDirectory.appendingPathComponent("crash_reports") }
enum OOMReportArchive { static let reportsDirectory = FilePath.workingDirectory.appendingPathComponent("oom_reports") }
enum ReportArchive {
    static let metadataFileName = "metadata.json"
    static let goLogFileName = "go.log"
    static let nativeLogFileName = "native.log"
}
let fm = FileManager.default
VPNDiagnostics.app("launch")
for index in 0..<4 {
    VPNDiagnostics.beginTunnel(mode: "mode-\(index)")
    VPNDiagnostics.core("core-session-\(index)")
    VPNDiagnostics.stopRequested(1)
}
let report = CrashReportArchive.crashReportsDirectory.appendingPathComponent("2026-10-28")
try fm.createDirectory(at: report, withIntermediateDirectories: true)
try Data("DO-NOT-EXPORT-CONFIGURATION".utf8).write(to: report.appendingPathComponent("configuration.json"))
try Data("panic: example".utf8).write(to: report.appendingPathComponent("go.log"))
let url = try VPNDiagnostics.export()
defer { try? fm.removeItem(at: url) }
let text = try String(contentsOf: url, encoding: .utf8)
precondition(!text.contains("core-session-0"), "Oldest session retained")
for index in 1...3 { precondition(text.contains("core-session-\(index)"), "Recent incident overwritten") }
precondition(text.contains("[app] launch") && text.contains("stop requested reason=1"), "Lifecycle evidence missing")
precondition(text.contains("panic: example"), "Crash evidence missing")
precondition(!text.contains("DO-NOT-EXPORT-CONFIGURATION"), "Configuration leaked")
for _ in 0..<20 { VPNDiagnostics.event(String(repeating: "x", count: 8192)) }
VPNDiagnostics.termination("stop requested reason=8 (idleTimeout)")
VPNDiagnostics.termination("startup failed: cancelled by stop")
let floodedURL = try VPNDiagnostics.export()
defer { try? fm.removeItem(at: floodedURL) }
let flooded = try String(contentsOf: floodedURL, encoding: .utf8)
precondition(flooded.contains("stop requested reason=8 (idleTimeout)"), "Full event segment swallowed disconnect cause")
precondition(flooded.contains("startup failed: cancelled by stop"), "Startup cancellation evidence missing")
VPNDiagnostics.core("UNEXPECTED-MUST-SURVIVE")
VPNDiagnostics.stopRequested(2)
VPNDiagnostics.applicationError("persistent UI error", error: NSError(domain: "ArchiveTest", code: 17))
for _ in 0..<6 {
    VPNDiagnostics.beginTunnel(mode: "normal")
    VPNDiagnostics.stopRequested(1)
}
let durableURL = try VPNDiagnostics.export()
defer { try? fm.removeItem(at: durableURL) }
let durable = try String(contentsOf: durableURL, encoding: .utf8)
precondition(durable.contains("UNEXPECTED-MUST-SURVIVE"), "Session rotation removed unshared incident")
precondition(durable.contains("persistent UI error") && durable.contains("domain=ArchiveTest code=17"), "Application error was not retained")
try VPNDiagnostics.reset()
precondition(!fm.fileExists(atPath: report.path), "reset retained crash reports")
precondition(!fm.fileExists(atPath: url.path), "reset retained an exported diagnostic file")
VPNDiagnostics.app("fresh launch after reset")
let resetURL = try VPNDiagnostics.export()
defer { try? fm.removeItem(at: resetURL) }
let resetText = try String(contentsOf: resetURL, encoding: .utf8)
precondition(resetText.contains("fresh launch after reset"), "logging did not recover after reset")
precondition(!resetText.contains("UNEXPECTED-MUST-SURVIVE") && !resetText.contains("persistent UI error"), "reset retained diagnostics")
print("PASS")
''')
            executable = folder / 'check'
            result = subprocess.run([
                'xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'),
                str(ROOT / 'Library/Shared/RollingDiagnosticLog.swift'),
                str(ROOT / 'Library/Shared/VPNDiagnosticArchive.swift'),
                str(ROOT / 'Library/Shared/VPNDiagnostics.swift'), str(harness), '-o', str(executable)
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable), str(folder / 'data')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_retention_restart_size_and_redaction(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            harness = directory / 'main.swift'
            harness.write_text(r'''import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let log = try RollingDiagnosticLog(directory: directory, maximumSegmentBytes: 1024)
for minute in 0...20 {
    try log.append("minute-\(minute)", at: Date(timeIntervalSince1970: Double(minute * 60)))
}
let retained = try log.read()
precondition(!retained.contains("minute-9\n"), "Expired segment retained")
precondition(retained.contains("minute-10\n") && retained.contains("minute-20\n"), "Ten minute history missing")
let restarted = try RollingDiagnosticLog(directory: directory, maximumSegmentBytes: 1024)
let reopened = try restarted.read()
precondition(reopened == retained, "Restart destroyed disconnect evidence")
try restarted.append("after-idle", at: Date(timeIntervalSince1970: 86400))
let afterIdle = try restarted.read()
precondition(!afterIdle.contains("minute-"), "Stale active history retained after a day")
for _ in 0..<100 { try restarted.append(String(repeating: "x", count: 500), at: Date(timeIntervalSince1970: 86400)) }
let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
precondition(bytes <= 2048, "Per-minute disk cap exceeded")
let capped = try restarted.read()
precondition(capped.contains("truncated"), "Dropped logs must be visible")
let secret = DiagnosticRedaction.clean("https://user:password@example.com/api?token=private-token Bearer abc123 uuid=123e4567-e89b-12d3-a456-426614174000 private_key=topsecret")
precondition(DiagnosticRedaction.clean("\u{001B}[37mTRACE\u{001B}[0m") == "TRACE", "Terminal color codes leaked into readable document")
for value in ["password", "private-token", "abc123", "123e4567-e89b-12d3-a456-426614174000", "topsecret"] {
    precondition(!secret.contains(value), "Sensitive value persisted")
}
let parallel = try RollingDiagnosticLog(directory: directory.appendingPathComponent("parallel"))
DispatchQueue.concurrentPerform(iterations: 100) { index in try! parallel.append("entry-\(index)") }
let concurrent = try parallel.read()
precondition(concurrent.components(separatedBy: "\n").count == 101, "Concurrent lines lost")
print("PASS")
''')
            executable = directory / 'check'
            result = subprocess.run([
                'xcrun', 'swiftc', '-module-cache-path', str(directory / 'modules'),
                str(ROOT / 'Library/Shared/RollingDiagnosticLog.swift'), str(harness),
                '-o', str(executable)
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            checked = subprocess.run([str(executable), str(directory / 'logs')], capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
