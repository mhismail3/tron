import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdir, realpath, rm } from "node:fs/promises";
import { promisify } from "node:util";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { GatewayError } from "../errors.js";

const execFileAsync = promisify(execFile);
const GIT = process.env.TRON_GIT_PATH ?? "/usr/bin/git";
const COMMAND_TIMEOUT_MS = 10_000;
const MAX_BRANCH_BYTES = 255;

export type SessionSourceControlMode =
  | "existingCheckout"
  | "newBranchWorktree"
  | "existingBranchWorktree";

export interface SessionSourceControlRequest {
  mode: SessionSourceControlMode;
  branch?: string;
  base?: string;
}

export interface PreparedSessionWorkspace {
  cwd: string;
  cleanup: () => Promise<void>;
}

interface GitCommandResult {
  stdout: string;
  stderr: string;
}

function inside(root: string, candidate: string): boolean {
  const delta = relative(root, candidate);
  return delta === "" || (!delta.startsWith(`..${sep}`) && delta !== ".." && !isAbsolute(delta));
}

function cleanField(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function validateBranch(value: string | undefined, field: string): string {
  const branch = cleanField(value);
  if (!branch || branch.startsWith("-") || Buffer.byteLength(branch) > MAX_BRANCH_BYTES || /\s/.test(branch)) {
    throw new GatewayError("invalid_request", `${field} must be a valid local Git branch name`);
  }
  return branch;
}

async function runGit(cwd: string, args: string[], timeout = COMMAND_TIMEOUT_MS): Promise<GitCommandResult> {
  try {
    return await execFileAsync(GIT, ["-C", cwd, ...args], {
      cwd,
      timeout,
      maxBuffer: 256 * 1_024,
      windowsHide: true,
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new GatewayError("conflict", `Git operation failed: ${detail}`, true);
  }
}

export class GitWorktreeService {
  private readonly worktreeRoot: string;

  constructor(tronHome: string) {
    this.worktreeRoot = join(resolve(tronHome), "gateway", "worktrees");
  }

  async prepare(
    cwd: string,
    request: SessionSourceControlRequest | undefined,
  ): Promise<PreparedSessionWorkspace> {
    if (!request || request.mode === "existingCheckout") {
      return { cwd, cleanup: async () => {} };
    }

    const repositoryRoot = await this.repositoryRoot(cwd);
    const branch = validateBranch(request.branch, "branch");
    await this.verifyBranchName(repositoryRoot, branch);
    const base = cleanField(request.base);
    if (request.mode === "newBranchWorktree" && base && (base.startsWith("-") || /\s/.test(base))) {
      throw new GatewayError("invalid_request", "base must be a valid local Git ref");
    }

    if (request.mode === "newBranchWorktree") {
      await this.requireCleanCheckoutForImplicitHead(cwd, base);
      if (base) await this.verifyCommit(repositoryRoot, base, "base");
    } else {
      await this.verifyLocalBranch(repositoryRoot, branch);
    }

    const target = await this.allocateTarget(repositoryRoot, branch);
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    try {
      if (request.mode === "newBranchWorktree") {
        await runGit(repositoryRoot, ["worktree", "add", "-b", branch, target, base ?? "HEAD"]);
      } else {
        await runGit(repositoryRoot, ["worktree", "add", target, branch]);
      }
      const canonical = await realpath(target);
      return {
        cwd: canonical,
        cleanup: async () => {
          await this.removeWorktree(repositoryRoot, canonical);
        },
      };
    } catch (error) {
      await rm(target, { recursive: true, force: true }).catch(() => {});
      throw error;
    }
  }

  private async repositoryRoot(cwd: string): Promise<string> {
    try {
      const result = await runGit(cwd, ["rev-parse", "--show-toplevel"]);
      const root = result.stdout.trim();
      if (!root) throw new Error("missing repository root");
      return await realpath(root);
    } catch {
      throw new GatewayError("invalid_request", "The selected workspace is not a Git repository");
    }
  }

  private async verifyBranchName(repositoryRoot: string, branch: string): Promise<void> {
    try {
      await runGit(repositoryRoot, ["check-ref-format", "--branch", branch]);
    } catch {
      throw new GatewayError("invalid_request", "branch must be a valid local Git branch name");
    }
  }

  private async requireCleanCheckoutForImplicitHead(cwd: string, base: string | undefined): Promise<void> {
    if (base) return;
    const result = await runGit(cwd, ["status", "--porcelain=v1", "--untracked-files=all"]);
    if (result.stdout.trim()) {
      throw new GatewayError(
        "conflict",
        "The selected checkout has uncommitted changes. Choose a committed base branch before creating a worktree.",
        false,
      );
    }
  }

  private async verifyCommit(repositoryRoot: string, ref: string, field: string): Promise<void> {
    try {
      await runGit(repositoryRoot, ["rev-parse", "--verify", `${ref}^{commit}`]);
    } catch {
      throw new GatewayError("invalid_request", `${field} does not resolve to a local Git commit`);
    }
  }

  private async verifyLocalBranch(repositoryRoot: string, branch: string): Promise<void> {
    try {
      await runGit(repositoryRoot, ["show-ref", "--verify", "--quiet", `refs/heads/${branch}`]);
    } catch {
      throw new GatewayError("invalid_request", `Local Git branch “${branch}” was not found`);
    }
  }

  private async allocateTarget(repositoryRoot: string, branch: string): Promise<string> {
    const repositoryName = basename(repositoryRoot).replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 80) || "repository";
    const branchName = branch.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, 100) || "worktree";
    const folder = join(this.worktreeRoot, repositoryName);
    const target = join(folder, `${branchName}-${randomUUID().slice(0, 8)}`);
    if (!inside(resolve(this.worktreeRoot), resolve(target))) {
      throw new GatewayError("internal", "Git worktree path escaped its managed root", false);
    }
    return target;
  }

  private async removeWorktree(repositoryRoot: string, target: string): Promise<void> {
    await runGit(repositoryRoot, ["worktree", "remove", "--force", target]).catch(async () => {
      await rm(target, { recursive: true, force: true });
      await runGit(repositoryRoot, ["worktree", "prune"]);
    });
  }
}
