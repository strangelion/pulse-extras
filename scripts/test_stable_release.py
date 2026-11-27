import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import stable_release as stable


class StableReleaseTests(unittest.TestCase):
    def test_exact_run(self):
        sha = "a" * 40
        run = dict(workflow_id=7, event="workflow_dispatch", status="completed",
                   conclusion="success", head_branch="main", head_sha=sha,
                   head_repository={"full_name": "owner/repo"})
        workflow = {"id": 7, "path": ".github/workflows/release.yml"}
        stable.validate_run(run, workflow, "owner/repo", sha)
        for field, value in (("head_sha", "b" * 40), ("conclusion", "failure"),
                             ("event", "pull_request"), ("workflow_id", 8),
                             ("head_branch", "dev")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                stable.validate_run(dict(run, **{field: value}), workflow, "owner/repo", sha)

    def test_hashes(self):
        digest = "a" * 64
        self.assertEqual(stable.tested_hashes("vcs=" + digest), {"vcs": digest})
        for value in ("", "vcs=123", "unknown=" + digest,
                      f"vcs={digest},vcs={digest}"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                stable.tested_hashes(value)

    def test_exact_accepted_artifact(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "vcs").mkdir()
            sha, digest = "a" * 40, "b" * 64
            evidence = {"version": "1.0.1", "asset_sha256": digest}
            with patch.object(stable.common, "read_evidence", return_value=evidence), \
                    patch.object(stable.release, "verify_candidate"):
                items, receipts = stable.prepare(root, sha, "123", {"vcs": digest},
                                                 "1.0.61", "local acceptance record", "owner")
                self.assertEqual(items[0]["tag"], "vcs/v1.0.1")
                self.assertEqual(receipts["vcs"]["asset_sha256"], digest)
                with self.assertRaises(ValueError):
                    stable.prepare(root, sha, "123", {"vcs": "c" * 64},
                                   "1.0.61", "record", "owner")
                evidence["version"] = "1.0.1-rc.1"
                with self.assertRaises(ValueError):
                    stable.prepare(root, sha, "123", {"vcs": digest}, "1.0.61", "record", "owner")

    def test_preview_path_cannot_publish_stable_without_receipts(self):
        with self.assertRaises(ValueError):
            stable.release.publish([], "publish-stable", Path("."))


if __name__ == "__main__":
    unittest.main()
