"""Exercise source export against real temporary Git repositories."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'prepare_release_sources.py'


class ReleaseSourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'project'
        self.root.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Source test')
        self.write('main.swift', 'original\n')
        self.write('.gitignore', 'ignored.txt\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        spec = importlib.util.spec_from_file_location('release_sources', SCRIPT)
        self.assertTrue(SCRIPT.is_file(), 'source release exporter must exist')
        self.module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.module
        spec.loader.exec_module(self.module)

    def git(self, *args, root=None):
        return subprocess.run(['git', '-C', str(root or self.root), *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def collect(self, required=(), submodules=()):
        return self.module.collect_project(self.root, required=required,
                                           submodules=submodules)

    def test_current_modified_content_and_only_explicit_untracked(self):
        self.write('main.swift', 'modified\n')
        self.write('required.txt', 'legal resource\n')
        self.write('private.txt', 'private\n')
        self.write('ignored.txt', 'ignored\n')
        files, provenance = self.collect(required=('required.txt',))
        self.assertEqual(files['main.swift'].read_bytes(), b'modified\n')
        self.assertIn('required.txt', files)
        self.assertNotIn('private.txt', files)
        self.assertNotIn('ignored.txt', files)
        self.assertTrue(provenance[0]['dirty'])

    def test_sensitive_tracked_paths_are_excluded(self):
        for name in ('output/design/reference.txt', '.env', 'keys/key.pem',
                     'PrototypeApp/vless-outbound.json', 'build/log.txt', '.netrc',
                     '.git-credentials', 'credentials.json', 'development.env'):
            self.write(name, 'private\n')
            self.git('add', '-f', name)
        files, _ = self.collect()
        self.assertEqual(set(files), {'.gitignore', 'main.swift'})

    def test_missing_required_and_ignored_required_fail(self):
        with self.assertRaises(self.module.SourceError):
            self.collect(required=('absent.txt',))
        self.write('ignored.txt', 'ignored')
        with self.assertRaises(self.module.SourceError):
            self.collect(required=('ignored.txt',))

    def test_deleted_tracked_file_fails_closed(self):
        (self.root / 'main.swift').unlink()
        with self.assertRaises(self.module.SourceError):
            self.collect()

    def test_symlink_never_dereferenced(self):
        (self.root / 'link.swift').symlink_to('/etc/passwd')
        self.git('add', 'link.swift')
        with self.assertRaises(self.module.SourceError):
            self.collect()

    def test_required_submodule_uses_dirty_content_and_omits_other_nested_repo(self):
        nested = self.root / 'core'
        nested.mkdir()
        self.git('init', '-q', root=nested)
        self.git('config', 'user.email', 'test@example.invalid', root=nested)
        self.git('config', 'user.name', 'test', root=nested)
        self.write('core/core.go', 'clean')
        self.git('add', '.', root=nested)
        self.git('commit', '-qm', 'core', root=nested)
        self.git('add', 'core')
        unrelated = self.root / 'other-client'
        unrelated.mkdir()
        self.git('init', '-q', root=unrelated)
        self.git('config', 'user.email', 'test@example.invalid', root=unrelated)
        self.git('config', 'user.name', 'test', root=unrelated)
        self.write('other-client/private.txt', 'unrelated')
        self.git('add', '.', root=unrelated)
        self.git('commit', '-qm', 'unrelated', root=unrelated)
        self.git('add', 'other-client')
        self.write('core/core.go', 'dirty')
        files, provenance = self.collect(submodules=('core',))
        self.assertEqual(files['core/core.go'].read_text(), 'dirty')
        self.assertNotIn('other-client/private.txt', files)
        self.assertEqual(len(provenance), 2)
        self.assertTrue(provenance[1]['dirty'])
        with self.assertRaises(self.module.SourceError):
            self.collect(submodules=('missing',))

    def test_reviewed_license_symlink_is_preserved_and_target_changes_rejected(self):
        self.write('LICENSE', 'license')
        folder = self.root / 'SFM.System/Resources'
        folder.mkdir(parents=True)
        (folder / 'LICENSE').symlink_to('../../LICENSE')
        self.git('add', 'LICENSE', 'SFM.System/Resources/LICENSE')
        files, _ = self.collect()
        target = Path(self.temp.name) / 'links.tar.gz'
        self.module.write_bundle(files, {}, target)
        with tarfile.open(target) as archive:
            member = archive.getmember('vipin-source/SFM.System/Resources/LICENSE')
            self.assertTrue(member.issym())
            self.assertEqual(member.linkname, '../../LICENSE')
        (folder / 'LICENSE').unlink()
        (folder / 'LICENSE').symlink_to('/etc/passwd')
        with self.assertRaises(self.module.SourceError):
            self.collect()

    def test_dependency_source_build_directory_is_preserved(self):
        dependency = Path(self.temp.name) / 'dependency'
        (dependency / 'go/build').mkdir(parents=True)
        (dependency / 'go/build/build.go').write_text('package build')
        files = {}
        self.module.add_tree(files, dependency, 'dependencies/go/toolchain/src/')
        self.assertIn('dependencies/go/toolchain/src/go/build/build.go', files)

    def license_manifest(self, notice_path='notice.txt', digest=None):
        digest = digest or hashlib.sha256(b'license notice').hexdigest()
        manifest = {'font': {'notices': [{'path': notice_path, 'sha256': digest}]},
                    'packages': [{'name': 'example', 'notices': []}]}
        self.write('scripts/license_sources/manifest.json', json.dumps(manifest))
        return ('scripts/license_sources/manifest.json',)

    def test_license_manifest_includes_only_referenced_notices(self):
        required = self.license_manifest()
        self.write('scripts/license_sources/notice.txt', 'license notice')
        self.write('scripts/license_sources/private.txt', 'private')
        self.git('add', 'scripts/license_sources/private.txt')
        files, _ = self.collect(required=required)
        self.assertIn('scripts/license_sources/manifest.json', files)
        self.assertIn('scripts/license_sources/notice.txt', files)
        self.assertNotIn('scripts/license_sources/private.txt', files)

    def test_license_manifest_missing_notice_fails(self):
        required = self.license_manifest()
        with self.assertRaises(self.module.SourceError):
            self.collect(required=required)

    def test_license_manifest_hash_mismatch_fails(self):
        required = self.license_manifest()
        self.write('scripts/license_sources/notice.txt', 'changed notice')
        with self.assertRaises(self.module.SourceError):
            self.collect(required=required)

    def test_license_manifest_path_escape_fails(self):
        for name in ('../outside.txt', '/tmp/outside.txt', 'sub/../../outside.txt',
                     'C:\\private.txt', '.env', ''):
            with self.subTest(path=name):
                required = self.license_manifest(notice_path=name)
                with self.assertRaises(self.module.SourceError):
                    self.collect(required=required)

    def test_archive_is_reproducible_and_hashes_cover_bytes(self):
        files, provenance = self.collect()
        destination = Path(self.temp.name)
        a = self.module.write_bundle(files, {'repositories': provenance}, destination / 'a.tar.gz')
        b = self.module.write_bundle(files, {'repositories': provenance}, destination / 'b.tar.gz')
        self.assertEqual(a, b)
        self.assertEqual(a, hashlib.sha256((destination / 'a.tar.gz').read_bytes()).hexdigest())
        with tarfile.open(destination / 'a.tar.gz') as archive:
            manifest = json.load(archive.extractfile('vipin-source/SOURCE-MANIFEST.json'))
            for name, expected in manifest['files'].items():
                data = archive.extractfile('vipin-source/' + name).read()
                self.assertEqual(hashlib.sha256(data).hexdigest(), expected['sha256'])
        self.assertEqual((destination / 'a.tar.gz.sha256').read_text().split()[0], a)


if __name__ == '__main__':
    unittest.main()
