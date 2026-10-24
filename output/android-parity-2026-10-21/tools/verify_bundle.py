"""Check this specification bundle without running apps or contacting a network."""
import csv
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    errors = []
    manifest = json.loads((ROOT / 'MANIFEST.json').read_text(encoding='utf-8'))
    expected = {entry['path']: entry for entry in manifest['files']}
    for relative, entry in expected.items():
        path = ROOT / relative
        if not path.is_file():
            errors.append('Missing: ' + relative)
            continue
        data = path.read_bytes()
        if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            errors.append('Changed: ' + relative)
        if path.suffix == '.json':
            try:
                json.loads(data.decode('utf-8'))
            except (ValueError, UnicodeError):
                errors.append('Invalid JSON: ' + relative)
    for path in ROOT.rglob('*'):
        if path.is_file():
            relative = path.relative_to(ROOT).as_posix()
            if relative != 'MANIFEST.json' and relative not in expected:
                errors.append('Unlisted: ' + relative)

    spec = (ROOT / 'SPECIFICATION.md').read_text(encoding='utf-8')
    requirements = re.findall(r'^\*\*(REQ-\d+)\.\*\*', spec, re.MULTILINE)
    required = {'REQ-%02d' % index for index in range(1, 73)}
    if len(requirements) != 72 or set(requirements) != required:
        errors.append('Expected exactly 72 distinct numbered requirements')
    with (ROOT / 'ACCEPTANCE.csv').open(encoding='utf-8-sig', newline='') as stream:
        cases = list(csv.DictReader(stream))
    if len(cases) != 93 or len({case['case_id'] for case in cases}) != 93:
        errors.append('Expected 93 distinct acceptance cases')
    covered = {item for case in cases for item in re.findall(r'REQ-\d+', case['requirements'])}
    if covered != required:
        errors.append('Acceptance requirements coverage differs: ' + str(covered ^ required))
    for case in cases:
        if case['status'] not in {'not-run', 'pass', 'fail', 'blocked'}:
            errors.append('Invalid case status: ' + case['case_id'])

    inputs = json.loads((ROOT / 'SOURCE_MANIFEST.json').read_text(encoding='utf-8'))
    for entry in inputs['files']:
        path = ROOT / entry['snapshot']
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            errors.append('Source snapshot mismatch: ' + entry['snapshot'])

    original = ROOT / 'design-handoff'
    original_manifest = json.loads((original / 'MANIFEST.json').read_text(encoding='utf-8'))
    for entry in original_manifest['files']:
        path = original / entry['path']
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            errors.append('Original handoff mismatch: ' + entry['path'])
    screens = json.loads((original / 'design/spec/screens.json').read_text(encoding='utf-8'))['screens']
    if len(screens) != 11:
        errors.append('Expected 11 original design states')
    for screen in screens:
        for key, size in [('png1x', (390, 844)), ('png2x', (780, 1688))]:
            data = (original / screen[key]).read_bytes()
            if data[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', data[16:24]) != size:
                errors.append('Invalid design PNG: ' + screen[key])
    with zipfile.ZipFile(original / 'design/source/sing-vpn-interface.sketch') as sketch:
        if sketch.testzip() is not None:
            errors.append('Sketch CRC error')

    if errors:
        print('\n'.join(errors))
        return 1
    print('OK: %d files; 72 requirements; 93 acceptance cases; 101 source snapshots; original 11-screen handoff intact.' % len(expected))
    return 0


if __name__ == '__main__':
    sys.exit(main())
