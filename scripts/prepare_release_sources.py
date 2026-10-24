#!/usr/bin/env python3
"""Prepare a deterministic, local-only source release from the current worktree.

No network requests, Git mutations, or implicit untracked-file inclusion.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
import tempfile

SUBMODULES = ('upstream/sing-box', 'ThirdParty/VKTurnProxy', 'Frameworks/Runestone')
TAGS = 'with_gvisor,with_wireguard,with_utls,with_clash_api,with_low_memory,badlinkname,tfogo_checklinkname0'
LICENSE_MANIFEST = 'scripts/license_sources/manifest.json'
SWIFT_PACKAGES = ('binarycodable', 'legacybinarycodable', 'grdb.swift', 'devicekit', 'plcrashreporter')
REQUIRED = (
    'scripts/prepare_release_sources.py', 'scripts/tests/test_release_sources.py',
    'scripts/prepare_release_site.py', 'docs/release/export-options.plist',
    'docs/release/testflight-submission.md', 'docs/release/testflight-metadata.json',
    'docs/release/branding/shield-check.svg', 'docs/release/branding/LICENSE.lucide',
    'docs/release/branding/SOURCE.json', 'docs/release/branding/render.swift',
    'scripts/generate_release_licenses.py', 'scripts/tests/test_release_licenses.py',
    LICENSE_MANIFEST,
    'scripts/tests/test_release_diagnostics.py',
    'PrototypeApp/Legal/Licenses.txt', 'PrototypeApp/Legal/DependencyLicenses.json',
    'docs/release/source-distribution.md',
    'PrototypeApp/PrototypeLegalDocument.swift', 'PrototypeApp/PrototypeLegalView.swift',
    'PrototypeApp/Legal/PrivacyPolicy.txt', 'PrototypeApp/Legal/SourceCode.txt',
    'scripts/tests/test_release_legal.py', 'SFIUITests/PrototypeLegalTests.swift',
    'docs/release/permissions.md', 'docs/release/privacy-policy-publication.md',
    'Extension/PrivacyInfo.xcprivacy', 'Library/PrivacyInfo.xcprivacy',
    'PrototypeApp/PrivacyInfo.xcprivacy',
    'docs/testing/testflight-readiness-2026-10-22.md',
    'docs/testing/testflight-go-dependencies-2026-10-22.json',
)
BLOCKED_PARTS = {'.git', '.env', '.ssh', '.aws', '.codex', '.claude', 'xcuserdata',
                 '__pycache__', 'node_modules', 'build', 'output', '.build', '.swiftpm',
                 'credentials', 'secrets', 'keys'}
BLOCKED_SUFFIXES = {'.pem', '.p12', '.p8', '.key', '.mobileprovision', '.keystore', '.jks', '.env'}


class SourceError(RuntimeError):
    """A source release cannot safely be prepared."""


def command(args, cwd, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode:
        # Do not echo arbitrary subprocess output that might contain local secrets.
        raise SourceError(f'{args[0]} {args[1]} failed (exit {result.returncode}); check local prerequisites')
    return result.stdout


def allowed(name, dependency=False):
    blocked = BLOCKED_PARTS - {'build', 'output', 'keys'} if dependency else BLOCKED_PARTS
    path = PurePosixPath(name)
    return (not path.is_absolute() and '..' not in path.parts
            and not any(part.lower() in blocked or part.lower().startswith('.env')
                        for part in path.parts)
            and path.suffix.lower() not in BLOCKED_SUFFIXES
            and path.name.lower() not in {
                'vless-outbound.json', 'local.properties', '.netrc', '.git-credentials',
                'credentials.json', '.mcp.json', '.npmrc', 'id_rsa', 'id_ed25519'}
            and not path.name.startswith('.vless-')
            and not path.name.lower().endswith(('.xcframework', '.aar', '.apk', '.ipa')))


def checked_file(root, name):
    path = root / name
    # Reject symlinks in every component, even if their target stays inside root.
    current = root
    for part in PurePosixPath(name).parts:
        current = current / part
        if current.is_symlink():
            raise SourceError(f'Symlink requires explicit source review: {name}')
    if not path.is_file() or not stat.S_ISREG(path.stat().st_mode):
        raise SourceError(f'Required source file missing or not regular: {name}')
    return path


def repository_files(root, prefix='', required_submodules=(), provenance=None):
    if command(['git', 'rev-parse', '--show-toplevel'], root).strip() != str(root.resolve()):
        raise SourceError(f'Not an initialized repository: {prefix or "."}')
    entries = command(['git', 'ls-files', '--stage', '-z'], root).split('\0')
    files = {}
    gitlinks = set()
    for entry in filter(None, entries):
        metadata, name = entry.split('\t', 1)
        mode, _, stage = metadata.split()
        if stage != '0':
            raise SourceError(f'Unresolved merge: {prefix}{name}')
        if mode == '160000':
            gitlinks.add(name)
            continue
        if not allowed(name) or (not prefix and name.startswith('scripts/license_sources/')):
            continue
        if mode == '120000':
            path = root / name
            if not path.is_symlink() or Path(os.readlink(path)).is_absolute():
                raise SourceError(f'Unsafe source symlink: {prefix}{name}')
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(root) or not allowed(resolved.relative_to(root).as_posix()):
                raise SourceError(f'Unsafe source symlink: {prefix}{name}')
            files[prefix + name] = path
        else:
            files[prefix + name] = checked_file(root, name)
    for name, path in files.items():
        if path.is_symlink():
            target = prefix + path.resolve().relative_to(root).as_posix()
            if target not in {'.', prefix + '.'} and target not in files and not any(
                    item.startswith(target.rstrip('/') + '/') for item in files):
                raise SourceError(f'Symlink target not included in sources: {name}')
    revision = command(['git', 'rev-parse', 'HEAD'], root).strip()
    dirty = bool(command(['git', 'status', '--porcelain', '--untracked-files=no'], root).strip())
    provenance.append({'path': prefix.rstrip('/') or '.', 'revision': revision, 'dirty': dirty})
    for child in required_submodules:
        if child not in gitlinks:
            raise SourceError(f'Required submodule not registered: {child}')
        files.update(repository_files(root / child, prefix + child + '/', provenance=provenance))
    return files


def collect_project(root, required=REQUIRED, submodules=SUBMODULES):
    root = root.resolve()
    provenance = []
    files = repository_files(root, required_submodules=submodules, provenance=provenance)
    for name in required:
        files[name] = required_file(root, name)
    if LICENSE_MANIFEST in required:
        add_license_notices(root, files)
    return files, provenance


def required_file(root, name):
    if not allowed(name):
        raise SourceError(f'Unsafe required path: {name}')
    ignored = subprocess.run(['git', '-C', str(root), 'check-ignore', '-q', '--no-index', name],
                             capture_output=True).returncode
    if ignored == 0:
        raise SourceError(f'Required path is ignored: {name}')
    if ignored != 1:
        raise SourceError(f'Cannot check ignore rules: {name}')
    return checked_file(root, name)


def add_license_notices(root, files):
    manifest_path = files[LICENSE_MANIFEST]
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict) or not isinstance(manifest.get('font'), dict) or not isinstance(
            manifest.get('packages'), list):
        raise SourceError('Invalid license source manifest structure')
    for component in [manifest['font'], *manifest['packages']]:
        if not isinstance(component, dict) or not isinstance(component.get('notices'), list):
            raise SourceError('Invalid license source notices')
        for notice in component['notices']:
            if not isinstance(notice, dict):
                raise SourceError('Invalid license source notice entry')
            relative, expected = notice.get('path'), notice.get('sha256')
            if (not isinstance(relative, str) or not relative or "\\" in relative or ":" in relative
                    or not allowed(relative) or PurePosixPath(relative).as_posix() != relative
                    or not isinstance(expected, str) or re.fullmatch('[0-9a-f]{64}', expected) is None):
                raise SourceError('Unsafe license source notice path or hash')
            name = 'scripts/license_sources/' + relative
            path = required_file(root, name)
            if file_hash(path) != expected:
                raise SourceError(f'License source notice hash mismatch: {name}')
            files[name] = path


def add_tree(files, directory, prefix):
    if not directory.is_dir() or directory.is_symlink():
        raise SourceError(f'Missing dependency directory: {prefix}')
    for path in sorted(directory.rglob('*')):
        relative = path.relative_to(directory).as_posix()
        if not allowed(relative, dependency=True):
            continue
        if path.is_symlink():
            raise SourceError(f'Dependency contains a symlink: {prefix}{relative}')
        if path.is_file():
            files[prefix + relative] = checked_file(directory, relative)


def decode_json_stream(value):
    decoder = json.JSONDecoder()
    while value.strip():
        value = value.lstrip()
        item, end = decoder.raw_decode(value)
        yield item
        value = value[end:]


def escaped_module(value):
    return re.sub('[A-Z]', lambda match: '!' + match[0].lower(), value)


def add_go_sources(root, files):
    core = root / 'upstream/sing-box'
    env = dict(os.environ, GOPROXY='off', GOSUMDB='off', GOTOOLCHAIN='local', GOWORK='off')
    goenv = json.loads(command(['go', 'env', '-json', 'GOMODCACHE', 'GOROOT', 'GOVERSION'], core, env))
    modules = {}
    selections = [('ios', 'arm64', ['./experimental/libbox']),
                  ('ios', 'amd64', ['./experimental/libbox']),
                  ('darwin', 'arm64', ['github.com/sagernet/gomobile/cmd/gomobile',
                                        'github.com/sagernet/gomobile/cmd/gobind'])]
    for goos, arch, packages in selections:
        selected_env = dict(env, GOOS=goos, GOARCH=arch, CGO_ENABLED='1')
        output = command(['go', 'list', '-mod=readonly', '-deps', '-tags', TAGS,
                          '-json=Module', *packages], core, selected_env)
        for package in decode_json_stream(output):
            module = package.get('Module')
            if module:
                effective = module.get('Replace', module)
                if not effective.get('Version'):
                    location = Path(effective['Dir']).resolve()
                    if location not in {core.resolve(), (root / 'ThirdParty/VKTurnProxy').resolve()}:
                        raise SourceError('Unexpected local Go replacement requires explicit inclusion')
                    continue
                modules[(effective['Path'], effective['Version'])] = effective
    inventory = []
    for (name, version), module in sorted(modules.items()):
        destination = f'dependencies/go/modules/{escaped_module(name)}@{escaped_module(version)}/'
        add_tree(files, Path(module['Dir']), destination)
        inventory.append({'module': name, 'version': version, 'source': destination.rstrip('/')})
    # Preserve available graph metadata as well as imported source modules.
    # Unselected module graphs may be incomplete in an offline developer cache.
    graph = list(decode_json_stream(command(['go', 'list', '-mod=readonly', '-m', '-e', '-json', 'all'], core, env)))
    cache = Path(goenv['GOMODCACHE']) / 'cache/download'
    for module in graph:
        effective = module.get('Replace', module)
        if not effective.get('Version'):
            continue
        name, version = effective['Path'], effective['Version']
        base = f'{escaped_module(name)}/@v/{escaped_module(version)}'
        if (name, version) not in modules and not (cache / (base + '.mod')).is_file():
            continue
        extensions = ['.mod']
        if (name, version) in modules:
            extensions += ['.zip', '.ziphash']
            if (cache / (base + '.info')).is_file():
                extensions.append('.info')
        for extension in extensions:
            relative = base + extension
            files['dependencies/go/cache/download/' + relative] = checked_file(cache, relative)
    goroot = Path(goenv['GOROOT'])
    add_tree(files, goroot / 'src', 'dependencies/go/toolchain/src/')
    for name in ('LICENSE', 'PATENTS', 'VERSION'):
        source_root = goroot if (goroot / name).is_file() else goroot.parent
        files['dependencies/go/toolchain/' + name] = checked_file(source_root, name)
    return {'version': goenv['GOVERSION'], 'tags': TAGS, 'modules': inventory,
            'scope': 'iOS arm64 and amd64 libbox plus darwin/arm64 gomobile and gobind tooling',
            'toolchain_source': 'dependencies/go/toolchain/src; host compiler binaries are not bundled'}


def add_swift_sources(root, files, checkouts):
    lock = root / 'sing-box.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    pins = {pin['identity']: pin for pin in json.loads(lock.read_text())['pins']}
    candidates = {path.name.lower(): path for path in checkouts.iterdir() if path.is_dir()}
    inventory = []
    for identity in SWIFT_PACKAGES:
        pin = pins.get(identity)
        checkout = candidates.get(identity)
        if pin is None or checkout is None:
            raise SourceError(f'Missing pinned Swift package checkout: {identity}')
        provenance = []
        package_files = repository_files(checkout, provenance=provenance)
        if provenance[0]['revision'] != pin['state']['revision'] or provenance[0]['dirty']:
            raise SourceError(f'Swift checkout differs from pinned revision: {identity}')
        for name, path in package_files.items():
            files[f'dependencies/swift/{identity}/{name}'] = path
        inventory.append({'identity': identity, 'revision': pin['state']['revision'],
                          'version': pin['state'].get('version'), 'url': pin['location']})
    return inventory


def file_hash(path):
    digest = hashlib.sha256()
    if path.is_symlink():
        return hashlib.sha256(os.readlink(path).encode()).hexdigest()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write_bundle(files, metadata, destination):
    manifest = dict(metadata)
    manifest['files'] = {name: {'sha256': file_hash(path), 'size': path.lstat().st_size,
                                  **({'symlink': os.readlink(path)} if path.is_symlink() else {})}
                         for name, path in sorted(files.items())}
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Atomic replacement prevents incomplete outputs looking like release archives.
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with temporary_path.open('wb') as output:
            with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as archive:
                    for name, path in sorted(files.items()):
                        info = tarfile.TarInfo('vipin-source/' + name)
                        if path.is_symlink():
                            info.type = tarfile.SYMTYPE
                            info.linkname = os.readlink(path)
                            info.mode = 0o777
                            archive.addfile(info)
                        else:
                            info.size = manifest['files'][name]['size']
                            info.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                            with path.open('rb') as content:
                                archive.addfile(info, content)
                        if file_hash(path) != manifest['files'][name]['sha256']:
                            raise SourceError(f'Source changed during export: {name}')
                    info = tarfile.TarInfo('vipin-source/SOURCE-MANIFEST.json')
                    info.size = len(manifest_bytes)
                    info.mode = 0o644
                    archive.addfile(info, io.BytesIO(manifest_bytes))
        digest = file_hash(temporary_path)
        temporary_path.replace(destination)
        destination.with_name(destination.name + '.sha256').write_text(f'{digest}  {destination.name}\n')
        destination.with_name(destination.name + '.manifest.json').write_bytes(manifest_bytes)
        return digest
    finally:
        temporary_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift-checkouts', type=Path,
                        help='Pinned Xcode SourcePackages/checkouts directory')
    parser.add_argument('--check', action='store_true', help='Validate and enumerate without writing an archive')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        files, provenance = collect_project(root)
        metadata = {'format': 1, 'repositories': provenance, 'explicit_release_files': list(REQUIRED),
                    'binary_correspondence': 'Source export alone does not establish correspondence; consult per-release build provenance for rebuilt binaries.',
                    'go': add_go_sources(root, files),
                    'swift_packages': add_swift_sources(root, files, args.swift_checkouts or
                                                        root / 'build/DerivedData/SourcePackages/checkouts')}
        if args.check:
            print(f'Validated {len(files)} source/dependency files; no archive written.')
            return
        destination = root / 'build/release/vipin-source.tar.gz'
        digest = write_bundle(files, metadata, destination)
        print(f'{destination}\nSHA256 {digest}\nFiles: {len(files)}')
    except (SourceError, OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Source release aborted: {error}\n')


if __name__ == '__main__':
    main()
