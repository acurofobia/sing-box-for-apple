"""Exercise the real diagnostic callback when reset cancels pending VPN work."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_prototype_startup_cancellation import method

ROOT = Path(__file__).resolve().parents[2]


class ResetDiagnosticsTests(unittest.TestCase):
    def test_reset_preserves_container_metadata_and_removes_app_files(self):
        source = (ROOT / 'PrototypeApp/Application.swift').read_text()
        cleanup = method(source, '            for file in try fm.contentsOfDirectory(')
        harness = r'''
import Foundation
enum FilePath {
    static let sharedDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
}
func resetSharedFiles() throws {
    let fm = FileManager.default
''' + cleanup + r'''
}
@main struct Checks {
    static func main() throws {
        let fm = FileManager.default
        let root = FilePath.sharedDirectory
        let metadata = root.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        let originalMetadata = Data("system-owned metadata".utf8)
        try originalMetadata.write(to: metadata)
        let preserved = ["Library", "device-access.lock", "device-access-fixture.json"]
        try fm.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        for name in preserved.dropFirst() { try Data("persistent".utf8).write(to: root.appendingPathComponent(name)) }
        let deleted = ["prototype-subscription.json", "prototype-subscription.json.refresh", "stderr.log", ".app-private-state", "runtime"]
        for name in deleted.dropLast() { try Data("app data".utf8).write(to: root.appendingPathComponent(name)) }
        try fm.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: root.appendingPathComponent("runtime/config.json"))
        try resetSharedFiles()
        guard fm.fileExists(atPath: metadata.path) else {
            throw NSError(domain: "ResetTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "reset deleted iOS container metadata"])
        }
        let retainedMetadata = try Data(contentsOf: metadata)
        precondition(retainedMetadata == originalMetadata)
        for name in preserved { precondition(fm.fileExists(atPath: root.appendingPathComponent(name).path), name) }
        for name in deleted { precondition(!fm.fileExists(atPath: root.appendingPathComponent(name).path), name) }
        try resetSharedFiles()
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            container = folder / 'container'
            container.mkdir()
            swift = folder / 'checks.swift'
            swift.write_text(harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(swift), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(executable), str(container)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)

    def test_reset_suppresses_notifications_and_cancelled_diagnostics(self):
        source = (ROOT / 'PrototypeApp/Application.swift').read_text()
        callback = method(source, '    func recordVPNState(')
        harness = r'''
import Foundation
enum State: Int { case disconnected, invalid, connected }
@MainActor enum VPNDiagnostics {
    static var events: [String] = []
    static func observeConnection(disconnected: Bool) { events.append("observed") }
    static func app(_ message: String) { events.append(message) }
    static func applicationError(_ message: String, error: Error) { events.append(message) }
}
@MainActor final class Connection {
    var status: State = .disconnected
    var connectedDate: Date?
    var fails = false
    func fetchLastDisconnectError() async throws {
        try? await Task.sleep(for: .milliseconds(20))
        if fails { throw NSError(domain: "OldDisconnect", code: 1) }
    }
}
struct Configuration { var disconnectOnSleep = false }
@MainActor final class Manager {
    let connection = Connection()
    var isEnabled = true
    var isOnDemandEnabled = false
    var protocolConfiguration: Configuration? = Configuration()
}
@MainActor final class Model {
    var manager: Manager? = Manager()
    var resetting = false
    var connectionGeneration: UInt64 = 0
    var lastDiagnosticState: State?
    var disconnectDiagnosticTask: Task<Void, Never>?
''' + callback + r'''
}
@main struct Checks {
    @MainActor static func main() async {
        let model = Model()
        model.resetting = true
        model.recordVPNState(force: true)
        await model.disconnectDiagnosticTask?.value
        precondition(VPNDiagnostics.events.isEmpty, "reset recorded a VPN status notification")
        model.resetting = false
        for fails in [false, true] {
            model.manager?.connection.fails = fails
            model.recordVPNState(force: true)
            VPNDiagnostics.events.removeAll()
            model.disconnectDiagnosticTask?.cancel()
            await model.disconnectDiagnosticTask?.value
            precondition(VPNDiagnostics.events.isEmpty, "cancelled diagnostic task recreated old logs")
        }
        model.recordVPNState(force: true)
        let previous = model.disconnectDiagnosticTask
        model.recordVPNState(force: true)
        let latest = model.disconnectDiagnosticTask
        VPNDiagnostics.events.removeAll()
        model.connectionGeneration += 1
        latest?.cancel()
        await previous?.value
        await latest?.value
        precondition(VPNDiagnostics.events.isEmpty, "an older diagnostic task survived reset")
        print("PASS")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            swift = folder / 'checks.swift'
            swift.write_text(harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                                     str(folder / 'modules'), str(swift), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
