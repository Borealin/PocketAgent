import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ish_runtime', ROOT / 'Scripts/ish_runtime.py')
ish_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ish_runtime)


class RootfsLayoutTests(unittest.TestCase):
    """verify_rootfs requires the root directory as the first archive entry:
    without it the iSH importer records the root without S_IFDIR and the
    kernel panics at boot (no working init)."""

    def problems(self, with_root):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'root.tar.gz'
            with tarfile.open(path, 'w:gz', format=tarfile.GNU_FORMAT) as archive:
                if with_root:
                    root = tarfile.TarInfo('./')
                    root.type = tarfile.DIRTYPE
                    root.mode = 0o755
                    archive.addfile(root)
                for name, data in [('etc/pocketagent-packages', b''), ('etc/passwd', b'')]:
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
            try:
                ish_runtime.verify_rootfs(path)
            except SystemExit as failure:
                return str(failure)
            return ''

    def test_missing_root_entry_is_rejected(self):
        self.assertIn('root directory', self.problems(with_root=False))

    def test_root_entry_satisfies_the_layout_check(self):
        # Other checks still fail on this synthetic archive; the root one does not.
        self.assertNotIn('root directory', self.problems(with_root=True))


if __name__ == '__main__':
    unittest.main()
