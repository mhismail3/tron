import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { lstat, mkdir, opendir, realpath, rename, rmdir } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { promisify } from "node:util";
import { asUncertainOutcome, GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import type { TrustInspection, TrustService } from "../../kernel/resources/trust-service.js";
import type { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import type { Actor } from "../../kernel/settings/settings-record.js";
import type { ChangeResult, ConfirmChange } from "../../kernel/settings/tool-contract.js";
import type { ChangeReview } from "../../protocol/types.js";
import { changeReview } from "../../kernel/settings/settings-types.js";

const exec = promisify(execFile);
export const PROJECT_ACTION = "project.lifecycle";
type Operation = "create" | "trust" | "rename" | "archive" | "untrust";
export type ProjectChangeResult = ChangeResult & { intent?: Action };
interface Action { operation: Operation; name: string; destination?: string; github?: boolean; identity: string }
export interface ProjectRequest { action: "create" | "trust" | "rename" | "archive" | "untrust"; name: string; newName?: string; github?: boolean; reason: string }
export type ProjectEligibility = { allowed: true } | { allowed: false; code: string; reason: string };
export interface ProjectRow {
  name: string;
  path: string;
  trust: TrustInspection | null;
  eligibility: Record<"trust" | "github" | "rename" | "archive" | "untrust", ProjectEligibility>;
}
export interface ProjectPage { workspace: string; projects: ProjectRow[]; nextCursor: string | null }
const eligibilityActions = ["trust", "github", "rename", "archive", "untrust"] as const;

/** Live occupancy as of one read: runtime slots are consulted live, Home work as of `occupancy()`. */
export interface ProjectOccupancy { assertIdle(path: string, moving: boolean): void }
export interface ProjectRuntimePort {
  occupancy(signal?: AbortSignal): Promise<ProjectOccupancy>;
  reload(path: string, trusted: boolean): Promise<void>;
  release(path: string): Promise<void>;
  abort(path: string): Promise<void>;
}

/** Filesystem/Git effects have one owner; settings owns approval, execution claims,
 * expiry and outcomes. Failed/uncertain effects are inspected, never replayed. */
export class ProjectLifecycle {
  private readonly mutex = new AsyncMutex();
  private changes: SettingsChangePath | undefined;
  readonly workspace: string;
  constructor(private readonly trust: () => TrustService, private readonly runtimes: ProjectRuntimePort,
    options: { workspace?: string; githubExecutable?: string } = {}) {
    this.workspace = options.workspace ?? join(homedir(), "Workspace");
    this.githubExecutable = options.githubExecutable ?? "gh";
  }
  private readonly githubExecutable: string;

  register(changes: SettingsChangePath): void {
    if (this.changes === changes) return;
    if (this.changes) throw new Error("Project lifecycle already has a settings owner");
    this.changes = changes;
  }

  /** Disposable projections, never a reservation or permission to execute. */
  async list(options: { limit: number; after?: string }, signal?: AbortSignal): Promise<ProjectPage> {
    signal?.throwIfAborted();
    await this.root();
    const names: string[] = [];
    let scanned = 0;
    for await (const entry of await opendir(this.workspace)) {
      signal?.throwIfAborted();
      if (++scanned > 1000) throw new GatewayError("busy", "Too many Workspace entries to list safely; use projects.inspect for a specific folder");
      if (!entry.name.startsWith(".") && (entry.isDirectory() || entry.isSymbolicLink())) names.push(entry.name);
    }
    names.sort();
    const remaining = names.filter(name => options.after === undefined || name > options.after);
    const selected = remaining.slice(0, options.limit);
    const projects: ProjectRow[] = [];
    // One read of Home work serves every row: these are disposable projections, and the
    // effects revalidate (#2072: a read of the task history per row took 40-90 s).
    const occupancy = selected.length > 0 ? await this.runtimes.occupancy(signal) : undefined;
    for (const name of selected) projects.push(await this.read(join(this.workspace, name), signal, occupancy));
    signal?.throwIfAborted();
    return { workspace: this.workspace, projects, nextCursor: remaining.length > selected.length ? selected.at(-1)! : null };
  }

  async read(cwd: string, signal?: AbortSignal, occupancy?: ProjectOccupancy): Promise<ProjectRow> {
    signal?.throwIfAborted();
    if (!isAbsolute(cwd)) throw new GatewayError("invalid_request", "Project inspection requires an absolute folder path");
    const path = resolve(cwd), name = basename(path);
    const denied = (error: unknown): ProjectEligibility => {
      if (!(error instanceof GatewayError)) throw error;
      return { allowed: false, code: error.code, reason: error.message };
    };
    const row: ProjectRow = { name, path, trust: null,
      eligibility: Object.fromEntries(eligibilityActions.map(action => [action,
        { allowed: false, code: "invalid_request", reason: "Unsupported project folder" }])) as ProjectRow["eligibility"] };
    try {
      const identity = await this.directory(path);
      if (await realpath(path) !== path) throw new GatewayError("invalid_request", "Project paths must be canonical directories, not symlinks");
      row.trust = await this.trust().inspect(path);
      if (dirname(path) !== this.workspace) throw new GatewayError("invalid_request", "Lifecycle supports only direct Workspace project folders");
      this.name(name);
      const inspected = await this.inspect({ operation: "untrust", name, identity }, signal, occupancy);
      occupancy ??= inspected.occupancy;
      signal?.throwIfAborted();
      row.trust = inspected.trust;
      row.eligibility.trust = row.eligibility.untrust = { allowed: true };
      row.eligibility.github = inspected.hasRemotes
        ? { allowed: false, code: "conflict", reason: "Project already has remotes; no GitHub repository will be created" } : { allowed: true };
      try {
        occupancy.assertIdle(path, true);
        row.eligibility.rename = { allowed: true };
        try { await this.archiveDirectory(); row.eligibility.archive = { allowed: true }; }
        catch (error) { row.eligibility.archive = denied(error); }
      } catch (error) { row.eligibility.rename = row.eligibility.archive = denied(error); }
    } catch (error) {
      const refusal = denied(error);
      for (const action of eligibilityActions) row.eligibility[action] = refusal;
    }
    signal?.throwIfAborted();
    return row;
  }

  /** A disposable exact review, or an authenticated native execution. No pending store or outbox. */
  async request(input: ProjectRequest, actor: Actor, commandId: string,
    options: { confirmation?: { digest: string; intent: unknown }; confirm?: ConfirmChange } = {}): Promise<ProjectChangeResult> {
    const changes = this.changes;
    if (!changes) throw new GatewayError("busy", "Project lifecycle settings are not available");
    this.name(input.name);
    if (!input.reason?.trim() || input.reason.length > 2000) throw new GatewayError("invalid_request", "A reason of 1 to 2000 characters is required");
    if (!["create", "trust", "rename", "archive", "untrust"].includes(input.action)) throw new GatewayError("invalid_request", "Unknown project action");
    if (input.newName !== undefined && input.action !== "rename") throw new GatewayError("invalid_request", "newName is only for rename");
    if (input.github !== undefined && input.action !== "create" && input.action !== "trust") throw new GatewayError("invalid_request", "github is only for create or trust");
    if (options.confirmation && actor.kind !== "ui") throw new GatewayError("invalid_request", "Only paired native UI can confirm a reviewed action");
    const action = options.confirmation ? this.action(options.confirmation.intent) : {
      operation: input.action, name: input.name,
      identity: await this.directory(input.action === "create" ? this.workspace : join(this.workspace, input.name)),
      ...(input.action === "rename" ? { destination: this.name(input.newName) } : input.action === "archive" ? { destination: input.name + "-" + randomUUID() } : {}),
      ...(input.github ? { github: true } : {}),
    };
    if (action.operation !== input.action || action.name !== input.name || !!action.github !== !!input.github
      || input.action === "rename" && action.destination !== input.newName) throw new GatewayError("invalid_request", "Project review intent does not match its typed action");
    const review = await this.mutex.run(() => this.review(action, input.reason));
    if (options.confirmation) return this.execute(action, options.confirmation.digest, actor, commandId, input.reason);
    if (!options.confirm) return { status: "review", review, intent: action, changes: [] };
    return await options.confirm(review, accepted => this.execute(action, review.digest,
      { kind: "ui", id: accepted.deviceId }, accepted.commandId, input.reason)) ?? { status: "declined", changes: [] };
  }

  private async review(action: Action, reason: string): Promise<ChangeReview> {
    const preview = await this.plan(action);
    return changeReview(action, { ...preview, reason, requiresTap: true });
  }

  private execute(action: Action, digest: string, actor: Actor, commandId: string, reason: string): Promise<ProjectChangeResult> {
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
  private action(params: unknown): Action {
    if (!params || typeof params !== "object" || Array.isArray(params)) throw new GatewayError("invalid_request", "Invalid project action");
    const p = params as Record<string, unknown>;
    if (Object.keys(p).some(key => !["operation", "name", "destination", "github", "identity"].includes(key))
      || !["create", "trust", "rename", "archive", "untrust"].includes(String(p.operation))
      || typeof p.identity !== "string" || !/^\d+:\d+$/.test(p.identity)
      || p.github !== undefined && p.github !== true) throw new GatewayError("invalid_request", "Invalid project action");
    this.name(p.name);
    if (p.operation === "rename") this.name(p.destination);
    else if (p.operation === "archive") {
      if (typeof p.destination !== "string" || !p.destination.startsWith(`${p.name}-`) || !/^[A-Za-z0-9_-]{1,110}$/.test(p.destination)) throw new GatewayError("invalid_request", "Invalid archive destination");
    } else if (p.destination !== undefined) throw new GatewayError("invalid_request", "Unexpected destination");
    if (p.github && p.operation !== "trust" && p.operation !== "create") throw new GatewayError("invalid_request", "GitHub creation requires a trust action");
    return p as unknown as Action;
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
  private async archiveDirectory(): Promise<void> {
    const archive = join(this.workspace, ".archive");
    try { await this.directory(archive); if (await realpath(archive) !== archive) throw new Error("symlink"); }
    catch (error) {
      if (!(error instanceof GatewayError && error.code === "not_found")) throw new GatewayError("invalid_request", "Archive must be a real directory");
    }
  }
  private destination(action: Action): string | undefined {
    return action.operation === "rename" ? join(this.workspace, action.destination!)
      : action.operation === "archive" ? join(this.workspace, ".archive", action.destination!) : undefined;
  }
  private async command(executable: string, args: string[], cwd: string, signal?: AbortSignal): Promise<string> {
    // Do not inherit Git redirection into another checkout or executable hooks.
    const env: NodeJS.ProcessEnv = { ...process.env, GIT_TERMINAL_PROMPT: "0", GH_PROMPT_DISABLED: "1" };
    for (const key of Object.keys(env)) if (key.startsWith("GIT_") && key !== "GIT_TERMINAL_PROMPT") delete env[key];
    try { return (await exec(executable, args, { cwd, env, timeout: 60_000, maxBuffer: 1024 * 1024, ...(signal ? { signal } : {}) })).stdout.trim(); }
    catch { signal?.throwIfAborted(); throw new GatewayError("conflict", `${executable === this.githubExecutable ? "GitHub" : "Git"} command did not complete; inspect project state before retrying`); }
  }
  private git(path: string, args: string[], signal?: AbortSignal): Promise<string> {
    // Even read-only log inspection can launch a repository-configured verifier.
    return this.command("git", ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false", ...args], path, signal);
  }
  private async inspect(action: Action, signal?: AbortSignal, shared?: ProjectOccupancy) {
    signal?.throwIfAborted();
    const path = join(this.workspace, action.name);
    await this.same(path, action.identity);
    const gitIdentity = await this.directory(join(path, ".git")); // linked worktrees/submodules are not project roots
    const root = await this.git(path, ["rev-parse", "--show-toplevel"], signal);
    if (root !== path) throw new GatewayError("invalid_request", "Lifecycle requires a standalone project repository");
    const worktrees = await this.git(path, ["worktree", "list", "--porcelain"], signal);
    if (worktrees.split("\n").filter(line => line.startsWith("worktree ")).length !== 1) throw new GatewayError("busy", "Project has linked worktrees; release their owners before changing its lifecycle");
    // Only the work tool's canonical claim-branch namespace owns claims.
    // Verify its trailer too; historical markers merged into main are not owners.
    // Retained claim branches are conservative: only their work owner cleans them.
    const refs = (await this.git(path, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], signal)).split("\n");
    if (refs.length > 200) throw new GatewayError("busy", "Too many project refs to inspect safely; review its work ownership first");
    for (const ref of refs.filter(ref => /^refs\/(?:heads|remotes\/[^/]+)\/[a-z0-9._-]+\/\d+-/.test(ref))) {
      const claim = await this.git(path, ["log", ref, "-1", "--grep=^Work-Claim-Session:", "--format=%(trailers:key=Work-Claim-Session,valueonly)"], signal);
      if (claim) throw new GatewayError("busy", "Project retains a work claim branch; its owner must release and clean it before lifecycle changes");
    }
    const occupancy = shared ?? await this.runtimes.occupancy(signal);
    occupancy.assertIdle(path, action.operation === "rename" || action.operation === "archive");
    const trust = await this.trust().inspect(path);
    if (trust.projectDir !== path) throw new GatewayError("invalid_request", "Project root changed");
    const destination = this.destination(action);
    if (destination) {
      if (action.operation === "archive") await this.archiveDirectory();
      await this.absent(destination);
    }
    const remotes = (await this.git(path, ["config", "--local", "--null", "--list"], signal)).split("\0").filter(value => value.startsWith("remote.")).join("\0");
    if (action.github && remotes) throw new GatewayError("conflict", "Project already has remotes; no GitHub repository will be created");
    const state = createHash("sha256").update(JSON.stringify({ gitIdentity, worktrees, remotes, saved: trust.savedDecision, effective: trust.effectiveDecision })).digest("hex");
    await this.same(path, action.identity);
    return { path, destination, trust, state, hasRemotes: remotes.length > 0, occupancy };
  }
  private async plan(action: Action): Promise<Omit<ChangeReview, "digest" | "requiresTap">> {
    if (action.operation === "create") {
      await this.root();
      if (await this.directory(this.workspace) !== action.identity) throw new GatewayError("conflict", "Workspace identity changed");
      const path = join(this.workspace, action.name);
      await this.absent(path);
      return { title: "Create and trust project " + action.name, items: [
        { label: "Project", before: "Absent", after: path, exact: action.identity },
        { label: "Repository", before: "Absent", after: "Git repository on main" },
        { label: "Authority", before: "None", after: "Trusted executable project resources", detail: "Trust is not a sandbox; code runs with your Mac user's authority." },
        ...(action.github ? [{ label: "GitHub", before: "No repository", after: "Create private repository and origin; do not push" }] : []),
      ] };
    }
    const { path, destination, trust, state } = await this.inspect(action);
    return { title: action.operation[0]!.toUpperCase() + action.operation.slice(1) + " project " + action.name, items: [
      { label: "Project", before: path, after: destination ?? path, exact: action.identity + " / " + state },
      { label: "Trust", before: trust.effectiveDecision === true ? "Trusted" : "Not trusted",
        after: action.operation === "trust" || action.operation === "rename" && trust.effectiveDecision === true ? "Trusted" : "Not trusted",
        detail: "Trust permits executable resources with your Mac user's authority. Revocation cannot undo code already run." },
      ...(action.github ? [{ label: "GitHub", before: "No remotes", after: "Create private repository " + action.name + " and origin; do not push" }] : []),
    ] };
  }
  private async setTrust(path: string, value: boolean): Promise<void> {
    await this.trust().setAndApply(path, value,
      inspection => this.runtimes.reload(inspection.projectDir, inspection.effectiveDecision === true),
      inspection => this.runtimes.release(inspection.projectDir),
      inspection => this.runtimes.abort(inspection.projectDir));
  }
  private async apply(action: Action): Promise<{ summary: string }> {
    if (action.operation === "create") {
      await this.plan(action);
      const path = join(this.workspace, action.name);
      await mkdir(path, { mode: 0o700 });
      const identity = await this.directory(path);
      await this.trust().reserveUntrustedDirectory(path);
      await this.git(path, ["-c", "init.templateDir=", "init", "--initial-branch=main"]);
      await this.same(path, identity);
      return this.apply({ ...action, operation: "trust", identity });
    }
    const { path, destination, trust } = await this.inspect(action);
    if (!destination) {
      if (action.github) {
        await this.command(this.githubExecutable, ["repo", "create", action.name, "--private", "--source", path, "--remote", "origin"], path);
        await this.same(path, action.identity);
      }
      await this.setTrust(path, action.operation === "trust");
      return { summary: `${path} is ${action.operation === "trust" ? "trusted and ready for delegation" : "untrusted"}` };
    }
    // The existing transactional reload fence excludes new Gateway work while
    // moving. Keep the old name explicitly false even after the move: a new
    // directory reusing that name must never inherit the departed project's grant.
    let moved = false;
    let reservation: string | undefined;
    try {
      await this.inspect(action);
      if (action.operation === "archive") {
        const archive = join(this.workspace, ".archive");
        await mkdir(archive, { mode: 0o700 }).catch(error => { if (error.code !== "EEXIST") throw error; });
        await this.directory(archive);
        if (await realpath(archive) !== archive) throw new GatewayError("invalid_request", "Archive path changed");
      }
      // Reserve exclusively instead of rename's normal overwrite behavior.
      // Trust's exact-path deny shadows ancestor authority before the move.
      await mkdir(destination, { mode: 0o700 });
      reservation = await this.directory(destination);
      await this.trust().relocate(path, destination, action.operation === "rename" && trust.effectiveDecision === true, async () => {
        (await this.runtimes.occupancy()).assertIdle(path, true);
        await this.same(path, action.identity);
        if (await this.directory(destination) !== reservation || await realpath(destination) !== destination) throw new GatewayError("conflict", "Destination reservation changed");
        await rename(path, destination);
        moved = true;
        await this.same(destination, action.identity);
      }, inspection => this.runtimes.reload(inspection.projectDir, inspection.effectiveDecision === true), inspection => this.runtimes.release(inspection.projectDir),
      inspection => this.runtimes.abort(inspection.projectDir));
      return { summary: `${path} moved to ${destination}; ${action.operation === "archive" ? "recover manually by moving the retained folder back after releasing work, then request trust; no files deleted" : "new sessions use the new path; historical sessions retain their original path"}` };
    } catch (error) {
      // Never move files backwards automatically after an uncertain external
      // change. The failed approval reports retained state for explicit recovery.
      throw new GatewayError("conflict", `Project move did not complete cleanly; inspect ${path} and ${destination}. ${moved ? "The folder moved and remains untrusted unless its final trust publication completed." : "The source was retained; it may now be untrusted."}`, false, { cause: error instanceof Error ? error.message : String(error) });
    } finally {
      if (!moved && reservation && await this.directory(destination).catch(() => undefined) === reservation) await rmdir(destination).catch(() => {});
    }
  }
}
