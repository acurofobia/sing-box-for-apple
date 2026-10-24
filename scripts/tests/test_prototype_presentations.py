"""Exercise the production modal coordinator, including dismissal queues."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PresentationTests(unittest.TestCase):
    def test_presentations_are_serialized_and_removed_targets_close(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            harness = folder / 'main.swift'
            harness.write_text('''import Foundation
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
  coordinator.notice = "Second error"
  try await Task.sleep(for: .milliseconds(8500))
  precondition(coordinator.notice == "Second error", "previous timeout dismissed the new error")
  try await Task.sleep(for: .seconds(2))
  precondition(coordinator.notice == nil, "notice did not disappear after ten seconds")
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
