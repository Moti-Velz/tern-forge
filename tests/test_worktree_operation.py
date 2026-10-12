"""Real Git/Worktrunk lifecycle tests; all repositories and approvals are temporary."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "worktree-operation.sh"
WT = shutil.which("wt")


class OperationFixture:
    """A temporary repository and the helper invoked for one backend."""

    BACKEND = ""
    TOOL = ""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-operation-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo space é's"
        self.repo.mkdir()
        home = self.root / "home"
        config = home / ".config" / "worktrunk"
        config.mkdir(parents=True)
        self.approvals = config / "approvals.toml"
        self.env = {
            **{key: value for key, value in os.environ.items() if not key.startswith(("GIT_", "WORKTRUNK_"))},
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "WORKTRUNK_CONFIG_PATH": str(config / "config.toml"),
            "WORKTRUNK_SYSTEM_CONFIG_PATH": str(config / "system.toml"),
            "WORKTRUNK_PROJECT_CONFIG_PATH": ".config/wt.toml",
            "WORKTRUNK_WORKTREE_PATH": str(self.root / "created-{{ branch | sanitize }}"),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Forge test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Forge test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
        self.git("init", "-b", "master")
        (self.repo / "tracked.txt").write_text("original\n")
        (self.repo / ".gitignore").write_text(".env\n")
        self.git("add", ".")
        self.git("commit", "-m", "base")

    def run_command(self, *args, check=True, cwd=None):
        result = subprocess.run(
            [str(arg) for arg in args], cwd=cwd or self.repo, env=self.env,
            input="", capture_output=True, text=True, timeout=30,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, *args, cwd=None):
        return self.run_command("git", *args, cwd=cwd).stdout.strip()

    def worktree(self, branch="feature/é'$literal;quote"):
        path = self.root / "linked é's $literal"
        self.git("worktree", "add", "-b", branch, str(path))
        return path, branch

    def argv(self, mode, target, option, hook=""):
        return [
            "/bin/bash", str(HELPER), mode, self.BACKEND, self.TOOL, str(self.repo),
            str(target), option, str(self.root / "completion.status"), hook,
        ]

    def operation(self, mode, target, option, hook=""):
        return self.run_command(*self.argv(mode, target, option, hook), check=False)


class RemovalSafety:
    """Guarantees every backend keeps: nothing unsaved or foreign is deleted."""

    def test_staged_changes_are_not_deleted(self):
        path, branch = self.worktree()
        (path / "tracked.txt").write_text("staged work\n")
        self.git("add", "tracked.txt", cwd=path)
        result = self.operation("remove", path, branch)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((path / "tracked.txt").read_text(), "staged work\n")

    def test_untracked_files_are_not_deleted(self):
        path, branch = self.worktree()
        (path / "untracked.txt").write_text("unsaved work\n")
        result = self.operation("remove", path, branch)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((path / "untracked.txt").read_text(), "unsaved work\n")

    def test_primary_checkout_is_not_deleted(self):
        result = self.operation("remove", self.repo, "master")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("branch", "--show-current"), "master")
        self.assertEqual((self.repo / "tracked.txt").read_text(), "original\n")

    def test_replaced_target_from_another_repository_is_not_deleted(self):
        foreign = self.root / "foreign"
        self.git("clone", "--no-hardlinks", str(self.repo), str(foreign))
        target = self.root / "foreign-linked"
        self.git("worktree", "add", "-b", "foreign-branch", str(target), cwd=foreign)
        result = self.operation("remove", target, "foreign-branch")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((target / "tracked.txt").read_text(), "original\n")
        self.assertEqual(self.git("branch", "--show-current", cwd=target), "foreign-branch")

    def test_branch_change_after_confirmation_is_not_deleted(self):
        path, branch = self.worktree()
        self.git("branch", "-m", "changed-after-confirmation", cwd=path)
        result = self.operation("remove", path, branch)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("branch", "--show-current", cwd=path), "changed-after-confirmation")

    def test_detached_worktree_can_be_removed_without_deleting_branches(self):
        path = self.root / "detached"
        self.git("worktree", "add", "--detach", str(path), "master")
        master = self.git("rev-parse", "master")
        result = self.operation("remove", path, "")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(path.exists())
        self.assertEqual(self.git("rev-parse", "master"), master)

    def test_removal_keeps_unmerged_branch_and_deletes_ignored_files(self):
        path, branch = self.worktree()
        (path / "tracked.txt").write_text("unmerged work\n")
        self.git("add", "tracked.txt", cwd=path)
        self.git("commit", "-m", "unmerged", cwd=path)
        commit = self.git("rev-parse", "HEAD", cwd=path)
        (path / ".env").write_text("ignored fixture\n")
        result = self.operation("remove", path, branch)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(path.exists())
        self.assertEqual(self.git("rev-parse", branch), commit)

    def test_creation_uses_selected_base_and_literal_branch(self):
        self.git("branch", "selected-base")
        (self.repo / "tracked.txt").write_text("newer master\n")
        self.git("commit", "-am", "advance master")
        branch = "feature/é'$literal;quote"
        result = self.operation("create", branch, "selected-base")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", branch), self.git("rev-parse", "selected-base"))
        self.assertNotEqual(self.git("rev-parse", branch), self.git("rev-parse", "master"))
        self.assertIn("branch refs/heads/" + branch, self.git("worktree", "list", "--porcelain"))

    def test_running_helper_publishes_its_pid_until_the_receipt_is_written(self):
        # Forge must not report failure while this PID is alive, even if
        # Tern stops reporting the operation's terminal.
        release = self.repo / ".git" / "release"
        hook = self.blocking_removal('while [ ! -e "$(git rev-parse --git-common-dir)/release" ]; do sleep 0.05; done')
        path, branch = self.worktree()
        receipt = self.root / "completion.status"
        pid_file = self.root / "completion.status.pid"
        helper = subprocess.Popen(
            self.argv("remove", path, branch, hook),
            cwd=self.repo, env=self.env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.addCleanup(lambda: helper.poll() is None and helper.kill())
        deadline = time.monotonic() + 15
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(pid_file.read_text().strip(), str(helper.pid))
        self.assertFalse(receipt.exists())
        release.touch()
        output, _ = helper.communicate(timeout=30)
        self.assertEqual(helper.returncode, 0, output)
        self.assertEqual(receipt.read_text(), "0\n")
        self.assertFalse(pid_file.exists())


@unittest.skipUnless(WT, "Worktrunk must be installed")
class WorktrunkOperationTests(OperationFixture, RemovalSafety, unittest.TestCase):
    BACKEND = "worktrunk"
    TOOL = WT or ""

    def hook(self, command):
        (self.repo / ".config").mkdir()
        (self.repo / ".config" / "wt.toml").write_text(
            "pre-remove = " + json.dumps(command) + "\n"
        )
        self.git("add", ".config/wt.toml")
        self.git("commit", "-m", "fixture removal hook")
        # Only these generated fixture commands are trusted; product commands
        # retain their interactive approval prompts.
        self.git("remote", "add", "origin", "https://github.com/forge-tests/fixture.git")
        self.approvals.write_text(
            '[projects."github.com/forge-tests/fixture"]\n'
            "approved-commands = [" + json.dumps(command) + "]\n"
        )

    def blocking_removal(self, command):
        self.hook(command)
        return ""

    def test_removal_runs_pre_remove_hook(self):
        self.hook('printf removed > "$(git rev-parse --git-common-dir)/removed-marker"')
        path, branch = self.worktree()
        result = self.operation("remove", path, branch)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.repo / ".git" / "removed-marker").read_text(), "removed")

    def test_failed_pre_remove_hook_preserves_worktree(self):
        self.hook("exit 23")
        path, branch = self.worktree()
        result = self.operation("remove", path, branch)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((path / "tracked.txt").read_text(), "original\n")
        self.assertEqual(self.git("branch", "--show-current", cwd=path), branch)


class GitOperationTests(OperationFixture, RemovalSafety, unittest.TestCase):
    BACKEND = "git"
    # orca.yaml's documented environment, captured by the hooks below.
    RECORD_ENV = 'printf "%s\\n%s\\n%s\\n%s\\n" "$ORCA_WORKTREE_PATH" "$ORCA_ROOT_PATH" "$ORCA_WORKSPACE_NAME" "$PWD" > '

    def blocking_removal(self, command):
        return command

    def test_creation_places_the_worktree_beside_the_checkout(self):
        result = self.operation("create", "feature/nested-name", "master")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        path = self.root / "repo space é's.feature-nested-name"
        self.assertEqual(self.git("branch", "--show-current", cwd=path), "feature/nested-name")

    def test_creation_refuses_an_existing_directory(self):
        occupied = self.root / "repo space é's.taken"
        occupied.mkdir()
        (occupied / "keep.txt").write_text("not ours\n")
        result = self.operation("create", "taken", "master")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((occupied / "keep.txt").read_text(), "not ours\n")
        self.assertNotIn("refs/heads/taken", self.git("for-each-ref", "refs/heads/"))

    def test_setup_script_runs_in_the_new_worktree_with_orca_environment(self):
        marker = self.root / "setup-env"
        result = self.operation("create", "with-setup", "master", self.RECORD_ENV + '"' + str(marker) + '"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        path = self.root / "repo space é's.with-setup"
        self.assertEqual(marker.read_text().splitlines(), [str(path), str(self.repo), path.name, str(path)])

    def test_failed_setup_script_is_reported_and_keeps_the_worktree(self):
        result = self.operation("create", "setup-fails", "master", "exit 7")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "completion.status").read_text(), str(result.returncode) + "\n")
        self.assertTrue((self.root / "repo space é's.setup-fails" / "tracked.txt").exists())

    def test_archive_script_runs_in_the_worktree_before_removal(self):
        path, branch = self.worktree()
        marker = self.root / "archive-env"
        result = self.operation("remove", path, branch, self.RECORD_ENV + '"' + str(marker) + '"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(path.exists())
        self.assertEqual(marker.read_text().splitlines(), [str(path), str(self.repo), path.name, str(path)])

    def test_failed_archive_script_preserves_worktree(self):
        path, branch = self.worktree()
        result = self.operation("remove", path, branch, "exit 9")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((path / "tracked.txt").read_text(), "original\n")
        self.assertEqual(self.git("branch", "--show-current", cwd=path), branch)


if __name__ == "__main__":
    unittest.main()
