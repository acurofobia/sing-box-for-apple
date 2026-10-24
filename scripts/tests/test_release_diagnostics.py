"""Compile the real post-connect startup path in Debug and Release modes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

HARNESS = r'''
import Foundation

private final class Capture {
    var phase = "startup"
    func setPhase(_ value: String) { phase = value }
}

// Replace only the expensive Go profiler; preserve its NSError failure contract.
private func LibboxVerifyVKTurnPrototypeOOMProfiles(_ directory: String, _ error: inout NSError?) {
    if CommandLine.arguments[1] == "fail" {
        error = NSError(domain: "profile-io", code: 1)
    }
}

private func finishStartup(baseline: Bool, vless: Bool, stopped: Bool = false) async throws -> String {
    let capture = Capture()
    let stateLock = NSLock()
    let directory = FileManager.default.temporaryDirectory
__STARTUP__
    return capture.phase
}

@main struct Checks {
    static func main() async throws {
        for (baseline, vless, phase) in [(true, false, "baseline"), (false, false, "combined"), (false, true, "vless")] {
            do {
                let result = try await finishStartup(baseline: baseline, vless: vless)
                #if DEBUG
                    precondition(baseline || CommandLine.arguments[1] != "fail", "Debug stopped exercising the profiler")
                #endif
                precondition(result == phase, "Startup never reached its connected phase")
            } catch {
                #if DEBUG
                    precondition(!baseline && CommandLine.arguments[1] == "fail", "Unexpected startup failure")
                #else
                    fatalError("Release startup failed because of diagnostic profiling: \(error)")
                #endif
            }
        }
        do {
            _ = try await finishStartup(baseline: true, vless: false, stopped: true)
            fatalError("Startup cancellation guard was lost")
        } catch is CancellationError {}
        print("PASS")
    }
}
'''


class ReleaseDiagnosticsTests(unittest.TestCase):
    def test_release_excludes_profiler_call_and_keeps_startup_phase_and_cancellation(self):
        source = (ROOT / 'Extension/PacketTunnelProvider.swift').read_text()
        # Keep the production conditional directives and cancellation/phase updates intact.
        startup = source.split('commandServer?.writeMessage(4, message: "[VPN] Connected: "', 1)[1]
        startup = startup.split('\n', 1)[1].split('        } catch {', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            swift = folder / 'checks.swift'
            swift.write_text(HARNESS.replace('__STARTUP__', startup))
            for configuration, flags in [('Release', []), ('Debug', ['-D', 'DEBUG'])]:
                with self.subTest(configuration=configuration):
                    command = ['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'), *flags]
                    sil = subprocess.run([*command, '-emit-silgen', str(swift)], capture_output=True, text=True)
                    self.assertEqual(sil.returncode, 0, sil.stderr)
                    # The linked Go archive can retain the function definition. What must
                    # disappear in Release is the Swift startup's reference to that function.
                    references = [line for line in sil.stdout.splitlines()
                                  if 'function_ref ' in line and 'LibboxVerifyVKTurnPrototypeOOMProfiles' in line]
                    self.assertEqual(bool(references), configuration == 'Debug', '\n'.join(references))
                    executable = folder / configuration
                    compiled = subprocess.run([*command, str(swift), '-o', str(executable)], capture_output=True, text=True)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    for outcome in ['ok', 'fail']:
                        run = subprocess.run([str(executable), outcome], capture_output=True, text=True, timeout=10)
                        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
