"""Exercise the production legal document loader with an offline resource bundle."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LegalDocumentTests(unittest.TestCase):
    def test_documents_load_offline_and_missing_resources_fail_explicitly(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            bundle = folder / 'LegalFixture.bundle'
            (bundle / 'Legal').mkdir(parents=True)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'test.legal'}))
            for name in ['PrivacyPolicy', 'Licenses', 'SourceCode']:
                (bundle / 'Legal' / (name + '.txt')).write_text(name + ' — пример', encoding='utf-8')
            harness = folder / 'main.swift'
            harness.write_text('''import Foundation
@main struct Checks {
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        for document in PrototypeLegalDocument.allCases {
            let text = try document.text(in: bundle)
            precondition(text.contains("— пример"))
            precondition(!document.title.isEmpty)
        }
        let licenses = "Intro\\n\\n" + String(repeating: "=", count: 78) + "\\nLibrary A\\nA license\\n\\n" + String(repeating: "=", count: 78) + "\\nLibrary B\\nB license"
        let sections = PrototypeLegalDocument.licenseSections(from: licenses)
        precondition(sections.count == 2)
        precondition(sections[0].title == "Library A" && sections[0].text.contains("A license"))
        precondition(sections[1].title == "Library B" && sections[1].text.contains("B license"))
        precondition(PrototypeLegalDocument.licenseSections(from: "A single complete license").first?.text == "A single complete license")
        let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Legal/PrivacyPolicy.txt")
        try FileManager.default.removeItem(at: file)
        do {
            _ = try PrototypeLegalDocument.privacy.text(in: bundle)
            fatalError("Missing policy was silently accepted")
        } catch {}
        print("PASS")
    }
}''')
            executable = folder / 'checks'
            compile_result = subprocess.run([
                'xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                str(ROOT / 'PrototypeApp/PrototypeLegalDocument.swift'), str(harness), '-o', str(executable)
            ], capture_output=True, text=True)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            result = subprocess.run([str(executable), str(bundle)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS', result.stdout)


if __name__ == '__main__':
    unittest.main()
