"""Exercise the production modal coordinator, including dismissal queues."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PresentationTests(unittest.TestCase):
    def test_error_presentation_does_not_loop_or_reopen_a_dismissed_notice(self):
        view = (ROOT / 'PrototypeApp/PrototypeView.swift').read_text()
        model = (ROOT / 'PrototypeApp/Application.swift').read_text()
        publishers = '\n'.join(line for line in model.splitlines() if line.strip().startswith((
            'lazy var errorChanges', 'lazy var subscriptionErrorChanges')))
        start = next(view.index(marker) for marker in [
            '        .onReceive(model.', '        .onChange(of: model.error'] if marker in view)
        end = view.index('        .onChange(of: presentation.notice)', start)
        harness = r'''import AppKit
import SwiftUI
@MainActor final class Model: ObservableObject {
    var recovery: String?
    var importProgress: String?
    @Published var error: String?
    @Published var subscriptionError: String?
    // ERROR_PUBLISHERS
}
struct ErrorView: View {
    @ObservedObject var model: Model
    @ObservedObject var presentation: PrototypePresentationCoordinator
    var body: some View {
        Text(presentation.notice ?? "No error").frame(width: 320, height: 120)
        // ERROR_OBSERVERS
    }
}
@main struct Checks {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = Model()
        model.error = "Initial error"
        let presentation = PrototypePresentationCoordinator()
        let window = NSWindow(contentViewController: NSHostingController(rootView: ErrorView(model: model, presentation: presentation)))
        window.title = "Vipin UI regression test"
        window.orderFront(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            print("FAIL: error presentation blocked the main run loop")
            exit(2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            precondition(presentation.notice == "Initial error", "initial error was not presented")
            model.error = "Stop VPN before changing configurations"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            precondition(presentation.notice == model.error, "application error was not presented")
            presentation.notice = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            precondition(presentation.notice == nil, "dismissed error was replayed on a view update")
            model.error = nil
            model.error = "Stop VPN before changing configurations"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            precondition(presentation.notice == model.error, "repeated synchronous error was not presented")
            presentation.notice = nil
            model.subscriptionError = "HTTP 503"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            precondition(presentation.notice == model.subscriptionError, "subscription error was not presented")
            presentation.notice = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            precondition(presentation.notice == nil, "dismissed subscription error was replayed")
            model.subscriptionError = nil
            model.subscriptionError = "HTTP 503"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            precondition(presentation.notice == model.subscriptionError, "repeated synchronous subscription error was not presented")
            presentation.notice = nil
            model.importProgress = "downloading"
            model.subscriptionError = "Import failed"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
            precondition(presentation.notice == nil, "import dialog error also appeared in a banner")
            print("PASS")
            exit(0)
        }
        application.run()
    }
}
'''.replace('// ERROR_OBSERVERS', view[start:end]).replace('// ERROR_PUBLISHERS', publishers)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / 'checks.swift'
            source.write_text(harness)
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                                     str(ROOT / 'PrototypeApp/SubscriptionUIDocument.swift'),
                                     str(ROOT / 'PrototypeApp/PrototypeLegalDocument.swift'),
                                     str(ROOT / 'PrototypeApp/PresentationCoordinator.swift'), str(source),
                                     '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)

    def test_presentations_are_serialized_and_removed_targets_close(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            harness = folder / 'main.swift'
            harness.write_text('''import Combine
import Foundation
@main struct Checks {
 @MainActor static func main() async throws {
  let coordinator = PrototypePresentationCoordinator()
  coordinator.show(.modes)
  coordinator.show(.page("page01"))
  precondition(coordinator.destination == .modes && !coordinator.drawerExpanded)
  coordinator.show(.subscription)
  coordinator.completeDismissal()
  precondition(coordinator.destination == .page("page01"), "repeated request replaced pending destination")
  coordinator.show(.dialog("block03"))
  precondition(coordinator.destination == nil)
  coordinator.completeDismissal()
  precondition(coordinator.destination == .dialog("block03"))
  coordinator.show(.external(URL(string: "https://example.org")!))
  precondition(coordinator.externalURL == nil, "external link opened before dialog closed")
  coordinator.show(.subscription)
  try await Task.sleep(for: .milliseconds(400))
  precondition(coordinator.destination == nil && coordinator.externalURL?.host == "example.org")
  coordinator.show(.page("missing"))
  coordinator.reconcile(nil)
  precondition(coordinator.destination == nil)
  coordinator.completeDismissal()
  coordinator.show(.modes)
  coordinator.reconcile(nil)
  precondition(!coordinator.drawerExpanded)
  coordinator.completeDismissal()
  precondition(coordinator.destination == nil)
  coordinator.notice = "First error"
  try await Task.sleep(for: .seconds(2))
  let clock = ContinuousClock()
  var dismissal: ContinuousClock.Instant?
  let observation = coordinator.$notice.dropFirst().sink { notice in
   if notice == nil { dismissal = clock.now }
  }
  let shown = clock.now
  coordinator.notice = "Second error"
  let deadline = shown.advanced(by: .seconds(15))
  while coordinator.notice != nil, clock.now < deadline {
   precondition(coordinator.notice == "Second error", "replacement notice changed while waiting for dismissal")
   try await Task.sleep(for: .milliseconds(20))
  }
  precondition(coordinator.notice == nil, "replacement notice never disappeared")
  precondition(dismissal.map { shown.duration(to: $0) >= .seconds(10) } == true,
               "previous timeout dismissed the new error early")
  observation.cancel()
  coordinator.notice = "Dismiss manually"
  coordinator.notice = nil
  precondition(coordinator.notice == nil)
  print("PASS")
 }
}''')
            executable = folder / 'checks'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                                     str(ROOT / 'PrototypeApp/SubscriptionUIDocument.swift'),
                                     str(ROOT / 'PrototypeApp/PrototypeLegalDocument.swift'),
                                     str(ROOT / 'PrototypeApp/PresentationCoordinator.swift'), str(harness),
                                     '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
