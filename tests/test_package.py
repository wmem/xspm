"""用真实 Git 仓库验证工程分支、锁定版本和本地开发提交保护。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="xspm-package-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = dict(os.environ, XMAKE_ROOT="y", XMAKE_COLORTERM="n")
        for name in ("XMAKE_PROJECT_DIR", "XMAKE_RCFILES"):
            self.env.pop(name, None)
        self.remote = self.base / "remote"
        self.remote.mkdir()
        self.git(self.remote, "init", "-q", "-b", "main")
        self.git(self.remote, "config", "user.name", "xspm-test")
        self.git(self.remote, "config", "user.email", "xspm-test@example.invalid")
        (self.remote / "data.txt").write_text("first\n")
        self.first = self.commit(self.remote, "first")
        self.project = self.base / "project"
        self.project.mkdir()
        (self.project / "xmake.lua").write_text(f'includes("{ROOT}/xmake.lua")\n')
        self.repo = self.project / "deps/lib"
        self.manifest = {"version": 1, "package": "gd32-template",
                         "dependencies": {"lib": f"{self.remote}#main"}}
        self.write_manifest()

    def git(self, cwd, *args):
        return subprocess.check_output(["git", "-C", str(cwd), *args], text=True,
                                       stderr=subprocess.PIPE).strip()

    def commit(self, repo, message):
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-qm", message)
        return self.git(repo, "rev-parse", "HEAD")

    def write_manifest(self):
        (self.project / "xspm.json").write_text(json.dumps(self.manifest) + "\n")

    def run_xspm(self, *args, success=True):
        result = subprocess.run(["xmake", "xspm", *args], cwd=self.project,
                                env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def advance_remote(self):
        (self.remote / "data.txt").write_text("second\n")
        return self.commit(self.remote, "second")

    def local_commit(self):
        self.git(self.repo, "config", "user.name", "xspm-test")
        self.git(self.repo, "config", "user.email", "xspm-test@example.invalid")
        (self.repo / "local.txt").write_text("local work\n")
        return self.commit(self.repo, "local work")

    def assert_branch(self, repo=None, name="gd32-template"):
        self.assertEqual(self.git(repo or self.repo, "branch", "--show-current"), name)

    def test_first_install_repeat_and_locked_offline_sync(self):
        self.run_xspm("--lock")
        self.assert_branch()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), self.first)
        before = (self.project / "xspm-lock.json").read_bytes()
        self.remote.rename(self.base / "offline")
        self.run_xspm()
        self.assert_branch()
        self.assertEqual((self.project / "xspm-lock.json").read_bytes(), before)

    def test_remote_source_branch_is_independent(self):
        self.manifest["package"] = "work/project"
        self.write_manifest()
        self.run_xspm("--lock")
        self.assert_branch(name="work/project")
        lock = json.loads((self.project / "xspm-lock.json").read_text())
        self.assertEqual(lock["packages"]["deps/lib"]["ref"], "main")

    def test_without_package_keeps_detached_checkout(self):
        del self.manifest["package"]
        self.write_manifest()
        self.run_xspm("--lock")
        self.assertEqual(self.git(self.repo, "branch", "--show-current"), "")

    def test_existing_detached_checkout_gets_project_branch(self):
        del self.manifest["package"]
        self.write_manifest()
        self.run_xspm("--lock")
        self.manifest["package"] = "gd32-template"
        self.write_manifest()
        self.run_xspm()
        self.assert_branch()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), self.first)

    def test_nested_and_development_dependencies_use_root_package(self):
        nested = self.base / "nested"
        nested.mkdir()
        self.git(nested, "init", "-q", "-b", "main")
        self.git(nested, "config", "user.name", "xspm-test")
        self.git(nested, "config", "user.email", "xspm-test@example.invalid")
        (nested / "value").write_text("child\n")
        self.commit(nested, "child")
        (self.remote / "xspm.json").write_text(json.dumps({
            "package": "library-identity", "dependencies": {"child": f"{nested}#main"}}))
        self.commit(self.remote, "nested manifest")
        self.manifest["devDependencies"] = {"tool": f"{nested}#main"}
        self.write_manifest()
        self.run_xspm("--lock")
        for repo in (self.repo, self.repo / "deps/child", self.project / "deps/tool"):
            self.assert_branch(repo)
        self.run_xspm("--status")

    def test_update_advances_branch_and_explicit_version_can_roll_back(self):
        self.run_xspm("--lock")
        latest = self.advance_remote()
        self.run_xspm("--update", "lib")
        self.assert_branch()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), latest)
        self.manifest["dependencies"]["lib"] = f"{self.remote}#{self.first}"
        self.write_manifest()
        self.run_xspm("--update", "lib")
        self.assert_branch()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), self.first)

    def test_local_commits_block_sync_and_force_does_not_discard_work(self):
        self.run_xspm("--lock")
        local = self.local_commit()
        lock = (self.project / "xspm-lock.json").read_bytes()
        (self.repo / "pending.txt").write_text("uncommitted\n")
        text = self.run_xspm("--force", success=False)
        self.assertIn("local or divergent commits", text)
        self.assert_branch()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), local)
        self.assertTrue((self.repo / "local.txt").exists())
        self.assertTrue((self.repo / "pending.txt").exists())
        self.assertEqual((self.project / "xspm-lock.json").read_bytes(), lock)

    def test_other_current_branch_with_local_commits_is_preserved(self):
        self.run_xspm("--lock")
        self.git(self.repo, "checkout", "-qb", "other-work")
        local = self.local_commit()
        self.run_xspm(success=False)
        self.assert_branch(name="other-work")
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), local)

    def test_remote_update_does_not_replace_divergent_local_commits(self):
        self.run_xspm("--lock")
        local = self.local_commit()
        self.advance_remote()
        lock = (self.project / "xspm-lock.json").read_bytes()
        self.assertIn("local or divergent commits", self.run_xspm("--update", success=False))
        self.assert_branch()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), local)
        self.assertEqual((self.project / "xspm-lock.json").read_bytes(), lock)

    def test_inactive_project_branch_with_extra_commits_is_preserved(self):
        self.run_xspm("--lock")
        local = self.local_commit()
        self.git(self.repo, "checkout", "--detach", self.first)
        self.run_xspm(success=False)
        self.assertEqual(self.git(self.repo, "rev-parse", "gd32-template"), local)

    def test_pushed_local_commit_can_be_adopted_by_new_ref(self):
        self.run_xspm("--lock")
        local = self.local_commit()
        self.git(self.repo, "push", "origin", "gd32-template:published")
        self.manifest["dependencies"]["lib"] = f"{self.remote}#published"
        self.write_manifest()
        self.run_xspm("--update", "lib")
        self.assert_branch()
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), local)
        self.run_xspm("--status")

    def test_dirty_tree_requires_force_and_branch_is_kept(self):
        self.run_xspm("--lock")
        (self.repo / "pending.txt").write_text("dirty\n")
        self.run_xspm(success=False)
        self.assertTrue((self.repo / "pending.txt").exists())
        self.run_xspm("--force")
        self.assertFalse((self.repo / "pending.txt").exists())
        self.assert_branch()

    def test_branch_status_is_read_only_and_sync_repairs_it(self):
        self.run_xspm("--lock")
        self.git(self.repo, "checkout", "--detach", self.first)
        state = (self.project / ".xspm/state/packages.json").read_bytes()
        self.assertIn("branch-mismatch", self.run_xspm("--status", success=False))
        self.assertEqual(self.git(self.repo, "branch", "--show-current"), "")
        self.assertEqual((self.project / ".xspm/state/packages.json").read_bytes(), state)
        self.run_xspm()
        self.assert_branch()

    def test_changing_package_preserves_previous_branch(self):
        self.run_xspm("--lock")
        self.manifest["package"] = "new-project"
        self.write_manifest()
        self.run_xspm()
        self.assert_branch(name="new-project")
        self.assertEqual(self.git(self.repo, "rev-parse", "gd32-template"), self.first)

    def test_invalid_package_is_rejected_before_clone(self):
        for name in ("", "HEAD", "-option", "a..b", "a b", "@{-1}", 7, True):
            with self.subTest(name=name):
                self.manifest["package"] = name
                self.write_manifest()
                self.run_xspm(success=False)
                self.assertFalse(self.repo.exists())

    def test_new_clone_can_pin_old_commit_when_default_branch_matches_package(self):
        self.advance_remote()
        self.manifest["package"] = "main"
        self.manifest["dependencies"]["lib"] = f"{self.remote}#{self.first}"
        self.write_manifest()
        self.run_xspm("--lock")
        self.assert_branch(name="main")
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), self.first)


if __name__ == "__main__":
    unittest.main(verbosity=2)
