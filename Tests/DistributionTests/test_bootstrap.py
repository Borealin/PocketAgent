import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


MODULE = Path(__file__).resolve().parents[2] / 'Scripts/bootstrap.py'
spec = importlib.util.spec_from_file_location('bootstrap', MODULE)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)

# Fixture Git commands ignore the developer's global/system configuration.
ISOLATED_GIT = {'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
                'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}
LIB = 'pub fn upstream() {}\npub fn tunnel() -> u8 { 0 }\npub fn tail() {}\n'


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *map(str, args)], check=True,
                          text=True, capture_output=True).stdout


class IdeviceCheckoutTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, ISOLATED_GIT)
        environment.start()
        self.addCleanup(environment.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.upstream = base / 'upstream'
        self.root = base / 'pocketagent'
        self.missing = str(base / 'missing-remote')
        self.write(self.upstream / 'ffi/src/lib.rs', LIB)
        self.write(self.upstream / 'ffi/Cargo.toml', '[package]\nname = "idevice-ffi"\n')
        self.write(self.upstream / 'README.md', 'idevice\n')
        git(base, 'init', '-q', self.upstream)
        git(self.upstream, 'config', 'uploadpack.allowAnySHA1InWant', 'true')
        git(self.upstream, 'add', '-A')
        git(self.upstream, 'commit', '-q', '-m', 'pin')
        self.revision = git(self.upstream, 'rev-parse', 'HEAD').strip()
        # The main branch's patch, already applied in existing checkouts.
        self.old_patch = self.diff({'ffi/src/lib.rs': LIB.replace('{ 0 }', '{ 1 }')})
        self.new_patch = self.diff({'ffi/src/lib.rs': LIB.replace('{ 0 }', '{ 2 }'),
                                    'ffi/Cargo.toml': '[package]\nname = "idevice-ffi"\n[features]\nddi = []\n'})
        self.next_patch = self.diff({'ffi/src/lib.rs': LIB.replace('{ 0 }', '{ 3 }')})
        # Later upstream history: the pin is fetched by revision, not branch tip.
        self.write(self.upstream / 'README.md', 'later\n')
        git(self.upstream, 'commit', '-q', '-am', 'later')
        self.spec = {'url': str(self.upstream), 'revision': self.revision}
        self.write(self.root / 'Native/ddi/mod.rs', 'pub fn ddi() {}\n')
        self.write(self.root / 'Native/idevice.patch', self.new_patch)
        self.parent = self.root / '.deps' / bootstrap.MANAGED

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def diff(self, edits):
        for name, text in edits.items():
            (self.upstream / name).write_text(text)
        text = git(self.upstream, 'diff')
        git(self.upstream, 'checkout', '-q', '--', '.')
        return text

    def prepare(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            path = bootstrap.prepare_idevice(self.root, self.spec)
        return path, output.getvalue()

    def legacy_checkout(self):
        """Reproduce the previous bootstrap's in-place .deps/idevice result."""
        legacy = self.root / '.deps/idevice'
        legacy.mkdir(parents=True)
        git(legacy, 'init', '-q')
        git(legacy, 'remote', 'add', 'origin', self.upstream)
        git(legacy, 'fetch', '-q', '--depth', '1', 'origin', self.revision)
        git(legacy, 'checkout', '-q', '--detach', self.revision)
        old = self.root.parent / 'old.patch'
        old.write_text(self.old_patch)
        git(legacy, 'apply', old)
        shutil.copytree(self.root / 'Native/ddi', legacy / 'ffi/src/pocket_ddi')
        return legacy

    @staticmethod
    def snapshot(repo):
        files = {str(p.relative_to(repo)): p.read_bytes() for p in sorted(repo.rglob('*'))
                 if p.is_file() and '.git' not in p.relative_to(repo).parts}
        return (files, git(repo, 'rev-parse', 'HEAD'),
                git(repo, 'status', '--porcelain', '--untracked-files=all'))

    def state(self, path):
        return (path / '.git' / bootstrap.STATE).read_text()

    def test_old_patch_checkout_is_left_untouched_and_current_patch_gets_new_checkout(self):
        legacy = self.legacy_checkout()
        current = self.root / 'Native/idevice.patch'
        # The previous in-place upgrade could neither recognize nor apply the new patch.
        for check in [['--reverse', '--check'], ['--check']]:
            self.assertNotEqual(0, subprocess.run(['git', '-C', str(legacy), 'apply', *check, str(current)],
                                                  capture_output=True).returncode)
        (legacy / 'README.md').write_text('unknown local edit\n')
        (legacy / 'scratch.txt').write_text('untracked user file\n')
        before = self.snapshot(legacy)
        # Objects come from the legacy checkout; no remote is reachable.
        self.spec['url'] = self.missing
        path, output = self.prepare()
        self.assertEqual(self.snapshot(legacy), before)
        self.assertIn('left untouched', output)
        self.assertEqual(path, bootstrap.idevice_checkout_path(self.root, self.spec))
        self.assertEqual(git(path, 'rev-parse', 'HEAD').strip(), self.revision)
        self.assertEqual((path / 'ffi/src/lib.rs').read_text(), LIB.replace('{ 0 }', '{ 2 }'))
        self.assertIn('ddi = []', (path / 'ffi/Cargo.toml').read_text())
        self.assertEqual((path / 'README.md').read_text(), 'idevice\n')
        self.assertEqual((path / 'ffi/src/pocket_ddi/mod.rs').read_text(), 'pub fn ddi() {}\n')

    def test_repeated_setup_reuses_verified_checkout_and_refreshes_native_ddi(self):
        first, _ = self.prepare()
        recorded = self.state(first)
        self.spec['url'] = self.missing
        (self.root / 'Native/ddi/mod.rs').write_text('pub fn updated() {}\n')
        (self.root / 'Native/ddi/extra.rs').write_text('pub fn extra() {}\n')
        # Build output and the bootstrap-owned DDI copy are not local edits.
        (first / 'ffi/idevice.h').write_text('/* generated */\n')
        (first / 'ffi/src/pocket_ddi/stale.rs').write_text('stale\n')
        second, output = self.prepare()
        self.assertEqual(second, first)
        self.assertEqual(self.state(second), recorded)
        self.assertNotIn('Legacy', output)
        self.assertEqual(sorted(p.name for p in (second / 'ffi/src/pocket_ddi').iterdir()), ['extra.rs', 'mod.rs'])
        self.assertEqual((second / 'ffi/src/pocket_ddi/mod.rs').read_text(), 'pub fn updated() {}\n')
        self.assertEqual(sorted(p.name for p in self.parent.iterdir()), ['.lock', first.name, 'objects.git'])
        self.assertEqual(git(first, 'rev-parse', 'HEAD').strip(), self.revision)

    def test_next_patch_revision_creates_another_checkout_from_the_object_cache(self):
        first, _ = self.prepare()
        recorded = self.state(first)
        self.write(self.root / 'Native/idevice.patch', self.next_patch)
        self.spec['url'] = self.missing
        second, _ = self.prepare()
        self.assertNotEqual(second, first)
        self.assertEqual((second / 'ffi/src/lib.rs').read_text(), LIB.replace('{ 0 }', '{ 3 }'))
        self.assertNotIn('ddi = []', (second / 'ffi/Cargo.toml').read_text())
        # The superseded checkout is retained exactly; returning to its patch reuses it.
        self.assertEqual((first / 'ffi/src/lib.rs').read_text(), LIB.replace('{ 0 }', '{ 2 }'))
        self.assertEqual(self.state(first), recorded)
        self.write(self.root / 'Native/idevice.patch', self.new_patch)
        again, _ = self.prepare()
        self.assertEqual(again, first)

    def test_unknown_edits_in_managed_checkout_are_refused_and_preserved(self):
        path, _ = self.prepare()
        (path / 'README.md').write_text('local edit\n')
        (path / 'notes.txt').write_text('mine\n')
        before = self.snapshot(path)
        with self.assertRaises(SystemExit) as raised:
            self.prepare()
        message = str(raised.exception.code)
        self.assertIn('local edits', message)
        self.assertIn('README.md', message)
        self.assertIn('notes.txt', message)
        self.assertEqual(self.snapshot(path), before)
        # A moved HEAD is refused as well; nothing is reset.
        git(path, 'commit', '-qam', 'local commit')
        head = git(path, 'rev-parse', 'HEAD')
        with self.assertRaises(SystemExit):
            self.prepare()
        self.assertEqual(git(path, 'rev-parse', 'HEAD'), head)
        self.assertEqual((path / 'README.md').read_text(), 'local edit\n')

    def test_patch_failure_and_interruption_leave_no_partial_checkout(self):
        self.write(self.root / 'Native/idevice.patch',
                   self.old_patch.replace('-pub fn tunnel() -> u8 { 0 }', '-pub fn absent() -> u8 { 0 }'))
        with self.assertRaises(SystemExit) as raised:
            self.prepare()
        self.assertIn('does not apply', str(raised.exception.code))
        self.assertEqual(sorted(p.name for p in self.parent.iterdir()), ['.lock', 'objects.git'])
        self.write(self.root / 'Native/idevice.patch', self.new_patch)
        with patch.object(bootstrap, 'worktree_tree', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.prepare()
        self.assertEqual(sorted(p.name for p in self.parent.iterdir()), ['.lock', 'objects.git'])
        # Staging left by a killed run is discarded; the next run completes.
        self.write(self.parent / '.staging-killed/ffi/src/lib.rs', 'partial\n')
        path, _ = self.prepare()
        self.assertEqual(sorted(p.name for p in self.parent.iterdir()), ['.lock', path.name, 'objects.git'])
        self.assertEqual((path / 'ffi/src/lib.rs').read_text(), LIB.replace('{ 0 }', '{ 2 }'))
        # A run stopped after publication but before the DDI copy recovers too.
        shutil.rmtree(path / 'ffi/src/pocket_ddi')
        again, _ = self.prepare()
        self.assertEqual(again, path)
        self.assertTrue((path / 'ffi/src/pocket_ddi/mod.rs').is_file())


if __name__ == '__main__':
    unittest.main()
