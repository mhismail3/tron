import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { lstat, mkdir, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { asUncertainOutcome, GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import type { TrustService } from "../../kernel/resources/trust-service.js";
import type { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import type { Actor } from "../../kernel/settings/settings-record.js";
import type { ChangeResult, ConfirmChange } from "../../kernel/settings/tool-contract.js";
import type { ChangeReview } from "../../protocol/types.js";
import { changeReview } from "../../kernel/settings/settings-types.js";

const exec = promisify(execFile);
const PROJECT_ACTION = "project.lifecycle";
interface Action { operation: "create"; name: string; identity: string }
export interface ProjectRequest { name: string; reason: string }

export interface ProjectOccupancy { assertIdle(path: string): void }
export interface ProjectRuntimePort {
  occupancy(signal?: AbortSignal): Promise<ProjectOccupancy>;
  reload(path: string, trusted: boolean): Promise<void>;
  release(path: string): Promise<void>;
  abort(path: string): Promise<void>;
}

export class ProjectLifecycle {
  private readonly mutex = new AsyncMutex();
  private changes: SettingsChangePath | undefined;
  readonly workspace: string;
  constructor(private readonly trust: () => TrustService, private readonly runtimes: ProjectRuntimePort,
    options: { workspace?: string } = {}) {
    this.workspace = options.workspace ?? join(homedir(), "Workspace");
  }

  register(changes: SettingsChangePath): void {
    if (this.changes === changes) return;
    if (this.changes) throw new Error("Project lifecycle already has a settings owner");
    this.changes = changes;
  }

  async request(input: ProjectRequest, options: { confirm?: ConfirmChange } = {}): Promise<ChangeResult> {
    const changes = this.changes;
    if (!changes) throw new GatewayError("busy", "Project lifecycle settings are not available");
    this.name(input.name);
    if (!input.reason?.trim() || input.reason.length > 2000) throw new GatewayError("invalid_request", "A reason of 1 to 2000 characters is required");
    const action: Action = { operation: "create", name: input.name, identity: await this.directory(this.workspace) };
    const review = await this.mutex.run(() => this.review(action, input.reason));
    if (!options.confirm) return { status: "review", review, changes: [] };
    return await options.confirm(review, accepted => this.execute(action, review.digest,
      { kind: "ui", id: accepted.deviceId }, accepted.commandId, input.reason)) ?? { status: "declined", changes: [] };
  }

  private async review(action: Action, reason: string): Promise<ChangeReview> {
    const preview = await this.plan(action);
    return changeReview(action, { ...preview, reason, requiresTap: true });
  }

  private execute(action: Action, digest: string, actor: Actor, commandId: string, reason: string): Promise<ChangeResult> {
    if (actor.kind !== "ui") throw new GatewayError("invalid_request", "Project effects require the paired native tap");
    const changes = this.changes!;
    return changes.withTarget({ kind: "project", cwd: join(this.workspace, action.name) }, () => this.mutex.run(async () => {
      const review = await this.review(action, reason);
      if (review.digest !== digest) throw new GatewayError("conflict", "Project changed since review; nothing was applied");
      await changes.record.recover();
      const changeId = randomUUID();
      const entry = { commandId, actor, target: { kind: "project" as const, cwd: join(this.workspace, action.name) },
        layer: "global" as const, key: PROJECT_ACTION, op: "set" as const, after: review, reason, action: true as const };
      await changes.record.append([{ ...entry, changeId, at: new Date().toISOString(), status: "started" }]);
      let result: { summary: string };
      try { result = await this.apply(action); }
      catch (error) {
        await changes.record.append([{ ...entry, changeId: randomUUID(), refersTo: changeId, at: new Date().toISOString(),
          status: "failed", failure: "Project effect did not complete cleanly; inspect canonical filesystem, Git and trust state before another action" }])
          .catch(publication => { throw asUncertainOutcome(publication, "Project effect failed and its audit could not be published; inspect before retrying"); });
        throw asUncertainOutcome(error, "Project effect may have occurred; inspect before retrying");
      }
      const appliedId = randomUUID();
      await changes.record.append([{ ...entry, changeId: appliedId, refersTo: changeId, at: new Date().toISOString(), status: "applied" }])
        .catch(error => { throw asUncertainOutcome(error, "Project applied but history publication failed"); });
      return { status: "applied", summary: result.summary, review, changes: [{
        changeId: appliedId, key: PROJECT_ACTION, layer: "global", status: "applied", undoable: false, result,
      }] };
    }));
  }

  private name(value: unknown): string {
    if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value)) {
      throw new GatewayError("invalid_request", "Project names must be 1 to 64 ASCII letters, digits, underscores or hyphens, starting with a letter or digit");
    }
    return value;
  }
  private async root(): Promise<void> {
    await this.directory(this.workspace);
    if (await realpath(this.workspace) !== this.workspace) throw new GatewayError("invalid_request", "Workspace must be a canonical directory, not a symlink");
  }
  private async directory(path: string): Promise<string> {
    const info = await lstat(path).catch((error: NodeJS.ErrnoException) => {
      throw new GatewayError(error.code === "ENOENT" ? "not_found" : "invalid_request", error.code === "ENOENT" ? "Project directory does not exist" : "Project directory cannot be inspected");
    });
    if (!info.isDirectory() || info.isSymbolicLink()) throw new GatewayError("invalid_request", "Project paths must be real directories, not symlinks");
    return `${info.dev}:${info.ino}`;
  }
  private async same(path: string, identity: string): Promise<void> {
    await this.root();
    if (await this.directory(path) !== identity || await realpath(path) !== path) throw new GatewayError("conflict", "Project path identity changed; nothing further will be applied");
  }
  private async absent(path: string): Promise<void> {
    try { await lstat(path); } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
    throw new GatewayError("conflict", "Destination already exists; project lifecycle never overwrites a path");
  }
  private async command(executable: string, args: string[], cwd: string, signal?: AbortSignal): Promise<string> {
    const env: NodeJS.ProcessEnv = { ...process.env, GIT_TERMINAL_PROMPT: "0" };
    for (const key of Object.keys(env)) if (key.startsWith("GIT_") && key !== "GIT_TERMINAL_PROMPT") delete env[key];
    try { return (await exec(executable, args, { cwd, env, timeout: 60_000, maxBuffer: 1024 * 1024, ...(signal ? { signal } : {}) })).stdout.trim(); }
    catch { signal?.throwIfAborted(); throw new GatewayError("conflict", "Git command did not complete; inspect project state before retrying"); }
  }
  private git(path: string, args: string[], signal?: AbortSignal): Promise<string> {
    return this.command("git", ["--no-pager", "-c", "core.hooksPath=/dev/null", ...args], path, signal);
  }
  private async inspect(action: Action, signal?: AbortSignal, shared?: ProjectOccupancy) {
    signal?.throwIfAborted();
    const path = join(this.workspace, action.name);
    await this.same(path, action.identity);
    const gitIdentity = await this.directory(join(path, ".git"));
    const root = await this.git(path, ["rev-parse", "--show-toplevel"], signal);
    if (root !== path) throw new GatewayError("invalid_request", "Lifecycle requires a standalone project repository");
    const worktrees = await this.git(path, ["worktree", "list", "--porcelain"], signal);
    if (worktrees.split("\n").filter(line => line.startsWith("worktree ")).length !== 1) throw new GatewayError("busy", "Project has linked worktrees; release their owners before changing its lifecycle");
    const occupancy = shared ?? await this.runtimes.occupancy(signal);
    occupancy.assertIdle(path);
    const trust = await this.trust().inspect(path);
    if (trust.projectDir !== path) throw new GatewayError("invalid_request", "Project root changed");
    const state = createHash("sha256").update(JSON.stringify({ gitIdentity, worktrees, saved: trust.savedDecision, effective: trust.effectiveDecision })).digest("hex");
    await this.same(path, action.identity);
    return { path, trust, state, occupancy };
  }
  private async plan(action: Action): Promise<Omit<ChangeReview, "digest" | "requiresTap">> {
    await this.root();
    if (await this.directory(this.workspace) !== action.identity) throw new GatewayError("conflict", "Workspace identity changed");
    const path = join(this.workspace, action.name);
    await this.absent(path);
    return { title: "Create and trust project " + action.name, items: [
      { label: "Project", before: "Absent", after: path, exact: action.identity },
      { label: "Repository", before: "Absent", after: "Git repository on main" },
      { label: "Authority", before: "None", after: "Trusted executable project resources", detail: "Trust is not a sandbox; code runs with your Mac user's authority." },
    ] };
  }
  private async setTrust(path: string, value: boolean): Promise<void> {
    await this.trust().setAndApply(path, value,
      inspection => this.runtimes.reload(inspection.projectDir, inspection.effectiveDecision === true),
      inspection => this.runtimes.release(inspection.projectDir),
      inspection => this.runtimes.abort(inspection.projectDir));
  }
  private async apply(action: Action): Promise<{ summary: string }> {
    await this.plan(action);
    const path = join(this.workspace, action.name);
    await mkdir(path, { mode: 0o700 });
    const identity = await this.directory(path);
    await this.trust().reserveUntrustedDirectory(path);
    await this.git(path, ["-c", "init.templateDir=", "init", "--initial-branch=main"]);
    await this.same(path, identity);
    const { path: trusted } = await this.inspect({ ...action, identity });
    await this.setTrust(trusted, true);
    return { summary: `${trusted} is trusted and ready for delegation` };
  }
}
