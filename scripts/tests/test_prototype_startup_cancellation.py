"""Run provider stop ordering with a blocked startup and a cancellation race."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def method(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class StartupCancellationTests(unittest.TestCase):
    def test_stop_cancels_blocked_start_and_latches_before_server_publication(self):
        source = (ROOT / 'Extension/PacketTunnelProvider.swift').read_text()
        stop = method(source, '    override func stopTunnel(')
        prepare = method(source, '    override func prepareServiceStart(')
        startup = method(source, '    override func startTunnel(')
        clear_deadline = method(source, '    private func clearServiceDeadline(')
        failure = startup.rsplit('        } catch {', 1)[1].rsplit('        }', 1)[0]
        harness = r'''
import Foundation
private enum NEProviderStopReason: Int { case userInitiated = 1, providerFailed = 2 }
private enum VPNDiagnostics {
 static func startupFailed(_ message: String) {}
 static func event(_ message: String) {}
 static func termination(_ message: String) {}
 static func stopRequested(_ reason: Int) {}
 static func stopReason(_ value: Int) -> String { String(value) }
}
private final class LibboxCommandServer: @unchecked Sendable {
 let lock = NSLock()
 var cancelled = false
 func cancelServiceStart() { lock.withLock { cancelled = true } }
 func isCancelled() -> Bool { lock.withLock { cancelled } }
}
private class ExtensionProvider {
 func stopTunnel(with reason: NEProviderStopReason) async {}
 func prepareServiceStart(_ server: LibboxCommandServer) throws {}
}
private final class Capture {
 var error: String?
 func fail(_ message: String) { error = message }
 func setHealthServer(_ server: LibboxCommandServer?) {}
 func setFailoverServer(_ server: LibboxCommandServer?) {}
 func stop() {}
}
private func LibboxCancelVKTurnPrototype() {}
private func LibboxStopVKTurnPrototype(_ id: Int64) {}
private func LibboxSetVKTurnPrototypeLogServer(_ server: LibboxCommandServer?) {}
private final class PacketTunnelProvider: ExtensionProvider {
 let stateLock = NSLock()
 var stopReason: NEProviderStopReason?
 var commandServer: LibboxCommandServer?
 var sessionID: Int64 = 0
 var startupFinished: AsyncStream<Void>?
 var startingServer: LibboxCommandServer?
 var capture: Capture?
 var serviceDeadline: DispatchWorkItem?
 var serviceSession: String?
''' + clear_deadline + '\n' + prepare + '\n' + stop + r'''
 func finishFailedStart(_ error: Error, capture: Capture) async throws {
''' + failure + r'''
 }
}
@main struct Checks {
 static func main() async throws {
  let coreError = NSError(domain: "libbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "context canceled"])
  for cancel in [false, true] {
   let provider = PacketTunnelProvider()
   let capture = Capture()
   if cancel { await provider.stopTunnel(with: .userInitiated) }
   do { try await provider.finishFailedStart(coreError, capture: capture) } catch {}
   precondition(capture.error == (cancel ? nil : coreError.localizedDescription),
                "a user stop must not publish a startup failure, an unsolicited failure must still be reported")
  }
  for early in [false, true] {
   let provider = PacketTunnelProvider()
   let server = LibboxCommandServer()
   let completion = AsyncStream<Void>.makeStream()
   provider.startupFinished = completion.stream
   if !early { try provider.prepareServiceStart(server) }
   // A fallback bounds the regression test even when production stop hangs.
   let startup = Task {
    for _ in 0..<200 {
     if server.isCancelled() { break }
     try? await Task.sleep(for: .milliseconds(5))
    }
    completion.continuation.finish()
   }
   let start = ContinuousClock.now
   let deadline = DispatchWorkItem {}
   provider.serviceDeadline = deadline
   provider.serviceSession = "test-session"
   let stopping = Task { await provider.stopTunnel(with: .userInitiated) }
   if early {
    try await Task.sleep(for: .milliseconds(20))
    do { try provider.prepareServiceStart(server); fatalError("stop allowed later core start") }
    catch is CancellationError { server.cancelServiceStart() }
   }
   await stopping.value
   await startup.value
   precondition(start.duration(to: .now) < .milliseconds(400), "stop waited for probe deadline")
   precondition(server.isCancelled(), "core startup context was not cancelled")
   precondition(deadline.isCancelled && provider.serviceSession == nil, "service lifetime timer survived stop")
   precondition(provider.startingServer == nil, "server reference retained after stop")
  }
  print("PASS")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'checks.swift').write_text(harness)
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                                     str(folder / 'checks.swift'), '-o', str(folder / 'checks')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(folder / 'checks')], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
