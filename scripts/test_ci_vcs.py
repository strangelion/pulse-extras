"""Regression tests for CI tool version validation; no network needed."""
import unittest

from ci_vcs import valid_jj_version


class JjVersionTests(unittest.TestCase):
    def test_official_release_output(self):
        self.assertTrue(valid_jj_version("jj 0.46.0\n"))
        self.assertTrue(valid_jj_version("jj 0.46.0-" + "a" * 40))
        self.assertTrue(valid_jj_version("jj 0.46.0-" + "a" * 40 + "-" + "b" * 40))

    def test_reject_wrong_versions(self):
        for value in ("jj 0.46.1", "jj 0.46.01", "jj 0.46.0-dev", "git 0.46.0", "jj 0.46.0 garbage", ""):
            with self.subTest(value=value):
                self.assertFalse(valid_jj_version(value))


if __name__ == "__main__":
    unittest.main()
