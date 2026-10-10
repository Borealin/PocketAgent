import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ish_runtime', ROOT / 'Scripts/ish_runtime.py')
ish_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ish_runtime)
HOSTFS = ish_runtime.SOURCES / 'ish/deps/linux/fs/hostfs/hostfs_user.c'


@unittest.skipUnless(sys.platform == 'darwin' and HOSTFS.is_file(),
                     'needs macOS and the patched sources (Scripts/ish_runtime.py fetch)')
class HostfsConfinementTests(unittest.TestCase):
    """The patched hostfs backend, compiled for the Mac, against a parent
    directory that another thread keeps replacing with a link outside the root."""

    def test_operations_stay_below_the_mount_root(self):
        result = ish_runtime.check_hostfs(iterations=20000)
        self.assertEqual(result['failures'], 0, result)
        self.assertEqual(result['outsideReads'], 0, result)
        self.assertEqual(result['outsideChanged'], 0, result)
        # Un-raced controls are exact: 50 passes with the parent in place
        # (one read, seven writes each) and 50 with it replaced by a link to
        # the outside directory (all nine operations refused with ELOOP).
        self.assertEqual(result['control'], [50, 350, 0], result)
        self.assertEqual(result['linked'], [0, 0, 450], result)
        # The race ran until it had both succeeded and hit the link; how often
        # depends on scheduling, so only presence is asserted.
        self.assertGreaterEqual(result['iterations'], 20000, result)
        self.assertGreater(result['reads'], 0, result)
        self.assertGreater(result['writes'], 0, result)
        self.assertGreater(result['looped'], 0, result)


if __name__ == '__main__':
    unittest.main()
