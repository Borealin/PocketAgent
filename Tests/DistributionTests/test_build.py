import importlib.util
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch


MODULE = Path(__file__).resolve().parents[2] / 'Scripts/build.py'
spec = importlib.util.spec_from_file_location('build', MODULE)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class RunnerPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runner = self.root / 'Runner.app'
        self.tests = self.runner / 'PlugIns/WebDriverAgentRunner.xctest'
        self.destination = self.runner / 'Frameworks/WebDriverAgentRunner.framework'
        # An arm64 MH_BUNDLE header makes the executable's bundle type an
        # explicit fixture property; no compiled code or signing identity is used.
        self.macho = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 8, 0, 0, 0, 0)
        self.bundle(self.runner, 'WebDriverAgentRunner-Runner', 'APPL')
        self.bundle(self.tests, 'WebDriverAgentRunner', 'BNDL')
        self.bundle(self.tests / 'Frameworks/WebDriverAgentLib.framework', 'WebDriverAgentLib', 'FMWK')
        (self.tests / 'Resources').mkdir()
        (self.tests / 'Resources/nested-resource.txt').write_text('retained resource\n')
        (self.tests / '.hidden-resource').write_bytes(b'hidden resource')

    def bundle(self, path, executable, package_type):
        path.mkdir(parents=True)
        (path / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'test.' + executable,
            'CFBundleExecutable': executable,
            'CFBundlePackageType': package_type,
        }))
        (path / executable).write_bytes(self.macho)
        (path / executable).chmod(0o755)

    def snapshot(self, path):
        return {str(p.relative_to(path)): (p.read_bytes(), stat.S_IMODE(p.stat().st_mode))
                for p in path.rglob('*') if p.is_file()}

    def test_relocation_preserves_complete_test_bundle_and_removes_plugins(self):
        before = self.snapshot(self.tests)
        result = build.relocate_runner_test_bundle(self.runner)
        self.assertEqual(result, self.destination)
        self.assertEqual(self.snapshot(result), before)
        self.assertFalse((self.runner / 'PlugIns').exists())
        info = plistlib.loads((result / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundlePackageType'], 'BNDL')
        self.assertEqual(info['CFBundleExecutable'], 'WebDriverAgentRunner')
        self.assertEqual(struct.unpack('<8I', (result / 'WebDriverAgentRunner').read_bytes())[3], 8)
        self.assertTrue((result / 'Frameworks/WebDriverAgentLib.framework/WebDriverAgentLib').is_file())

    def test_unexpected_plugin_is_rejected_without_moving_test_module(self):
        (self.runner / 'PlugIns/Other.appex').mkdir()
        before = self.snapshot(self.runner)
        with self.assertRaisesRegex(ValueError, 'Unexpected runner PlugIns entries: Other.appex'):
            build.relocate_runner_test_bundle(self.runner)
        self.assertEqual(self.snapshot(self.runner), before)
        self.assertTrue(self.tests.is_dir())
        self.assertFalse(self.destination.exists())

    def test_destination_collision_is_rejected_without_overwriting(self):
        self.destination.mkdir(parents=True)
        (self.destination / 'keep.txt').write_text('existing bundle')
        before = self.snapshot(self.runner)
        with self.assertRaisesRegex(ValueError, 'destination already exists'):
            build.relocate_runner_test_bundle(self.runner)
        self.assertEqual(self.snapshot(self.runner), before)
        self.assertTrue(self.tests.is_dir())

    def test_missing_module_is_rejected(self):
        self.tests.rename(self.tests.with_name('Missing.xctest'))
        with self.assertRaisesRegex(ValueError, 'missing PlugIns/WebDriverAgentRunner.xctest'):
            build.relocate_runner_test_bundle(self.runner)
        self.assertFalse(self.destination.exists())

    def test_empty_or_invalid_test_bundle_is_rejected(self):
        (self.tests / 'WebDriverAgentRunner').unlink()
        with self.assertRaisesRegex(ValueError, 'missing its executable'):
            build.relocate_runner_test_bundle(self.runner)
        (self.tests / 'WebDriverAgentRunner').write_bytes(self.macho)
        (self.tests / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'WebDriverAgentRunner', 'CFBundlePackageType': 'APPL'}))
        with self.assertRaisesRegex(ValueError, 'unexpected executable or package type'):
            build.relocate_runner_test_bundle(self.runner)
        self.assertTrue(self.tests.is_dir())
        self.assertFalse(self.destination.exists())

    def test_signer_enumerates_test_framework_and_nested_library_before_parent(self):
        build.relocate_runner_test_bundle(self.runner)
        (self.root / '.build').mkdir()
        with patch.object(build, 'ROOT', self.root), patch.object(build, 'run') as run:
            build.sign(self.runner)
        signed = [call.args[0][-1] for call in run.call_args_list
                  if call.args[0][:2] == ['codesign', '--force']]
        self.assertEqual(signed, [
            self.destination / 'Frameworks/WebDriverAgentLib.framework',
            self.destination,
            self.runner,
        ])
        self.assertEqual(run.call_args_list[-1].args[0],
                         ['codesign', '--verify', '--deep', '--strict', self.runner])

    def prepare_fixture(self):
        original = self.root / '.build/WDA/Build/Products/Release-iphoneos/WebDriverAgentRunner-Runner.app'
        original.parent.mkdir(parents=True)
        self.runner.rename(original)
        self.bundle(original / 'Frameworks/XCTest.framework', 'XCTest', 'FMWK')
        (original / 'Debug.dSYM').mkdir()
        (self.root / 'Native').mkdir()
        (self.root / 'Native/WebDriverAgent-LICENSE.txt').write_text('fixture license')
        return original

    def test_prepare_runner_mutates_only_packaging_copy_and_moves_after_runtime_cleanup(self):
        original = self.prepare_fixture()
        before = self.snapshot(original)
        config = {'runnerBundleIdentifier': 'test.release.runner', 'minimumOSVersion': '26.0'}
        with patch.object(build, 'ROOT', self.root), patch.object(build, 'run'), \
                patch.object(build, 'sign') as sign:
            prepared = build.prepare_runner(config, '0.4.0', '4')
        self.assertEqual(self.snapshot(original), before)
        self.assertTrue((original / 'PlugIns/WebDriverAgentRunner.xctest').is_dir())
        self.assertTrue((original / 'Frameworks/XCTest.framework').is_dir())
        packed_tests = prepared / 'Frameworks/WebDriverAgentRunner.framework'
        self.assertEqual(self.snapshot(packed_tests), self.snapshot(original / 'PlugIns/WebDriverAgentRunner.xctest'))
        self.assertFalse((prepared / 'PlugIns').exists())
        self.assertFalse((prepared / 'Frameworks/XCTest.framework').exists())
        self.assertFalse((prepared / 'Debug.dSYM').exists())
        self.assertEqual(plistlib.loads((prepared / 'Info.plist').read_bytes())['CFBundleIdentifier'],
                         'test.release.runner')
        sign.assert_called_once_with(prepared, None)

    def test_prepare_runner_removes_sibling_test_symbols_before_relocating_code(self):
        original = self.prepare_fixture()
        symbols = original / 'PlugIns/WebDriverAgentRunner.xctest.dSYM/Contents/Resources/DWARF'
        symbols.mkdir(parents=True)
        (symbols / 'WebDriverAgentRunner').write_bytes(b'fixture debug symbols')
        before = self.snapshot(original)
        config = {'runnerBundleIdentifier': 'test.release.runner', 'minimumOSVersion': '26.0'}
        with patch.object(build, 'ROOT', self.root), patch.object(build, 'run'), \
                patch.object(build, 'sign') as sign:
            prepared = build.prepare_runner(config, '0.4.0', '4')
        self.assertEqual(self.snapshot(original), before)
        self.assertTrue(symbols.is_dir())
        packed_tests = prepared / 'Frameworks/WebDriverAgentRunner.framework'
        self.assertEqual(self.snapshot(packed_tests), self.snapshot(original / 'PlugIns/WebDriverAgentRunner.xctest'))
        self.assertFalse((prepared / 'PlugIns').exists())
        self.assertEqual(list(prepared.rglob('*.dSYM')), [])
        sign.assert_called_once_with(prepared, None)

    def test_prepare_runner_still_rejects_unknown_plugins_after_symbol_cleanup(self):
        original = self.prepare_fixture()
        (original / 'PlugIns/WebDriverAgentRunner.xctest.dSYM').mkdir()
        (original / 'PlugIns/Unknown.appex').mkdir()
        before = self.snapshot(original)
        config = {'runnerBundleIdentifier': 'test.release.runner', 'minimumOSVersion': '26.0'}
        with patch.object(build, 'ROOT', self.root), patch.object(build, 'run') as run, \
                patch.object(build, 'sign') as sign:
            with self.assertRaisesRegex(ValueError, 'Unexpected runner PlugIns entries: Unknown.appex'):
                build.prepare_runner(config, '0.4.0', '4')
        self.assertEqual(self.snapshot(original), before)
        prepared = self.root / '.build/Packaging/WebDriverAgentRunner-Runner.app'
        self.assertTrue((prepared / 'PlugIns/WebDriverAgentRunner.xctest').is_dir())
        self.assertTrue((prepared / 'PlugIns/Unknown.appex').is_dir())
        self.assertEqual(list(prepared.rglob('*.dSYM')), [])
        self.assertFalse((prepared / 'Frameworks/WebDriverAgentRunner.framework').exists())
        run.assert_not_called()
        sign.assert_not_called()

    def test_prepare_runner_rejects_collision_before_runtime_cleanup(self):
        original = self.prepare_fixture()
        collision = original / 'Frameworks/WebDriverAgentRunner.framework'
        collision.mkdir()
        (collision / 'keep.txt').write_text('do not discard')
        before = self.snapshot(original)
        config = {'runnerBundleIdentifier': 'test.release.runner', 'minimumOSVersion': '26.0'}
        with patch.object(build, 'ROOT', self.root), patch.object(build, 'run') as run, \
                patch.object(build, 'sign') as sign:
            with self.assertRaisesRegex(ValueError, 'destination already exists'):
                build.prepare_runner(config, '0.4.0', '4')
        self.assertEqual(self.snapshot(original), before)
        prepared = self.root / '.build/Packaging/WebDriverAgentRunner-Runner.app'
        self.assertEqual((prepared / 'Frameworks/WebDriverAgentRunner.framework/keep.txt').read_text(),
                         'do not discard')
        run.assert_not_called()
        sign.assert_not_called()


if __name__ == '__main__':
    unittest.main()
