"""Verify this handoff's integrity; works with Python 3 standard library."""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    manifest = json.loads((ROOT / 'MANIFEST.json').read_text(encoding='utf-8'))
    errors = []
    expected = {entry['path']: entry for entry in manifest['files']}
    for relative, entry in expected.items():
        file = ROOT / relative
        if not file.is_file():
            errors.append('Missing file: ' + relative)
            continue
        data = file.read_bytes()
        if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            errors.append('Changed file: ' + relative)
    for file in ROOT.rglob('*'):
        if not file.is_file():
            continue
        if file.suffix.lower() == '.sketch':
            continue
        relative = file.relative_to(ROOT).as_posix()
        if relative != 'MANIFEST.json' and relative not in expected:
            errors.append('Unlisted file: ' + relative)
        if file.suffix == '.json':
            try:
                json.loads(file.read_text(encoding='utf-8'))
            except (ValueError, UnicodeError) as error:
                errors.append(str(error) + ': ' + relative)
    screens = json.loads((ROOT / 'design/spec/screens.json').read_text(encoding='utf-8'))['screens']
    if len(screens) != 11:
        errors.append('Expected 11 design screens')
    for item in screens:
        for key, size in [('png1x', (390, 844)), ('png2x', (780, 1688))]:
            data = (ROOT / item[key]).read_bytes()
            if data[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', data[16:24]) != size:
                errors.append('Invalid PNG dimensions: ' + item[key])
        layout = json.loads((ROOT / item['layout']).read_text(encoding='utf-8'))
        if layout['sketchFrameId'] != item['sketchFrameId'] or not layout['nodes']:
            errors.append('Invalid layout: ' + item['layout'])
        if not (ROOT / item['appScreenshot']).is_file():
            errors.append('Missing app reference: ' + item['appScreenshot'])
    if errors:
        print('\n'.join(errors))
        return 1
    print('OK: %d files, 11 screens at 1x and 2x, resolved layouts and JSON integrity.' % len(expected))
    return 0

if __name__ == '__main__':
    sys.exit(main())
