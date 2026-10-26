import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { lstat, mkdir, realpath, rename, rmdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import type { TrustService } from "../../kernel/resources/trust-service.js";
import type { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import type { Actor } from "../../kernel/settings/settings-record.js";
import type { ApprovalActionPreview, ChangeResult } from "../../kernel/settings/tool-contract.js";

const exec = promisify(execFile);
export const PROJECT_ACTION = "project.lifecycle";
type Operation = "trust" | "rename" | "archive" | "untrust";
interface Action { operation: Operation; name: string; destination?: string; github?: boolean; identity: string }
export interface ProjectRequest { action: "create" | "trust" | "rename" | "archive" | "untrust"; name: string; newName?: string; github?: boolean; reason: string }
export interface ProjectRuntimePort {
  assertIdle(path: string, moving: boolean): Promise<void>;
  reload(path: string, trusted: boolean): Promise<void>;
  release(path: string): Promise<void>;
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
    changes.registerAction(PROJECT_ACTION, {
      plan: params => this.mutex.run(() => this.plan(this.action(params))),
      apply: params => this.mutex.run(() => this.apply(this.action(params))),
    });
    this.changes = changes;
  }

  async request(input: ProjectRequest, actor: Actor, commandId: string): Promise<ChangeResult> {
    const changes = this.changes;
    if (!changes) throw new GatewayError("busy", "Project lifecycle settings are not available");
    this.name(input.name);
    if (!input.reason?.trim() || input.reason.length > 2000) throw new GatewayError("invalid_request", "A reason of 1 to 2000 characters is required");
    if (!["create", "trust", "rename", "archive", "untrust"].includes(input.action)) throw new GatewayError("invalid_request", "Unknown project action");
    if (input.newName !== undefined && input.action !== "rename") throw new GatewayError("invalid_request", "newName is only for rename");
    if (input.github !== undefined && input.action !== "create" && input.action !== "trust") throw new GatewayError("invalid_request", "github is only for create or trust");
    // Local creation has no executable authority. Record intent before mkdir, and
    // leave any partial directory for inspection rather than deleting user work.
    if (input.action === "create") await this.mutex.run(async () => {
      await this.root();
      const path = join(this.workspace, input.name);
      await this.absent(path);
      const changeId = randomUUID();
      await changes.record.append([{ changeId, commandId, at: new Date().toISOString(), actor,
        target: { kind: "global" }, layer: "global", key: "project.create", op: "set", after: { path }, reason: input.reason,
        tier: "quiet", tierBasis: { direction: "narrow", floor: "quiet", floorSource: "code", web: false, risk: null }, status: "pending", action: true }]);
      try {
        await mkdir(path, { mode: 0o700 });
        const identity = await this.directory(path);
        // An explicit false shadows an inherited/default-always decision before
        // any resource can load. Only the later approved action grants trust.
        await this.trust().reserveUntrustedDirectory(path);
        await this.git(path, ["-c", "init.templateDir=", "init", "--initial-branch=main"]);
        await this.same(path, identity);
        await changes.record.append([{ changeId: randomUUID(), refersTo: changeId, commandId, at: new Date().toISOString(), actor,
          target: { kind: "global" }, layer: "global", key: "project.create", op: "set", after: { path },
          tier: "quiet", tierBasis: { direction: "narrow", floor: "quiet", floorSource: "code", web: false, risk: null }, status: "applied", action: true }]);
      } catch (error) {
        await changes.record.append([{ changeId: randomUUID(), refersTo: changeId, commandId, at: new Date().toISOString(), actor,
          target: { kind: "global" }, layer: "global", key: "project.create", op: "set", after: { path },
          tier: "quiet", tierBasis: { direction: "narrow", floor: "quiet", floorSource: "code", web: false, risk: null }, status: "failed", action: true,
          failure: "Creation did not complete; inspect the retained path before retrying" }]);
        throw error;
      }
    });
    const operation = input.action === "create" ? "trust" : input.action;
    const path = join(this.workspace, input.name);
    const identity = await this.directory(path);
    const destination = operation === "rename" ? this.name(input.newName)
      : operation === "archive" ? `${input.name}-${randomUUID()}` : undefined;
    return changes.requestAction(PROJECT_ACTION, { operation, name: input.name, identity,
      ...(destination ? { destination } : {}), ...(input.github ? { github: true } : {}) }, { actor, commandId, reason: input.reason });
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
      || !["trust", "rename", "archive", "untrust"].includes(String(p.operation))
      || typeof p.identity !== "string" || !/^\d+:\d+$/.test(p.identity)
      || p.github !== undefined && p.github !== true) throw new GatewayError("invalid_request", "Invalid project action");
    this.name(p.name);
    if (p.operation === "rename") this.name(p.destination);
    else if (p.operation === "archive") {
      if (typeof p.destination !== "string" || !p.destination.startsWith(`${p.name}-`) || !/^[A-Za-z0-9_-]{1,110}$/.test(p.destination)) throw new GatewayError("invalid_request", "Invalid archive destination");
    } else if (p.destination !== undefined) throw new GatewayError("invalid_request", "Unexpected destination");
    if (p.github && p.operation !== "trust") throw new GatewayError("invalid_request", "GitHub creation requires a trust action");
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
  private destination(action: Action): string | undefined {
    return action.operation === "rename" ? join(this.workspace, action.destination!)
      : action.operation === "archive" ? join(this.workspace, ".archive", action.destination!) : undefined;
  }
  private async command(executable: string, args: string[], cwd: string): Promise<string> {
    // Do not inherit Git redirection into another checkout or executable hooks.
    const env: NodeJS.ProcessEnv = { ...process.env, GIT_TERMINAL_PROMPT: "0", GH_PROMPT_DISABLED: "1" };
    for (const key of Object.keys(env)) if (key.startsWith("GIT_") && key !== "GIT_TERMINAL_PROMPT") delete env[key];
    try { return (await exec(executable, args, { cwd, env, timeout: 60_000, maxBuffer: 1024 * 1024 })).stdout.trim(); }
    catch { throw new GatewayError("conflict", `${executable === this.githubExecutable ? "GitHub" : "Git"} command did not complete; inspect project state before retrying`); }
  }
  private git(path: string, args: string[]): Promise<string> {
    return this.command("git", ["-c", "core.hooksPath=/dev/null", ...args], path);
  }
  private async inspect(action: Action) {
    const path = join(this.workspace, action.name);
    await this.same(path, action.identity);
    const gitIdentity = await this.directory(join(path, ".git")); // linked worktrees/submodules are not project roots
    const root = await this.git(path, ["rev-parse", "--show-toplevel"]);
    if (root !== path) throw new GatewayError("invalid_request", "Lifecycle requires a standalone project repository");
    const worktrees = await this.git(path, ["worktree", "list", "--porcelain"]);
    if (worktrees.split("\n").filter(line => line.startsWith("worktree ")).length !== 1) throw new GatewayError("busy", "Project has linked worktrees; release their owners before changing its lifecycle");
    // Only the work tool's canonical claim-branch namespace owns claims.
    // Verify its trailer too; historical markers merged into main are not owners.
    // Retained claim branches are conservative: only their work owner cleans them.
    const refs = (await this.git(path, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"])).split("\n");
    if (refs.length > 200) throw new GatewayError("busy", "Too many project refs to inspect safely; review its work ownership first");
    for (const ref of refs.filter(ref => /^refs\/(?:heads|remotes\/[^/]+)\/[a-z0-9._-]+\/\d+-/.test(ref))) {
      const claim = await this.git(path, ["log", ref, "-1", "--grep=^Work-Claim-Session:", "--format=%(trailers:key=Work-Claim-Session,valueonly)"]);
      if (claim) throw new GatewayError("busy", "Project retains a work claim branch; its owner must release and clean it before lifecycle changes");
    }
    await this.runtimes.assertIdle(path, action.operation === "rename" || action.operation === "archive");
    const trust = await this.trust().inspect(path);
    if (trust.projectDir !== path) throw new GatewayError("invalid_request", "Project root changed");
    const destination = this.destination(action);
    if (destination) {
      if (action.operation === "archive") {
        const archive = join(this.workspace, ".archive");
        try { await this.directory(archive); if (await realpath(archive) !== archive) throw new Error("symlink"); }
        catch (error) { if (!(error instanceof GatewayError && error.code === "not_found")) throw new GatewayError("invalid_request", "Archive must be a real directory"); }
      }
      await this.absent(destination);
    }
    const remotes = (await this.git(path, ["config", "--local", "--null", "--list"])).split("\0").filter(value => value.startsWith("remote.")).join("\0");
    if (action.github && remotes) throw new GatewayError("conflict", "Project already has remotes; no GitHub repository will be created");
    const state = createHash("sha256").update(JSON.stringify({ gitIdentity, worktrees, remotes, saved: trust.savedDecision, effective: trust.effectiveDecision })).digest("hex");
    await this.same(path, action.identity);
    return { path, destination, trust, state };
  }
  private async plan(action: Action): Promise<ApprovalActionPreview> {
    const { path, destination, trust, state } = await this.inspect(action);
    return { title: `${action.operation[0]!.toUpperCase()}${action.operation.slice(1)} project ${action.name}`,
      target: { kind: "project", cwd: path }, items: [
        { label: "Project", value: path }, { label: "Identity", value: `${action.identity} / ${state}` },
        { label: "Trust", value: `${trust.effectiveDecision === true ? "Trusted" : "Not trusted"} → ${action.operation === "trust" || action.operation === "rename" && trust.effectiveDecision === true ? "Trusted" : "Not trusted"}` },
        ...(destination ? [{ label: "Destination", value: destination }] : []),
        ...(action.github ? [{ label: "GitHub", value: `Create private repository ${action.name} using existing gh authentication; set origin; do not push` }] : []),
        { label: "Implications", value: action.operation === "trust" ? "Trust loads executable project resources with your Mac user's authority; it is not a sandbox." : "Changes location or executable authority. Release active work first." },
      ] };
  }
  private async setTrust(path: string, value: boolean): Promise<void> {
    await this.trust().setAndApply(path, value,
      inspection => this.runtimes.reload(inspection.projectDir, inspection.effectiveDecision === true),
      inspection => this.runtimes.release(inspection.projectDir));
  }
  private async apply(action: Action): Promise<{ summary: string }> {
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
        await this.runtimes.assertIdle(path, true);
        await this.same(path, action.identity);
        if (await this.directory(destination) !== reservation || await realpath(destination) !== destination) throw new GatewayError("conflict", "Destination reservation changed");
        await rename(path, destination);
        moved = true;
        await this.same(destination, action.identity);
      }, inspection => this.runtimes.reload(inspection.projectDir, false), inspection => this.runtimes.release(inspection.projectDir));
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
