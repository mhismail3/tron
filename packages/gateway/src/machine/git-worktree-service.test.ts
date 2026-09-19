import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { promisify } from "node:util";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { GitWorktreeService } from "./git-worktree-service.js";

const execFileAsync = promisify(execFile);

async function git(cwd: string, ...args: string[]): Promise<string> {
  const result = await execFileAsync("/usr/bin/git", ["-C", cwd, ...args]);
  return result.stdout.trim();
}

async function repository(): Promise<{ root: string; tronHome: string }> {
  const root = await mkdtemp(join(tmpdir(), "tron-worktree-repo-"));
  const tronHome = await mkdtemp(join(tmpdir(), "tron-worktree-home-"));
  await git(root, "init", "-q");
  await git(root, "config", "user.email", "tron-tests@example.invalid");
  await git(root, "config", "user.name", "Tron Tests");
  await writeFile(join(root, "README.md"), "base\n");
  await git(root, "add", "README.md");
  await git(root, "commit", "-qm", "base");
  return { root, tronHome };
}

describe("GitWorktreeService", () => {
  it("creates an isolated new branch worktree and cleans it up transactionally", async () => {
    const { root, tronHome } = await repository();
    try {
      const service = new GitWorktreeService(tronHome);
      const prepared = await service.prepare(root, {
        mode: "newBranchWorktree",
        branch: "feature/tron-session",
      });

      expect(await git(prepared.cwd, "branch", "--show-current")).toBe("feature/tron-session");
      expect(await readFile(join(prepared.cwd, "README.md"), "utf8")).toBe("base\n");
      await prepared.cleanup();
      await expect(readFile(prepared.cwd, "README.md")).rejects.toThrow();
      await expect(git(root, "show-ref", "--verify", "--quiet", "refs/heads/feature/tron-session")).rejects.toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
    }
  });

  it("rejects an implicit-head worktree when the selected checkout is dirty", async () => {
    const { root, tronHome } = await repository();
    try {
      await writeFile(join(root, "dirty.txt"), "not committed\n");
      const service = new GitWorktreeService(tronHome);
      await expect(service.prepare(root, {
        mode: "newBranchWorktree",
        branch: "feature/dirty",
      })).rejects.toThrow("uncommitted changes");
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
    }
  });

  it("rejects a pre-existing managed repository symlink before invoking Git", async () => {
    const { root, tronHome } = await repository();
    const outside = await mkdtemp(join(tmpdir(), "tron-worktree-escape-"));
    try {
      const managed = join(tronHome, "gateway", "worktrees");
      await mkdir(managed, { recursive: true });
      await symlink(outside, join(managed, basename(root)));
      const service = new GitWorktreeService(tronHome);
      await expect(service.prepare(root, {
        mode: "newBranchWorktree",
        branch: "feature/escape",
      })).rejects.toThrow("Managed Git worktree path is not a directory");
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
      await rm(outside, { recursive: true, force: true });
    }
  });

  it("never deletes a pre-existing branch when new worktree creation is rejected", async () => {
    const { root, tronHome } = await repository();
    try {
      await git(root, "branch", "feature/existing");
      const service = new GitWorktreeService(tronHome);
      await expect(service.prepare(root, { mode: "newBranchWorktree", branch: "feature/existing" })).rejects.toThrow();
      expect(await git(root, "branch", "--list", "feature/existing")).toContain("feature/existing");
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
    }
  });

  it("preserves the winner branch when concurrent new-branch requests race", async () => {
    const { root, tronHome } = await repository();
    try {
      const service = new GitWorktreeService(tronHome);
      const results = await Promise.allSettled(Array.from({ length: 8 }, () => service.prepare(root, {
        mode: "newBranchWorktree",
        branch: "feature/concurrent",
      })));
      const winners = results.filter((result): result is PromiseFulfilledResult<Awaited<ReturnType<GitWorktreeService["prepare"]>>> => result.status === "fulfilled");
      const losers = results.filter((result) => result.status === "rejected");
      expect(winners).toHaveLength(1);
      expect(losers).toHaveLength(7);
      // The losing add has no proof that it created the branch and must not
      // delete the successful request's branch during its failure cleanup.
      expect(await git(root, "show-ref", "--verify", "--quiet", "refs/heads/feature/concurrent")).toBe("");
      await winners[0].value.cleanup();
      await expect(git(root, "show-ref", "--verify", "--quiet", "refs/heads/feature/concurrent")).rejects.toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
    }
  });

  it("preserves a branch that changed while its owned worktree is active", async () => {
    const { root, tronHome } = await repository();
    try {
      const service = new GitWorktreeService(tronHome);
      const prepared = await service.prepare(root, {
        mode: "newBranchWorktree",
        branch: "feature/changed",
      });
      await writeFile(join(prepared.cwd, "changed.txt"), "changed\n");
      await git(prepared.cwd, "add", "changed.txt");
      await git(prepared.cwd, "commit", "-qm", "changed");
      await prepared.cleanup();
      expect(await git(root, "branch", "--list", "feature/changed")).toContain("feature/changed");
      await expect(readFile(prepared.cwd, "README.md")).rejects.toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
    }
  });

  it("creates a worktree from an existing local branch without changing the source checkout", async () => {
    const { root, tronHome } = await repository();
    try {
      await git(root, "branch", "release");
      const sourceBranch = await git(root, "branch", "--show-current");
      const service = new GitWorktreeService(tronHome);
      const prepared = await service.prepare(root, {
        mode: "existingBranchWorktree",
        branch: "release",
      });
      try {
        expect(await git(root, "branch", "--show-current")).toBe(sourceBranch);
        expect(await git(prepared.cwd, "branch", "--show-current")).toBe("release");
      } finally {
        await prepared.cleanup();
      }
      expect(await git(root, "branch", "--list", "release")).toContain("release");
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
    }
  });
});
