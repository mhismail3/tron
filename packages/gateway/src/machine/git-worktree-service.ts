import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { lstat, mkdir, realpath } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { asUncertainOutcome, GatewayError, isUncertainOutcome } from "../errors.js";

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
    const stdout: Buffer[] = [], stderr: Buffer[] = [];
    let stdoutBytes = 0, stderrBytes = 0;
    let settled = false;
    let terminationReason: string | undefined;
    let killTimer: NodeJS.Timeout | undefined, retirementTimer: NodeJS.Timeout | undefined;
    const child = spawn(GIT, ["-C", cwd, ...args], { cwd, detached: true, windowsHide: true });
    const terminateGroup = (signal: NodeJS.Signals): void => {
      if (!child.pid) return;
      try { process.kill(-child.pid, signal); }
      catch { try { child.kill(signal); } catch { /* retained as uncertain below */ } }
    };
    const groupGone = (): boolean => {
      if (!child.pid) return true;
      try { process.kill(-child.pid, 0); return false; }
      catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
    };
    const finish = (error?: Error, code?: number | null, signal?: NodeJS.Signals | null, deadlineExpired = false): void => {
      if (settled) return;
      // A nonzero direct-child exit is no more proof of descendant retirement
      // than a successful one. Never permit destructive rollback on that basis.
      if (!deadlineExpired && !groupGone()) {
        requestTermination("process group outlived Git");
        return;
      }
      settled = true;
      clearTimeout(deadlineTimer);
      if (killTimer) clearTimeout(killTimer);
      if (retirementTimer) clearTimeout(retirementTimer);
      if (!error && !terminationReason && code === 0) {
        resolve({ stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString() });
      } else {
        reject(new GatewayError("conflict", `Git operation failed: ${terminationReason ?? error?.message ?? `exited with ${signal ?? code}`}`,
          terminationReason === undefined,
          terminationReason ? { outcomeUnknown: true } : { exitCode: code ?? undefined }));
      }
      // Late callbacks are observed but never accumulate more output or publish
      // a second result. Deadline expiry is uncertainty, not proof of group exit.
      if (deadlineExpired) { child.stdout.destroy(); child.stderr.destroy(); }
    };
    const requestTermination = (reason: string): void => {
      if (settled || terminationReason) return;
      terminationReason = reason;
      clearTimeout(deadlineTimer);
      terminateGroup("SIGTERM");
      killTimer = setTimeout(() => terminateGroup("SIGKILL"), 1_000);
      retirementTimer = setTimeout(() => {
        terminateGroup("SIGKILL");
        finish(undefined, null, "SIGKILL", true);
      }, 2_000);
    };
    const append = (target: Buffer[], chunk: Buffer | string, size: number): number => {
      if (settled || terminationReason) return size;
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const remaining = Math.max(0, maximumOutput - size);
      if (remaining > 0) target.push(bytes.subarray(0, remaining));
      if (bytes.length > remaining) requestTermination("output exceeded bounds");
      return size + Math.min(bytes.length, remaining);
    };
    const deadlineTimer = setTimeout(() => requestTermination("timed out"), timeout);
    child.stdout.on("data", (chunk: Buffer | string) => { stdoutBytes = append(stdout, chunk, stdoutBytes); });
    child.stderr.on("data", (chunk: Buffer | string) => { stderrBytes = append(stderr, chunk, stderrBytes); });
    child.on("error", error => finish(error));
    child.on("close", (code, signal) => finish(undefined, code, signal));
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
          let worktreeRemoved = false;
          if (createdBranch && baseCommit) {
            // The branch is deleted while its exact worktree association still
            // proves this operation owns it. A failed/uncertain add never gets
            // here and therefore never gets permission to delete a same-named
            // branch created by a concurrent Git actor.
            await this.assertOwnedWorktree(repositoryRoot, canonical, branch);
            try {
              await this.removeCreatedBranch(repositoryRoot, branch, baseCommit);
            } catch (error) {
              // A timed-out ref operation may still be running. Preserve the
              // exact worktree as well; no destructive cleanup may race it.
              if (isUncertainOutcome(error)) throw error;
              const current = await runGit(repositoryRoot, ["rev-parse", "--verify", `refs/heads/${branch}`])
                .catch(failure => { throw asUncertainOutcome(failure, "Git branch cleanup could not be reconciled"); });
              if (current.stdout.trim() === baseCommit) {
                throw asUncertainOutcome(error, "Git branch cleanup failed without a confirmed branch move");
              }
              // The worktree is still ours, so it is safe to release it even
              // when a session commit or external actor moved the branch. The
              // compare-and-delete has already preserved that branch.
              await this.removeWorktree(repositoryRoot, canonical);
              worktreeRemoved = true;
              // The failed compare-and-delete has not granted permission to
              // alter the surviving branch.
            }
          }
          if (!worktreeRemoved) await this.removeWorktree(repositoryRoot, canonical);
        },
      };
    } catch (error) {
      // An unsuccessful add has no proof that this operation created either
      // the branch or target. Preserve both as ambiguous residue rather than
      // racing a concurrent Git actor with destructive cleanup.
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

  private async assertOwnedWorktree(repositoryRoot: string, target: string, branch: string): Promise<void> {
    let listing: string;
    try {
      listing = (await runGit(repositoryRoot, ["worktree", "list", "--porcelain"])).stdout;
    } catch (error) {
      throw asUncertainOutcome(error, "Git worktree ownership could not be verified; preserve the worktree and branch");
    }
    const records = listing.split(/\n(?=worktree )/u);
    const record = records.find((candidate) => candidate.split("\n")[0] === `worktree ${target}`);
    if (!record || !record.split("\n").includes(`branch refs/heads/${branch}`)) {
      throw new GatewayError("conflict", "Git worktree ownership changed; preserve the branch and worktree for reconciliation", false,
        { outcomeUnknown: true });
    }
  }

  private async removeCreatedBranch(repositoryRoot: string, branch: string, expectedCommit: string): Promise<void> {
    // update-ref's expected-old argument makes this a compare-and-delete: a
    // session commit or another actor moving the branch leaves it intact.
    try {
      await runGit(repositoryRoot, ["update-ref", "-d", `refs/heads/${branch}`, expectedCommit]);
    } catch (error) {
      if (isUncertainOutcome(error)) {
        throw asUncertainOutcome(error, "Git branch cleanup did not settle; preserve the branch for reconciliation");
      }
      // update-ref's expected-old mismatch is a definitive no-effect result;
      // callers release their still-owned worktree while preserving the branch.
      throw error;
    }
  }

  private async removeWorktree(repositoryRoot: string, target: string): Promise<void> {
    try {
      await runGit(repositoryRoot, ["worktree", "remove", "--force", target]);
    } catch (error) {
      // The target is deliberately not rm'ed or pruned after an uncertain Git
      // command: another actor may have taken ownership while it was running.
      throw asUncertainOutcome(error, "Git worktree cleanup did not settle; preserve the worktree for reconciliation");
    }
  }
}
