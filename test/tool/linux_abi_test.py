import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    'linux_abi', Path(__file__).resolve().parents[2] / 'tool/check_linux_abi.py',
)
ABI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ABI)


class LinuxAbiTest(unittest.TestCase):
    def test_numeric_versions_and_undefined_imports_only(self):
        symbols = '\n'.join([
            '0 FUNC GLOBAL DEFAULT UND old@GLIBC_2.9',
            '0 FUNC GLOBAL DEFAULT UND later@GLIBC_2.31',
            '0 FUNC GLOBAL DEFAULT 10 definition@GLIBC_2.39',
            '0 FUNC GLOBAL DEFAULT UND cpp@GLIBCXX_3.4.28',
        ])
        self.assertEqual(
            ABI.version_requirements(symbols),
            {'GLIBC': (2, 31), 'GLIBCXX': (3, 4, 28)},
        )

    def test_newer_libc_and_glib_are_detected(self):
        symbols = '0 FUNC GLOBAL DEFAULT UND call@GLIBC_2.39'
        self.assertGreater(ABI.version_requirements(symbols)['GLIBC'], ABI.LIMITS['GLIBC'])
        self.assertIsNotNone(ABI.FORBIDDEN_GLIB.search('UND g_once_init_enter_pointer'))
        self.assertIsNone(ABI.FORBIDDEN_GLIB.search('UND g_once_init_enter'))


if __name__ == '__main__':
    unittest.main()
