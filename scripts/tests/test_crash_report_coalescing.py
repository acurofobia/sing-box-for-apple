"""Run the Swift archive merger against local reports and count payload reads."""
import json
from datetime import datetime, timedelta
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / 'Library/Shared'


class CrashReportCoalescingTests(unittest.TestCase):
    def test_only_matching_single_logs_are_read_and_unusable_neighbours_are_preserved(self):
        manager = (ROOT / 'CrashReportManager.swift').read_text()
        coalesce = manager[manager.index('    private nonisolated static func coalesceArchivedCrashReports'):
                           manager.index('    public nonisolated func availableFiles')]
        scan = manager[manager.index('    private nonisolated static func loadArchivedReportRecords'):
                       manager.index('enum CrashReportMetadataBuilder')]
        swift = (ROOT / 'CrashReportArchive.swift').read_text() + '''
enum FilePath {
    static let workingDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
    static let sharedDirectory = workingDirectory
}
enum CrashReportMetadataBuilder {
    static func mergedMetadata(go: CrashReportMetadata, goContent: String, native: CrashReportMetadata,
                               nativeContent: String) -> CrashReportMetadata { go }
}
enum Merger {
    static func run() { coalesceArchivedCrashReports() }
''' + coalesce + scan
        swift = swift.replace('String(contentsOf:', 'readText(contentsOf:') + '''
func readText(contentsOf url: URL, encoding: String.Encoding) throws -> String {
    print(url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent)
    return try String(contentsOf: url, encoding: encoding)
}
Merger.run()
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            source = folder / 'main.swift'
            source.write_text(swift)
            executable = folder / 'merge'
            compiled = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'),
                                       str(source), '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)

            def report(seconds, kind, content, config=None, source='Application', bundle='app'):
                timestamp = datetime(2026, 1, 1) + timedelta(seconds=seconds)
                path = folder / 'crash_reports' / timestamp.strftime('%Y-%m-%dT%H-%M-%S')
                path.mkdir(parents=True)
                (path / 'metadata.json').write_text(json.dumps({'source': source, 'bundleIdentifier': bundle}))
                (path / kind).write_bytes(content)
                if config is not None:
                    (path / 'configuration.json').write_bytes(config)
                return path

            native = report(30, 'native.log', b'native stack', b'native config')
            bad_log = report(29, 'go.log', b'\xff')
            bad_config = report(28, 'go.log', b'log', b'\xff')
            nearest = report(27, 'go.log', b'go stack', b'go config')
            (nearest / '.read').touch()
            farther = report(24, 'go.log', b'farther', b'far config')
            mismatched = report(31, 'go.log', b'other', b'other config', bundle='extension')
            wrong_source = report(33, 'go.log', b'other process', source='NetworkExtension')
            unknown_files = report(34, 'go.log', b'keep sidecar')
            (unknown_files / 'extra.log').write_bytes(b'keep')
            old = report(1, 'go.log', b'old', b'old config')
            alone = report(90, 'native.log', b'alone', b'alone config')
            malformed = report(32, 'go.log', b'preserve directory')
            (malformed / 'native.log').mkdir()
            another_native = report(61, 'native.log', b'other native', b'fallback')
            another_go = report(60, 'go.log', b'other go')

            def files(path):
                return {f.name: f.read_bytes() if f.is_file() else None for f in path.iterdir()}

            unmatched = [farther, mismatched, wrong_source, unknown_files, old, alone, malformed]
            untouched = {p: files(p) for p in [bad_log, bad_config, *unmatched]}
            result = subprocess.run([str(executable), temporary], check=True, capture_output=True, text=True)
            self.assertFalse(native.exists())
            self.assertEqual((nearest / 'go.log').read_bytes(), b'go stack')
            self.assertEqual((nearest / 'native.log').read_bytes(), b'native stack')
            self.assertEqual((nearest / 'configuration.json').read_bytes(), b'go config')
            self.assertTrue((nearest / '.read').is_file())
            self.assertFalse(another_native.exists())
            self.assertEqual((another_go / 'configuration.json').read_bytes(), b'fallback')
            for path, expected in untouched.items():
                self.assertEqual(files(path), expected, path.name)
            reads = result.stdout.splitlines()
            self.assertIn(nearest.name + '/go.log', reads)
            for path in unmatched:
                self.assertFalse(any(line.startswith(path.name + '/') for line in reads), path.name)
