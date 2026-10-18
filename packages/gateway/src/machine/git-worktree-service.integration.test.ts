import { execFile } from "node:child_process";
import { chmod, lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { promisify } from "node:util";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it, vi } from "vitest";
import { GitWorktreeService } from "./git-worktree-service.js";
import { waitFor } from "../../test-support/wait-for.js";

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
  it("creates and retires worktrees only in the selected repository despite inherited Git selectors", async () => {
    const selected = await repository();
    const foreign = await repository();
    const saved = { ...process.env };
    let prepared: Awaited<ReturnType<GitWorktreeService["prepare"]>> | undefined;
    try {
      await writeFile(join(foreign.root, "README.md"), "foreign\n");
      await git(foreign.root, "commit", "-qam", "foreign");
      await writeFile(join(selected.root, "README.md"), "selected\n");
      await git(selected.root, "commit", "-qam", "selected");
      const head = await git(selected.root, "rev-parse", "HEAD");
      const foreignRefs = await git(foreign.root, "show-ref");
      const foreignIndex = await readFile(join(foreign.root, ".git", "index"));
      const hooks = join(selected.tronHome, "hooks");
      const marker = join(selected.tronHome, "checkout-marker");
      const config = join(selected.tronHome, "global.gitconfig");
      await mkdir(hooks);
      await writeFile(join(hooks, "post-checkout"), `#!/bin/sh\nprintf 'checkout\\n' > ${JSON.stringify(marker)}\n`);
      await chmod(join(hooks, "post-checkout"), 0o755);
      await git(selected.root, "config", "--file", config, "core.hooksPath", hooks);
      try {
        process.env.GIT_DIR = join(foreign.root, ".git");
        process.env.GIT_WORK_TREE = foreign.root;
        process.env.GIT_COMMON_DIR = join(foreign.root, ".git");
        process.env.GIT_INDEX_FILE = join(foreign.root, ".git", "index");
        process.env.GIT_OBJECT_DIRECTORY = join(foreign.root, ".git", "objects");
        process.env.GIT_CONFIG_GLOBAL = config;
        prepared = await new GitWorktreeService(selected.tronHome).prepare(selected.root, {
          mode: "newBranchWorktree", branch: "feature/selected", base: "HEAD",
        });
      } finally {
        process.env = { ...saved };
      }
      expect(await git(prepared.cwd, "rev-parse", "HEAD")).toBe(head);
      expect(await readFile(join(prepared.cwd, "README.md"), "utf8")).toBe("selected\n");
      expect(await readFile(marker, "utf8")).toBe("checkout\n");
      expect(await git(selected.root, "branch", "--list", "feature/selected")).toContain("feature/selected");
      expect(await git(foreign.root, "show-ref")).toBe(foreignRefs);
      expect(await readFile(join(foreign.root, ".git", "index"))).toEqual(foreignIndex);
      // Retirement must use the same selected repository, not the process's
      // ambient repository restored by a surrounding Git hook.
      try {
        process.env.GIT_DIR = join(foreign.root, ".git");
        process.env.GIT_WORK_TREE = foreign.root;
        await prepared.cleanup();
      } finally {
        process.env = { ...saved };
      }
      await expect(lstat(prepared.cwd)).rejects.toMatchObject({ code: "ENOENT" });
      await expect(git(selected.root, "show-ref", "--verify", "--quiet", "refs/heads/feature/selected")).rejects.toThrow();
      expect(await git(foreign.root, "show-ref")).toBe(foreignRefs);
      prepared = undefined;
    } finally {
      process.env = { ...saved };
      try { await prepared?.cleanup(); } finally {
        for (const fixture of [selected, foreign]) {
          await rm(fixture.root, { recursive: true, force: true });
          await rm(fixture.tronHome, { recursive: true, force: true });
        }
      }
    }
  });

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
      await expect(lstat(prepared.cwd)).rejects.toMatchObject({ code: "ENOENT" });
      await expect(git(root, "show-ref", "--verify", "--quiet", "refs/heads/feature/tron-session")).rejects.toThrow();
    } finally {
      await rm(root, { recursive: true, force: true });
      await rm(tronHome, { recursive: true, force: true });
    }
  });

  it("refuses ambient foreign objects but honors repository-owned alternates", async () => {
    const selected = await repository();
    const foreign = await repository();
    const saved = { ...process.env };
    let prepared: Awaited<ReturnType<GitWorktreeService["prepare"]>> | undefined;
    try {
      await writeFile(join(foreign.root, "README.md"), "foreign-only\n");
      await git(foreign.root, "commit", "-qam", "foreign-only");
      const foreignHead = await git(foreign.root, "rev-parse", "HEAD");
      try {
        process.env.GIT_ALTERNATE_OBJECT_DIRECTORIES = join(foreign.root, ".git", "objects");
        await expect(new GitWorktreeService(selected.tronHome).prepare(selected.root, {
          mode: "newBranchWorktree", branch: "feature/foreign-base", base: foreignHead,
        }).then(result => { prepared = result; })).rejects.toMatchObject({ code: "invalid_request" });
      } finally {
        process.env = { ...saved };
      }
      expect(await git(selected.root, "branch", "--list", "feature/foreign-base")).toBe("");
      // Repository-owned object sharing is still Git's canonical configuration.
      await writeFile(join(selected.root, ".git", "objects", "info", "alternates"), `${join(foreign.root, ".git", "objects")}\n`);
      prepared = await new GitWorktreeService(selected.tronHome).prepare(selected.root, {
        mode: "newBranchWorktree", branch: "feature/foreign-base", base: foreignHead,
      });
      expect(await git(prepared.cwd, "rev-parse", "HEAD")).toBe(foreignHead);
      expect(await readFile(join(prepared.cwd, "README.md"), "utf8")).toBe("foreign-only\n");
    } finally {
      process.env = { ...saved };
      try { await prepared?.cleanup(); } finally {
        for (const fixture of [selected, foreign]) {
          await rm(fixture.root, { recursive: true, force: true });
          await rm(fixture.tronHome, { recursive: true, force: true });
        }
      }
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

  it("treats a nonzero Git exit with a live hook descendant as uncertain and terminates the owned group", async () => {
    const { root, tronHome } = await repository();
    const pidFile = join(tronHome, "hook-descendant.pid");
    let pid: number | undefined;
    try {
      const hook = join(root, ".git", "hooks", "post-checkout");
      await writeFile(hook, `#!/bin/sh\n/bin/sleep 60 >/dev/null 2>&1 &\nprintf '%s' "$!" > ${JSON.stringify(pidFile)}\nexit 1\n`);
      await chmod(hook, 0o755);
      const service = new GitWorktreeService(tronHome);
      await expect(service.prepare(root, { mode: "newBranchWorktree", branch: "feature/hook-failure" }))
        .rejects.toMatchObject({ details: { outcomeUnknown: true }, retryable: false });
      pid = Number(await readFile(pidFile, "utf8"));
      await waitFor(() => {
        try { process.kill(pid!, 0); return false; }
        catch { return true; }
      }, "the hook's background process to exit");
      // The command's uncertain outcome does not grant cleanup authority.
      expect(await git(root, "branch", "--list", "feature/hook-failure")).toContain("feature/hook-failure");
    } finally {
      if (pid === undefined) pid = Number(await readFile(pidFile, "utf8").catch(() => "NaN"));
      if (Number.isSafeInteger(pid) && pid! > 1) { try { process.kill(pid!, "SIGKILL"); } catch { /* exact test descendant already exited */ } }
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
      await expect(lstat(prepared.cwd)).rejects.toMatchObject({ code: "ENOENT" });
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
