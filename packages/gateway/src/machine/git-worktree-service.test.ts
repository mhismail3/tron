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
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
    }
  });
});
