"""The download helper must fail closed without altering user files."""
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'Scripts/download_pairing_tool.command'


class PairingDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def run_helper(self, *arguments):
        return subprocess.run(['bash', str(SCRIPT), *map(str, arguments)],
                              capture_output=True, text=True, timeout=10)

    def test_help_does_not_start_download(self):
        result = self.run_helper('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--download-only', result.stdout)
        self.assertNotIn('正在下载', result.stdout)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_bad_digest_rejects_file_without_changing_or_opening_it(self):
        file = self.root / 'unexpected image.dmg'
        original = b'not the official disk image'
        file.write_bytes(original)
        result = self.run_helper('--verify', file)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SHA-256', result.stderr)
        self.assertNotIn('校验通过', result.stdout)
        self.assertEqual(file.read_bytes(), original)
        self.assertEqual(list(self.root.iterdir()), [file])

    def test_symlink_is_rejected_without_reading_or_modifying_target(self):
        target = self.root / 'keep.txt'
        target.write_text('user data')
        link = self.root / 'image.dmg'
        link.symlink_to(target)
        result = self.run_helper('--verify', link)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('普通 DMG 文件', result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_text(), 'user data')

    def test_missing_file_and_directory_are_rejected(self):
        for file in [self.root / 'missing.dmg', self.root]:
            with self.subTest(file=file):
                result = self.run_helper('--verify', file)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('正在下载', result.stdout)
                self.assertIn('普通 DMG 文件', result.stderr)

    def test_wrong_arguments_do_not_create_files_or_start_download(self):
        for arguments in [('--verify',), ('--download-only', 'extra'),
                          ('--help', 'extra'), ('--unknown',)]:
            with self.subTest(arguments=arguments):
                result = self.run_helper(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(self.root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
