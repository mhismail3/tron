#!/usr/bin/env python3
"""Real Git cleanup preserves local data and distinguishes ancestry from squash-equivalent content."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/work"))
import cleanup


class ClosedIssue:
    def run(self, *args):
        if args[:2] == ("issue", "view"):
            return '{"state":"CLOSED"}'
        if args[:2] == ("pr", "list"):
            return '[]'
        raise AssertionError(args)


def run():
    evidence = []
    with tempfile.TemporaryDirectory(prefix="tron-work-cleanup-") as temporary:
        root = Path(temporary)
        repo, remote, worktree = root / "repo", root / "remote.git", root / "tree"
        env = {**os.environ, "HOME": str(root), "TMPDIR": str(root), "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": "/dev/null"}
        def git(cwd, *args):
            return subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                                  capture_output=True, text=True).stdout.strip()
        git(root, "init", "--bare", str(remote))
        git(root, "clone", str(remote), str(repo))
        git(repo, "checkout", "-b", "main")
        git(repo, "config", "user.name", "Fixture")
        git(repo, "config", "user.email", "fixture@example.invalid")
        (repo / "tracked").write_text("base\n")
        git(repo, "add", "."); git(repo, "commit", "-m", "base")
        git(repo, "push", "origin", "main")
        branch = "feat/41-fixture"
        git(repo, "worktree", "add", "-b", branch, str(worktree))
        (worktree / "tracked").write_text("candidate\n")
        git(worktree, "commit", "-am", "candidate")
        git(worktree, "push", "origin", branch)
        git(worktree, "push", "origin", "HEAD:main")
        head = git(worktree, "rev-parse", "HEAD")
        tree = cleanup.Worktree(worktree, head, branch, None, False)
        settings = cleanup.Settings(repo, root, "origin", "main", [], [], repo)
        (worktree / "untracked").write_text("preserve")
        done, reasons = cleanup._blockers(ClosedIssue(), tree, settings)
        assert done is not None and any("untracked" in reason for reason in reasons), reasons
        assert (worktree / "untracked").read_text() == "preserve"
        (worktree / "untracked").unlink()
        done, reasons = cleanup._blockers(ClosedIssue(), tree, settings)
        assert done is not None and not reasons, reasons
        ok, detail = cleanup._remove(ClosedIssue(), tree, settings, done)
        assert ok and not worktree.exists(), detail
        assert git(repo, "ls-remote", "--heads", "origin", branch) == ""
        assert git(repo, "rev-parse", "origin/main") == head
        evidence.append({"case": "plain push, closed issue, dirty preservation, exact branch cleanup", "head": head})

        # A real integration merge contains the branch head even though main's
        # tip differs and no pull request from the task branch exists.
        git(repo, "merge", "--ff-only", "origin/main")
        integrated = root / "integrated"
        integration_branch = "feat/42-integrated"
        git(repo, "worktree", "add", "-b", integration_branch, str(integrated))
        (integrated / "tracked").write_text("integrated candidate\n")
        git(integrated, "commit", "-am", "integration candidate")
        git(integrated, "push", "origin", integration_branch)
        integrated_head = git(integrated, "rev-parse", "HEAD")
        git(repo, "merge", "--no-ff", integration_branch, "-m", "integration merge")
        git(repo, "push", "origin", "main")
        integration_head = git(repo, "rev-parse", "origin/main")
        assert integration_head != integrated_head
        tree = cleanup.Worktree(integrated, integrated_head, integration_branch, None, False)
        done, reasons = cleanup._blockers(ClosedIssue(), tree, settings)
        assert done is not None and not reasons, reasons
        ok, detail = cleanup._remove(ClosedIssue(), tree, settings, done)
        assert ok and not integrated.exists(), detail
        assert git(repo, "ls-remote", "--heads", "origin", integration_branch) == ""
        evidence.append({"case": "integration merge without task PR cleans exact ancestor", "head": integrated_head,
                         "main": integration_head})

        # Squashing can preserve every file without preserving the authored
        # checkpoint. Equal trees are not permission to erase that history.
        squashed = root / "squashed"
        squash_branch = "feat/43-squashed"
        git(repo, "worktree", "add", "-b", squash_branch, str(squashed))
        (squashed / "tracked").write_text("squashed candidate\n")
        git(squashed, "commit", "-am", "unique authored checkpoint")
        git(squashed, "push", "origin", squash_branch)
        squash_head = git(squashed, "rev-parse", "HEAD")
        git(repo, "merge", "--squash", squash_branch)
        git(repo, "commit", "-m", "squash integration")
        git(repo, "push", "origin", "main")
        assert git(squashed, "rev-parse", "HEAD^{tree}") == git(repo, "rev-parse", "origin/main^{tree}")
        ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", squash_head, "origin/main"],
                                  cwd=repo, env=env, capture_output=True)
        assert ancestor.returncode == 1, ancestor.stderr
        tree = cleanup.Worktree(squashed, squash_head, squash_branch, None, False)
        done, reasons = cleanup._blockers(ClosedIssue(), tree, settings)
        assert done is None and reasons, (done, reasons)
        assert squashed.is_dir() and git(squashed, "rev-parse", "HEAD") == squash_head
        assert git(repo, "rev-parse", squash_branch) == squash_head
        assert git(repo, "ls-remote", "--heads", "origin", squash_branch).split()[0] == squash_head
        evidence.append({"case": "content-identical squash keeps unique head, tree and local/remote refs",
                         "head": squash_head, "main": git(repo, "rev-parse", "origin/main")})
    artifact = ROOT / "test-results/work-cleanup.json"
    artifact.parent.mkdir(exist_ok=True)
    artifact.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Passed plain-git cleanup journey; evidence: {artifact}")


if __name__ == "__main__":
    run()
