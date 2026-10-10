import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ish_runtime', ROOT / 'Scripts/ish_runtime.py')
ish_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ish_runtime)
ARCH = ish_runtime.SOURCES / 'ish/deps/linux/arch/ish'


@unittest.skipUnless(sys.platform == 'darwin' and (ARCH / 'kernel/setup_user.c').is_file(),
                     'needs macOS and the patched sources (Scripts/ish_runtime.py fetch)')
class KernelUserTests(unittest.TestCase):
    """Patched setup_user.c (bounded startup wait) and syscalls_user.c (guest
    egress policy), compiled for the Mac with kernel_user_harness.c."""

    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'kernel-user-harness'
            subprocess.run(['xcrun', 'clang', '-O1', '-Wall', '-Werror=implicit-function-declaration',
                            '-I', ARCH / 'include', ROOT / 'Tests/RuntimeTests/kernel_user_harness.c',
                            ARCH / 'kernel/setup_user.c', ARCH / 'kernel/syscalls_user.c', '-o', binary],
                           check=True, env=dict(os.environ, SDKROOT=''))
            cls.result = json.loads(subprocess.check_output([str(binary)], text=True, timeout=60))
            cls.panic = json.loads(subprocess.check_output([str(binary), 'panic'], text=True, timeout=60))

    def test_startup_wait_is_bounded(self):
        r = self.result
        self.assertNotEqual(r['neverResult'], 0, r)
        self.assertGreaterEqual(r['neverSeconds'], 0.9, r)
        self.assertLess(r['neverSeconds'], 3, r)
        self.assertEqual(r['laterResult'], 0, r)
        self.assertLess(r['laterSeconds'], 2, r)
        self.assertEqual(r['againResult'], 0, r)

    def test_panic_ends_the_startup_wait(self):
        self.assertNotEqual(self.panic['panicResult'], 0, self.panic)
        self.assertLess(self.panic['panicSeconds'], 2, self.panic)

    def test_public_destinations_are_allowed(self):
        for key in ['publicHTTPS', 'publicDNS', 'connectedSocket', 'public8101', 'beforeList', 'afterClear']:
            self.assertEqual(self.result[key], 1, key)

    def test_protected_ports_and_local_ranges_are_refused(self):
        for key in ['public8100', 'public62078', 'listed', 'shortName', 'loopback', 'private10', 'private192',
                    'cgnat', 'linkLocal', 'multicast']:
            self.assertEqual(self.result[key], 0, key)


if __name__ == '__main__':
    unittest.main()
