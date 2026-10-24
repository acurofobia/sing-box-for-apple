"""Compile the actual Swift UI decoder and exercise the version-one contract."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DOCUMENT = {'schemaVersion': 1, 'blocks': [
    {'id': 'block01', 'type': 'card', 'title': 'Plan', 'buttons': []},
    {'id': 'block04', 'type': 'selectionList', 'items': [
        {'id': 'option01', 'title': 'Renamed transport', 'text': '',
         'state': 'available', 'buttons': [], 'detailsPageId': 'page01'}]},
    {'id': 'block06', 'type': 'progress', 'value': 0, 'maximum': 100, 'unit': 'bytes'}],
    'pages': [{'id': 'page01', 'title': 'Details', 'text': ''}]}


class UIDocumentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        folder = Path(cls.directory.name)
        harness = folder / 'main.swift'
        harness.write_text('''import Foundation
@main struct Checks {
 static func main() {
  do {
   let document = try PrototypeUIDocument.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
   let decoded = try PrototypeUIDocument.decode(JSONEncoder().encode(document))
   print(decoded.blocks.count)
  } catch { print("invalid"); exit(1) }
 }
}''')
        cls.executable = folder / 'checks'
        source = ROOT / 'PrototypeApp/SubscriptionUIDocument.swift'
        result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                                 str(source), str(harness), '-o', str(cls.executable)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def check(self, document, valid=True):
        payload = document if isinstance(document, bytes) else json.dumps(document, ensure_ascii=False).encode()
        path = Path(self.directory.name) / 'input.json'
        path.write_bytes(payload)
        result = subprocess.run([str(self.executable), str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)

    def test_valid_document_and_unknown_ids(self):
        self.check(DOCUMENT)
        doc = copy.deepcopy(DOCUMENT)
        doc['blocks'][0]['id'] = 'futureBlock'
        self.check(doc)

    def test_duplicate_keys_including_escaped_keys_are_rejected(self):
        for payload in [b'{"schemaVersion":1,"schemaVersion":1,"blocks":[],"pages":[]}',
                        b'{"schemaVersion":1,"blocks":[],"\\u0062locks":[],"pages":[]}']:
            self.check(payload, False)

    def test_version_types_and_unknown_fields(self):
        for version in [True, 1.0, 2, '1', None]:
            self.check(dict(DOCUMENT, schemaVersion=version), False)
        self.check(dict(DOCUMENT, future=True), False)

    def test_hidden_invalid_elements_and_slot_types(self):
        doc = copy.deepcopy(DOCUMENT)
        doc['blocks'][0].update(visible=False, future=True)
        self.check(doc, False)
        doc = copy.deepcopy(DOCUMENT)
        doc['blocks'][0]['type'] = 'valueRow'
        self.check(doc, False)

    def test_identifiers_references_and_integer_ranges(self):
        for change in ['duplicate', 'missingPage', 'wrongBlock', 'bool', 'float', 'overflow', 'zero', 'above']:
            doc = copy.deepcopy(DOCUMENT)
            if change == 'duplicate': doc['pages'][0]['id'] = 'option01'
            elif change == 'missingPage': doc['pages'] = []
            elif change == 'wrongBlock':
                doc['blocks'][0]['buttons'] = [{'id': 'button01', 'title': 'Open',
                                              'action': {'type': 'openBlock', 'targetId': 'block04'}}]
            else:
                doc['blocks'][2]['value'] = {'bool': True, 'float': 1.0, 'overflow': 9007199254740992,
                                            'zero': 0, 'above': 101}[change]
                if change == 'zero': doc['blocks'][2]['maximum'] = 0
            self.check(doc, False)

    def test_unpaired_surrogates_are_rejected(self):
        self.check(b'{"schemaVersion":1,"blocks":[],"pages":[{"id":"page01","title":"Title","text":"\\ud800"}]}', False)

    def test_identifier_cannot_end_with_newline(self):
        doc = copy.deepcopy(DOCUMENT)
        doc['blocks'][0]['id'] = 'block01\n'
        self.check(doc, False)

    def test_external_url_validation(self):
        for url in ['https://example.org/path', 'https://t.me/example', 'HTTPS://example.org/path', 'http://example.org',
                    'https://user:secret@example.org', 'https://example.org:99999',
                    'https://example.org/with space', 'https://example.org/\\x', 'javascript:alert(1)']:
            doc = copy.deepcopy(DOCUMENT)
            doc['blocks'][0]['buttons'] = [{'id': 'button01', 'title': 'Open',
                                          'action': {'type': 'openExternalUrl', 'url': url}}]
            self.check(doc, url in ['https://example.org/path', 'https://t.me/example', 'HTTPS://example.org/path'])

    def test_text_dates_size_and_unicode(self):
        self.check(dict(DOCUMENT, pages=[{'id': 'page01', 'title': 'Details', 'text': '😀' * 32768}]))
        doc = copy.deepcopy(DOCUMENT)
        doc['pages'][0]['text'] = 'x' * 32769
        self.check(doc, False)
        for date in ['2026-10-18T12:30:00Z', '2026-10-18T12:30:00.123+05:00', '2026-10-18T12:30Z', '2026-10-18T12:30:00+0500', '2026-10-18T12:30:00', '2026-02-30T12:00:00Z', '2026-10-18T12:30:00+99:99', '2026-10-18T12:30:00Z\n', 'bad']:
            doc = copy.deepcopy(DOCUMENT)
            doc['blocks'][2]['resetAt'] = date
            self.check(doc, date in ['2026-10-18T12:30:00Z', '2026-10-18T12:30:00.123+05:00', '2026-10-18T12:30Z', '2026-10-18T12:30:00+0500'])
        self.check(b' ' * (1024 * 1024 + 1), False)
        self.check(b'{"schemaVersion":1,"blocks":[],"pages":[]}\xff', False)
