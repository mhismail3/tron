import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { lstat, mkdir, realpath, rm } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { GatewayError } from "../errors.js";

const GIT = process.env.TRON_GIT_PATH ?? "/usr/bin/git";
const COMMAND_TIMEOUT_MS = 10_000;
const MAX_BRANCH_BYTES = 255;

export type SessionSourceControlMode =
  | "existingCheckout"
  | "newBranchWorktree"
  | "existingBranchWorktree";

export type SessionSourceControlRequest =
  | { mode: "existingCheckout" }
  | { mode: "newBranchWorktree"; branch: string; base?: string }
  | { mode: "existingBranchWorktree"; branch: string };

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

async function ensureDirectoryNoSymlink(path: string): Promise<void> {
  try {
    const metadata = await lstat(path);
    if (!metadata.isDirectory()) throw new GatewayError("conflict", "Managed Git worktree path is not a directory", false);
    return;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  await mkdir(path, { mode: 0o700 });
  const metadata = await lstat(path);
  if (!metadata.isDirectory()) throw new GatewayError("conflict", "Managed Git worktree path is not a directory", false);
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

function runGit(cwd: string, args: string[], timeout = COMMAND_TIMEOUT_MS): Promise<GitCommandResult> {
  return new Promise((resolve, reject) => {
    const maximumOutput = 256 * 1_024;
    let timedOut = false;
    let settled = false;
    let outputOverflow = false;
    let killTimer: NodeJS.Timeout | undefined;
    let deadlineTimer: NodeJS.Timeout | undefined;
    let hardDeadlineTimer: NodeJS.Timeout | undefined;
    const stdout: string[] = [];
    const stderr: string[] = [];
    const child = spawn(GIT, ["-C", cwd, ...args], { cwd, detached: true, windowsHide: true });
    const terminateGroup = (signal: NodeJS.Signals): void => {
      if (!child.pid) return;
      try { process.kill(-child.pid, signal); }
      catch { try { child.kill(signal); } catch { /* process already exited */ } }
    };
    const append = (target: string[], chunk: Buffer | string): void => {
      target.push(chunk.toString());
      if (Buffer.byteLength(target.join("")) > maximumOutput) {
        outputOverflow = true;
        terminateGroup("SIGTERM");
      }
    };
    const finish = (error?: Error | null, code?: number | null, signal?: NodeJS.Signals | null): void => {
      if (settled) return;
      settled = true;
      if (killTimer) clearTimeout(killTimer);
      if (deadlineTimer) clearTimeout(deadlineTimer);
      if (hardDeadlineTimer) clearTimeout(hardDeadlineTimer);
      if (!error && !timedOut && !outputOverflow && code === 0) {
        resolve({ stdout: stdout.join(""), stderr: stderr.join("") });
        return;
      }
      const detail = error?.message ?? (timedOut ? "timed out" : outputOverflow ? "output exceeded bounds" : `exited with ${signal ?? code}`);
      reject(new GatewayError("conflict", `Git operation failed: ${detail}`, true,
        timedOut ? { outcomeUnknown: true } : { exitCode: code ?? undefined }));
    };
    child.stdout.on("data", (chunk: Buffer | string) => append(stdout, chunk));
    child.stderr.on("data", (chunk: Buffer | string) => append(stderr, chunk));
    child.on("error", (error) => finish(error));
    child.on("close", (code, signal) => finish(null, code, signal));
    deadlineTimer = setTimeout(() => {
      timedOut = true;
      terminateGroup("SIGTERM");
      killTimer = setTimeout(() => terminateGroup("SIGKILL"), 1_000);
    }, timeout);
    // A descendant that keeps stdio open must not make a timed-out command
    // retain the Gateway forever. The group remains killed and the result is
    // explicitly uncertain if this hard bound is reached.
    hardDeadlineTimer = setTimeout(() => {
      if (settled) return;
      settled = true;
      if (killTimer) clearTimeout(killTimer);
      reject(new GatewayError("conflict", "Git operation did not settle after its bounded termination window", true,
        { outcomeUnknown: true }));
    }, timeout + 2_000);
  });
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
    const base = request.mode === "newBranchWorktree" ? cleanField(request.base) : undefined;
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
    const createdBranch = request.mode === "newBranchWorktree";
    const baseRef = base ?? "HEAD";
    const baseCommit = createdBranch
      ? (await runGit(repositoryRoot, ["rev-parse", `${baseRef}^{commit}`])).stdout.trim()
      : undefined;
    let branchExisted = false;
    if (createdBranch) {
      try {
        await runGit(repositoryRoot, ["show-ref", "--verify", "--quiet", `refs/heads/${branch}`]);
        branchExisted = true;
      } catch (error) {
        // Exit 1 is show-ref's definitive "not present" result. Any other
        // failure is an uncertain lookup and must never authorize destructive
        // cleanup of a same-named branch owned by another operation.
        branchExisted = !(error instanceof GatewayError && (error.details as { exitCode?: number } | undefined)?.exitCode === 1);
      }
    }
    try {
      if (createdBranch) {
        await runGit(repositoryRoot, ["worktree", "add", "-b", branch, target, baseRef]);
      } else {
        await runGit(repositoryRoot, ["worktree", "add", target, branch]);
      }
      const canonical = await realpath(target);
      return {
        cwd: canonical,
        cleanup: async () => {
          try {
            await this.removeWorktree(repositoryRoot, canonical);
          } finally {
            if (createdBranch && !branchExisted && baseCommit) {
              await this.removeCreatedBranch(repositoryRoot, branch, baseCommit);
            }
          }
        },
      };
    } catch (error) {
      // Reconcile the exact administrative records after a failed or uncertain
      // add before attempting the compare-and-delete branch cleanup.
      await rm(target, { recursive: true, force: true }).catch(() => {});
      await runGit(repositoryRoot, ["worktree", "prune"]).catch(() => {});
      if (createdBranch && !branchExisted && baseCommit) {
        await this.removeCreatedBranch(repositoryRoot, branch, baseCommit).catch(() => {});
      }
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
    const managedRoot = resolve(this.worktreeRoot);
    const folder = join(managedRoot, repositoryName);
    // Never use recursive mkdir here: it follows a pre-existing symlink in an
    // intermediate component. Both components are checked before Git sees the
    // target, then realpath containment proves the resolved parent remains owned.
    await ensureDirectoryNoSymlink(dirname(managedRoot));
    await ensureDirectoryNoSymlink(managedRoot);
    const canonicalRoot = await realpath(managedRoot);
    await ensureDirectoryNoSymlink(folder);
    const canonicalFolder = await realpath(folder);
    if (!inside(canonicalRoot, canonicalFolder)) {
      throw new GatewayError("internal", "Git worktree path escaped its managed root", false);
    }
    const target = join(folder, `${branchName}-${randomUUID().slice(0, 8)}`);
    if (!inside(canonicalRoot, canonicalFolder) || !inside(resolve(managedRoot), resolve(target))) {
      throw new GatewayError("internal", "Git worktree path escaped its managed root", false);
    }
    try {
      const metadata = await lstat(target);
      // A pre-existing target, especially a symlink, must never be handed to
      // worktree add or removed by the failure cleanup path.
      if (metadata) throw new GatewayError("conflict", "Managed Git worktree target already exists", false);
    } catch (error) {
      if (error instanceof GatewayError) throw error;
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    const canonicalParent = await realpath(dirname(target));
    if (!inside(canonicalRoot, canonicalParent)) {
      throw new GatewayError("internal", "Git worktree path escaped its managed root", false);
    }
    return target;
  }

  private async removeCreatedBranch(repositoryRoot: string, branch: string, expectedCommit: string): Promise<void> {
    // update-ref's expected-old argument makes this a compare-and-delete: a
    // session commit or another actor moving the branch leaves it intact.
    await runGit(repositoryRoot, ["update-ref", "-d", `refs/heads/${branch}`, expectedCommit]);
  }

  private async removeWorktree(repositoryRoot: string, target: string): Promise<void> {
    await runGit(repositoryRoot, ["worktree", "remove", "--force", target]).catch(async (error) => {
      await rm(target, { recursive: true, force: true });
      await runGit(repositoryRoot, ["worktree", "prune"]);
      throw error;
    });
  }
}
