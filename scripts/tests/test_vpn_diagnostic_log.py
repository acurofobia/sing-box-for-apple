"""Run the production rolling log against real files, including restart and limits."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

from test_prototype_startup_cancellation import method

ROOT = Path(__file__).resolve().parents[2]

SUPPORT = r'''import Foundation
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
'''


class VPNDiagnosticLogTests(unittest.TestCase):
    def run_diagnostics(self, swift, timeout=10):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            harness = folder / 'main.swift'
            harness.write_text(SUPPORT + swift)
            executable = folder / 'check'
            sources = ROOT / 'Library/Shared'
            subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'),
                            str(sources / 'RollingDiagnosticLog.swift'), str(sources / 'VPNDiagnosticArchive.swift'),
                            str(sources / 'VPNDiagnostics.swift'), str(harness), '-o', str(executable)], check=True)
            try:
                result = subprocess.run([str(executable), str(folder / 'data')], capture_output=True,
                                        text=True, timeout=timeout, env={**os.environ, 'TMPDIR': temporary})
            except subprocess.TimeoutExpired:
                self.fail('diagnostics did not return while the dependency was unavailable')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_large_saved_export_releases_each_redacted_segment(self):
        self.run_diagnostics(r'''
let folder = FilePath.sharedDirectory.appendingPathComponent("Library/Application Support/VPNDiagnostics/application-errors")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let line = "2026-11-20T13:42:00Z [app error] update subscription domain=NSURLErrorDomain code=-1009 description=The Internet connection appears to be offline.\n"
let data = Data(String(repeating: line, count: (256 * 1024) / line.utf8.count).utf8)
for index in 0..<24 {
    try data.write(to: folder.appendingPathComponent(String(format: "%014d.log", index)))
}
func peakRSS() -> Int64 {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Int64(usage.ru_maxrss)
}
let before = peakRSS()
let file = try VPNDiagnostics.export()
defer { try? FileManager.default.removeItem(at: file) }
let report = try VPNDiagnostics.exportForReading()
defer { try? FileManager.default.removeItem(at: report.url) }
let last = try report.text(forPage: report.pageCount - 1)
precondition(report.pageCount > 300 && !last.isEmpty)
let increase = peakRSS() - before
if increase > 64 * 1024 * 1024 {
    print("6 MiB saved export increased peak resident memory by \(increase) bytes")
    exit(1)
}
let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
precondition(size >= data.count * 24, "Report was truncated")
''')

    def test_saved_pages_match_full_export_with_unicode_redaction_and_rotated_tail(self):
        self.run_diagnostics(r'''
let fm = FileManager.default
let folder = FilePath.sharedDirectory.appendingPathComponent("Library/Application Support/VPNDiagnostics")
try fm.createDirectory(at: folder, withIntermediateDirectories: true)
let text = String(repeating: "\u{FEFF}", count: 16_385) +
    String(repeating: "🌧️ заметка e\u{301} 👩‍💻\r\n", count: 2300) +
    "Authorization: Bearer test-value\nhttps://example.invalid/hidden\n"
try Data(text.utf8).write(to: folder.appendingPathComponent("b.log"))
// The historical tail starts in the middle of a UTF-8 scalar. Keep its replacement character.
let large = Data("DROPé".utf8) + Data(repeating: 65, count: 512 * 1024 - 1)
try large.write(to: folder.appendingPathComponent("a.txt"))
let report = try VPNDiagnostics.exportForReading()
defer { try? fm.removeItem(at: report.url) }
let output = try String(contentsOf: report.url, encoding: .utf8)
let expected = "\n--- a.txt (last 512 KiB) ---\n" + String(decoding: large.suffix(512 * 1024), as: UTF8.self) +
    "\n\n--- b.log ---\n" + DiagnosticRedaction.clean(text) + "\n"
precondition(output.hasSuffix(expected) && !output.contains("test-value") && !output.contains("example.invalid"))
var start = output.startIndex
for number in 0..<report.pageCount {
    let page = try report.text(forPage: number)
    let end = output.index(start, offsetBy: 16_384, limitedBy: output.endIndex) ?? output.endIndex
    precondition(page == output[start..<end])
    start = end
}
precondition(start == output.endIndex)
let firstAgain = try report.text(forPage: 0)
precondition(firstAgain == output.prefix(16_384))
let exports = report.url.deletingLastPathComponent()
let before = try fm.contentsOfDirectory(atPath: exports.path).sorted()
let unreadable = folder.appendingPathComponent("c.log")
try fm.createSymbolicLink(at: unreadable, withDestinationURL: unreadable)
do {
    _ = try VPNDiagnostics.export()
    print("Unreadable input did not fail the export"); exit(1)
} catch {
    let after = try fm.contentsOfDirectory(atPath: exports.path).sorted()
    precondition(before == after, "A partial or hidden export survived a read error")
}
''')

    def test_busy_archive_allows_status_logging_stop_and_saved_export(self):
        self.run_diagnostics(r'''
let fm = FileManager.default
let directory = FilePath.sharedDirectory.appendingPathComponent("Library/Application Support/VPNDiagnostics")
func session(_ time: Date) throws -> URL {
    let name = String(format: "%020.6f", time.timeIntervalSince1970) + "-" + UUID().uuidString
    let url = directory.appendingPathComponent("sessions/" + name)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    try Data().write(to: url.appendingPathComponent("tracked.txt"))
    return url
}
let ended = try session(Date().addingTimeInterval(-60))
let descriptor = open(directory.appendingPathComponent("archive.lock").path, O_CREAT | O_RDWR, 0o600)
precondition(descriptor >= 0 && flock(descriptor, LOCK_EX) == 0)
defer { close(descriptor) }
// The second notification queues behind the first. Neither may capture a future tunnel.
VPNDiagnostics.observeConnection(disconnected: true)
VPNDiagnostics.observeConnection(disconnected: true)
let live = try session(Date())
VPNDiagnostics.app("status changed")
VPNDiagnostics.expectStop()
let exported = try VPNDiagnostics.export()
defer { try? fm.removeItem(at: exported) }
let text = try String(contentsOf: exported, encoding: .utf8)
precondition(text.contains("status changed"))
precondition(fm.fileExists(atPath: live.appendingPathComponent("expected-stop.txt").path))
precondition(flock(descriptor, LOCK_UN) == 0)
let incidents = directory.appendingPathComponent("incidents")
let preserved = incidents.appendingPathComponent(ended.lastPathComponent)
let deadline = Date().addingTimeInterval(3)
while !fm.fileExists(atPath: preserved.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
precondition(fm.fileExists(atPath: preserved.path), "missed the disconnected tunnel")
// Clearing must finish previously submitted observations before acknowledging incidents.
try VPNDiagnostics.clearPreservedReports()
precondition(!fm.fileExists(atPath: live.appendingPathComponent("acknowledged.txt").path),
             "a later live tunnel was archived by a stale notification")
''')

    def test_saved_diagnostics_available_while_disconnect_reply_is_pending(self):
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        collect = method(app, '    func collectDiagnostics()')
        self.run_diagnostics(r'''
@MainActor struct CrashReportManager { func refresh() async {} }
@MainActor final class Model {
    var disconnectDiagnosticTask: Task<Void, Never>?
    let pending = AsyncStream<Void>.makeStream()
    func recordVPNState(force: Bool) {
        disconnectDiagnosticTask = Task { for await _ in pending.stream {} }
    }
''' + collect + r'''
}
VPNDiagnostics.app("already on disk")
let model = Model()
await model.collectDiagnostics()
let url = try VPNDiagnostics.export()
let text = try String(contentsOf: url, encoding: .utf8)
try FileManager.default.removeItem(at: url)
precondition(text.contains("already on disk"))
model.pending.continuation.finish()
await model.disconnectDiagnosticTask?.value
''', timeout=5)

    def test_export_preserves_three_latest_sessions_and_excludes_configuration(self):
        self.run_diagnostics(r'''
let fm = FileManager.default
let liveURL = try VPNDiagnostics.exportCurrentLogs(["first entry", "second token=test-secret"])
defer { try? fm.removeItem(at: liveURL) }
let live = try String(contentsOf: liveURL, encoding: .utf8)
precondition(liveURL.pathExtension == "txt" && live.contains("first entry\nsecond token=[redacted]"), "Live log file missing entries")
precondition(!live.contains("test-secret"), "Live export leaked credentials")
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
precondition(!text.contains("first entry") && !live.contains("[app] launch"), "Live and saved logs must be independent files")
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
