"""Regression tests for CI tool version validation; no network needed."""
import io
import hashlib
from zipfile import ZipFile
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from ci_vcs import download_archive, download_svn_archive, extract_named_zip_member, valid_jj_version, valid_svn_version


class JjVersionTests(unittest.TestCase):
    def test_official_release_output(self):
        self.assertTrue(valid_jj_version("jj 0.46.0\n"))
        self.assertTrue(valid_jj_version("jj 0.46.0-" + "a" * 40))
        self.assertTrue(valid_jj_version("jj 0.46.0-" + "a" * 40 + "-" + "b" * 40))

    def test_reject_wrong_versions(self):
        for value in ("jj 0.46.1", "jj 0.46.01", "jj 0.46.0-dev", "git 0.46.0", "jj 0.46.0 garbage", ""):
            with self.subTest(value=value):
                self.assertFalse(valid_jj_version(value))


class JjDownloadTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.archive = Path(temp.name) / "jj.tar.gz"
        self.url = "https://example.invalid/jj.tar.gz"

    def http_error(self, code):
        return HTTPError(self.url, code, "test", None, None)

    @patch("ci_vcs.time.sleep")
    @patch("ci_vcs.urlopen")
    def test_transient_failure_then_success(self, urlopen, sleep):
        self.archive.write_bytes(b"stale data")
        urlopen.side_effect = [self.http_error(503), URLError("temporary"), io.BytesIO(b"verified later")]
        download_archive(self.url, self.archive)
        self.assertEqual(self.archive.read_bytes(), b"verified later")
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual([call.args for call in sleep.call_args_list], [(2,), (4,)])

    @patch("ci_vcs.time.sleep")
    @patch("ci_vcs.urlopen")
    def test_permanent_failure_is_not_retried(self, urlopen, sleep):
        urlopen.side_effect = self.http_error(404)
        with self.assertRaises(HTTPError):
            download_archive(self.url, self.archive)
        self.assertEqual(urlopen.call_count, 1)
        sleep.assert_not_called()
        self.assertFalse(self.archive.exists())

    @patch("ci_vcs.time.sleep")
    @patch("ci_vcs.urlopen")
    def test_retries_are_bounded(self, urlopen, sleep):
        urlopen.side_effect = self.http_error(503)
        with self.assertRaises(HTTPError):
            download_archive(self.url, self.archive)
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertFalse(self.archive.exists())

    @patch("ci_vcs.time.sleep")
    @patch("ci_vcs.urlopen")
    def test_partial_download_removed_before_retry(self, urlopen, sleep):
        class PartialResponse(io.BytesIO):
            def read(self, size=-1):
                if self.tell():
                    raise ConnectionResetError("interrupted")
                return super().read(3)

        def assert_removed(_):
            self.assertFalse(self.archive.exists())

        sleep.side_effect = assert_removed
        urlopen.side_effect = [PartialResponse(b"bad partial"), io.BytesIO(b"complete")]
        download_archive(self.url, self.archive)
        self.assertEqual(self.archive.read_bytes(), b"complete")
        self.assertEqual(urlopen.call_count, 2)


class SvnArchiveTests(unittest.TestCase):
    def test_exact_vendor_version(self):
        self.assertTrue(valid_svn_version('1.14.5-SlikSvn\n'))
        self.assertTrue(valid_svn_version('1.14.5'))
        for value in ('1.14.6-SlikSvn', '1.14.5-dev', '1.14.5-SlikSvn-other', '1.14.05'):
            self.assertFalse(valid_svn_version(value))

    def test_extracts_only_named_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "source.zip"
            with ZipFile(archive, "w") as z:
                z.writestr("tools/vendor.zip", b"expected")
                z.writestr("../outside.txt", b"not extracted")
            target = root / "vendor.zip"
            extract_named_zip_member(archive, "tools/vendor.zip", target)
            self.assertEqual(target.read_bytes(), b"expected")
            self.assertFalse((root.parent / "outside.txt").exists())
            with self.assertRaises(SystemExit):
                extract_named_zip_member(archive, "missing", root / "missing")

    def test_pinned_inner_digest_is_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = "vendor"

            def download(_, target):
                with ZipFile(target, "w") as z:
                    z.writestr("tools/vendor.zip", b"vendor bytes")
                    z.writestr("tools/chocolateyInstall.ps1", b"never execute")

            with patch("ci_vcs.download_archive", side_effect=download):
                with patch("ci_vcs.SVN_ARCHIVE_SHA256", hashlib.sha256(b"vendor bytes").hexdigest()):
                    self.assertEqual(download_svn_archive(root, name).read_bytes(), b"vendor bytes")
                (root / "vendor.zip").unlink()
                with patch("ci_vcs.SVN_ARCHIVE_SHA256", "0" * 64):
                    with self.assertRaises(SystemExit):
                        download_svn_archive(root, name)


if __name__ == "__main__":
    unittest.main()
