import { MANAGED_SUBAGENTS_SOURCE, managedProviderSettingsView, type ManagedSubagents } from "../kernel/delegation/managed-subagents.js";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  DefaultPackageManager,
  SettingsManager,
  type ResolvedPaths,
} from "../kernel/pi/coding-agent.js";
import { GatewayError, asUncertainOutcome } from "../errors.js";
import type { JsonValue, PackageInventory, PackageUpdates } from "../protocol/types.js";
import type { TrustService } from "../kernel/resources/trust-service.js";
import { loadPackageProvides, type InstalledPackage } from "./package-provides.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { type OutsideChanges } from "./settings-outside.js";
import { changeReview, type PlannedWrite } from "../kernel/settings/settings-types.js";
import { instanceId } from "../kernel/settings/scope-resolution.js";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "../kernel/run/gateway-work-registry.js";
import type { SettingsChangePath } from "../kernel/settings/settings-change.js";
import type { Actor } from "../kernel/settings/settings-record.js";
import type { ChangeResult, ConfirmChange } from "../kernel/settings/tool-contract.js";
import type { ChangeReview, NativeChangeAcceptance } from "../protocol/types.js";

const MAXIMUM_PACKAGES = 256;
const MAXIMUM_RESOURCE_ITEMS = 1_000;
const MAXIMUM_PACKAGE_UPDATES = 256;
const MAXIMUM_PACKAGE_STRING_BYTES = 8_192;
const MAXIMUM_PACKAGE_RESPONSE_BYTES = 768 * 1_024;
const PACKAGE_UPDATE_ACTION = "package.update";
const execFileAsync = promisify(execFile);
const EXACT_NPM_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

export interface PackageUpdateRequest { cwd: string; source: string; version: string; reason: string }

type UpdateKind = "npm" | "git";

type ConfiguredPackages = Parameters<SettingsManager["setPackages"]>[0];

interface PackageUpdatePlan {
  kind: UpdateKind; source: string; target: string; name: string; from: string; version: string; reason: string;
  installedPath: string | undefined; packages: ConfiguredPackages; review: ChangeReview;
}

function sourceKind(source: string): UpdateKind | "local" {
  if (source.startsWith("npm:")) return "npm";
  return /^(git:|https?:\/\/|ssh:\/\/|git@)/.test(source) ? "git" : "local";
}

function gitRepository(source: string): string {
  const at = source.lastIndexOf("@");
  return at > Math.max(source.lastIndexOf("/"), source.lastIndexOf(":")) ? source.slice(0, at) : source;
}

function normalizedGitLocator(locator: string): string {
  return locator.replace(/^git:/, "").replace(/^https:\/\//, "").replace(/\.git$/, "");
}

async function gitRead(cwd: string, args: string[]): Promise<string> {
  const env: NodeJS.ProcessEnv = { ...process.env, GIT_TERMINAL_PROMPT: "0" };
  for (const key of Object.keys(env)) if (key.startsWith("GIT_") && key !== "GIT_TERMINAL_PROMPT") delete env[key];
  try {
    return (await execFileAsync("git", ["--no-pager", "--no-optional-locks", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", ...args], { cwd, env, timeout: 30_000, maxBuffer: 1024 * 1024 })).stdout.trim();
  } catch {
    throw new GatewayError("conflict", "Git could not inspect the installed checkout; inspect it before retrying");
  }
}

async function installedVersion(installedPath: string | undefined): Promise<string | undefined> {
  if (!installedPath) return undefined;
  try {
    const manifest = JSON.parse(await readFile(join(installedPath, "package.json"), "utf8")) as { version?: unknown };
    return typeof manifest.version === "string" ? manifest.version : undefined;
  } catch {
    return undefined;
  }
}

function boundedString(value: string): boolean {
  return Buffer.byteLength(value) <= MAXIMUM_PACKAGE_STRING_BYTES;
}

function validateUnique<T>(values: T[], identity: (value: T) => string, label: string): void {
  const identities = new Set<string>();
  for (const value of values) {
    const id = identity(value);
    if (!boundedString(id) || identities.has(id)) {
      throw new GatewayError("conflict", `${label} contains oversized or duplicate identities`);
    }
    identities.add(id);
  }
}

function validatePackageInventory(packages: InstalledPackage[], resources: ResolvedPaths): void {
  if (packages.length > MAXIMUM_PACKAGES) throw new GatewayError("conflict", "Package inventory exceeds its item limit");
  validateUnique(packages, (value) => `${value.scope}:${value.source}`, "Package inventory");
  for (const value of packages) {
    if (!boundedString(value.source) || (value.installedPath !== undefined && !boundedString(value.installedPath))) {
      throw new GatewayError("conflict", "Package inventory exceeds its string limit");
    }
  }
  for (const [kind, values] of [
    ["extensions", resources.extensions],
    ["skills", resources.skills],
    ["prompts", resources.prompts],
    ["themes", resources.themes],
  ] as const) {
    if (values.length > MAXIMUM_RESOURCE_ITEMS) throw new GatewayError("conflict", `Package ${kind} exceeds its item limit`);
    validateUnique(values, (value) => value.path, `Package ${kind}`);
    for (const value of values) {
      if (!boundedString(value.path) || !boundedString(value.metadata.source)
        || (value.metadata.baseDir !== undefined && !boundedString(value.metadata.baseDir))) {
        throw new GatewayError("conflict", `Package ${kind} exceeds its string limit`);
      }
    }
  }
  if (Buffer.byteLength(JSON.stringify({ packages, resources })) > MAXIMUM_PACKAGE_RESPONSE_BYTES) {
    throw new GatewayError("conflict", "Package inventory exceeds its response byte limit");
  }
}

function validatePackageUpdates(updates: Awaited<ReturnType<DefaultPackageManager["checkForAvailableUpdates"]>>): void {
  if (updates.length > MAXIMUM_PACKAGE_UPDATES) throw new GatewayError("conflict", "Package updates exceed their item limit");
  validateUnique(updates, (value) => `${value.scope}:${value.source}`, "Package updates");
  for (const value of updates) {
    if (!boundedString(value.source) || !boundedString(value.displayName) || !boundedString(value.type)) {
      throw new GatewayError("conflict", "Package updates exceed their string limit");
    }
  }
  if (Buffer.byteLength(JSON.stringify({ updates })) > MAXIMUM_PACKAGE_RESPONSE_BYTES) {
    throw new GatewayError("conflict", "Package updates exceed their response byte limit");
  }
}

export class PackageService {
  private readonly mutex = new AsyncMutex();
  private changes?: SettingsChangePath;
  private reload?: () => void;

  constructor(
    private readonly agentDir: string,
    private readonly trust: TrustService,
    private readonly broadcast: (topic: string, payload: JsonValue) => void,
    private readonly workRegistry?: GatewayWorkRegistry,
    private readonly managedSubagents?: ManagedSubagents,
    private readonly outside?: OutsideChanges,
  ) {}

  register(changes: SettingsChangePath, reload: () => void): void {
    if (this.changes === changes) return;
    if (this.changes) throw new Error("Package service already has a settings owner");
    this.changes = changes;
    this.reload = reload;
  }

  private async manager(cwdInput: string, requireProjectTrust: boolean): Promise<{
    manager: DefaultPackageManager; settings: SettingsManager; project: { cwd: string; projectDir: string };
  }> {
    const trust = requireProjectTrust
      ? await this.trust.requireResolved(cwdInput)
      : await this.trust.inspect(cwdInput).then((inspection) => ({ cwd: inspection.cwd, projectDir: inspection.projectDir, trusted: inspection.effectiveDecision === true }));
    const settings = SettingsManager.create(trust.projectDir, this.agentDir, { projectTrusted: trust.trusted });
    if (settings.drainErrors().length > 0) {
      throw new GatewayError("conflict", "Canonical package settings could not be loaded");
    }
    return {
      manager: new DefaultPackageManager({ cwd: trust.cwd, projectDir: trust.projectDir, agentDir: this.agentDir, settingsManager: settings }),
      settings,
      project: { cwd: trust.cwd, projectDir: trust.projectDir },
    };
  }

  private async flushSettings(settings: SettingsManager): Promise<void> {
    await settings.flush();
    if (settings.drainErrors().length > 0) {
      throw new GatewayError("conflict", "Canonical package settings could not be persisted");
    }
  }

  private ensureConfiguredSource(manager: DefaultPackageManager, source: string, local: boolean): void {
    const scope = local ? "project" : "user";
    if (!manager.listConfiguredPackages().some((entry) => entry.scope === scope && entry.source === source)) {
      throw new GatewayError("not_found", "The requested package is not configured in that scope");
    }
  }

  private async trackAdministrative<T>(operation: (work: GatewayWorkHandle | undefined) => Promise<T>): Promise<T> {
    const work = this.workRegistry?.begin({
      kind: "administrative-provider-package-operation",
      hostEpoch: this.workRegistry.runtimeEpoch,
    });
    try {
      return await operation(work);
    } finally {
      work?.settle();
    }
  }

  async list(cwd: string): Promise<unknown> {
    return this.trackAdministrative(() => this.mutex.run(async () => {
      const { manager, settings, project } = await this.manager(cwd, false);
      const packages = manager.listConfiguredPackages();
      const resolver = this.managedSubagents
        ? new DefaultPackageManager({ cwd: project.cwd, projectDir: project.projectDir, agentDir: this.agentDir, settingsManager: managedProviderSettingsView(settings) })
        : manager;
      const resources = await resolver.resolve(async () => "skip");
      validatePackageInventory(packages, resources);
      const provides = await loadPackageProvides({
        agentDir: this.agentDir,
        ...(this.managedSubagents ? { managedSubagents: this.managedSubagents } : {}),
        trust: this.trust,
        cwd,
        settingsManager: settings,
        packages,
        resources,
      });
      return {
        packages: provides.entries,
        resources: provides.resources,
        ...(provides.diagnostic !== undefined ? { providesDiagnostic: provides.diagnostic } : {}),
      } satisfies Omit<PackageInventory, "resources"> & { resources: ResolvedPaths };
    }));
  }

  async checkUpdates(cwd: string): Promise<unknown> {
    return this.trackAdministrative(() => this.mutex.run(async () => {
      const { manager } = await this.manager(cwd, false);
      const updates = await manager.checkForAvailableUpdates();
      validatePackageUpdates(updates);
      return { updates } satisfies PackageUpdates;
    }));
  }

  async updatePackage(request: PackageUpdateRequest, requester: Actor, confirm?: ConfirmChange): Promise<ChangeResult> {
    if (!this.changes) throw new GatewayError("busy", "Package updates are not available");
    if (!request.reason.trim()) throw new GatewayError("invalid_request", "A reason is required for a package update");
    const plan = await this.trackAdministrative(() => this.mutex.run(() => this.planUpdate(request, requester)));
    if (!confirm) return { status: "review", review: plan.review, changes: [] };
    return (await confirm(plan.review, accepted => this.applyUpdate(request, plan.review.digest, requester, accepted))) ?? { status: "declined", changes: [] };
  }

  private async planUpdate(request: PackageUpdateRequest, requester: Actor): Promise<PackageUpdatePlan> {
    if (requester.kind !== "home") throw new GatewayError("invalid_request", "Package updates are available only in Tron Home");
    if (request.source === MANAGED_SUBAGENTS_SOURCE) {
      throw new GatewayError("conflict", "Tron manages pi-subagents; package commands cannot change its bundled payload");
    }
    const kind = sourceKind(request.source);
    if (kind === "local") throw new GatewayError("invalid_request", "Local package sources have no update source; edit or replace the path yourself");
    if (/^[a-z][a-z0-9+.-]*:\/\/[^/@]*@/i.test(request.source)) {
      throw new GatewayError("invalid_request", "Package sources with credentials in their URL are refused; keep credentials in their owned store");
    }
    const { manager, settings } = await this.manager(request.cwd, false);
    const configured = manager.listConfiguredPackages();
    if (!configured.some(entry => entry.scope === "user" && entry.source === request.source)) {
      if (configured.some(entry => entry.source === request.source)) {
        throw new GatewayError("invalid_request", "Repository packages are read-only in the app; edit the repository configuration");
      }
      throw new GatewayError("not_found", "The requested package is not configured in that scope");
    }
    const installedPath = manager.getInstalledPath(request.source, "user");
    const packagesAfter = (target: string): ConfiguredPackages => (settings.getGlobalSettings().packages ?? []).map(entry => {
      if (typeof entry === "string") return entry === request.source ? target : entry;
      return entry.source === request.source ? { ...entry, source: target } : entry;
    });
    if (kind === "npm") {
      const spec = request.source.slice("npm:".length);
      const at = spec.lastIndexOf("@");
      const name = at > 0 ? spec.slice(0, at) : spec;
      if (!/^(?:@[a-z0-9-~][a-z0-9-._~]*\/)?[a-z0-9-~][a-z0-9-._~]*$/.test(name)) {
        throw new GatewayError("invalid_request", "The npm package name is not valid");
      }
      if (!EXACT_NPM_VERSION.test(request.version) || request.version.length > 64) {
        throw new GatewayError("invalid_request", "A package update requires an exact npm version such as 1.2.3; tags and ranges are refused");
      }
      const from = await installedVersion(installedPath);
      if (!from) throw new GatewayError("conflict", "The package is not installed; install it before updating");
      if (from === request.version) throw new GatewayError("conflict", `${name} is already at ${from}; nothing to update`);
      const target = `npm:${name}@${request.version}`;
      return this.planned({ kind, source: request.source, target, name, from, version: request.version, reason: request.reason, installedPath, packages: packagesAfter(target) });
    }
    if (!/^[0-9a-f]{40}$/.test(request.version)) {
      throw new GatewayError("invalid_request", "A git package update requires a full 40-character commit SHA");
    }
    if (!installedPath || !existsSync(join(installedPath, ".git"))) {
      throw new GatewayError("conflict", "The package is not installed as a git checkout; install it before updating");
    }
    const repo = gitRepository(request.source);
    const origin = await gitRead(installedPath, ["remote", "get-url", "origin"]);
    if (normalizedGitLocator(origin) !== normalizedGitLocator(repo)) {
      throw new GatewayError("conflict", "The installed checkout's origin does not match the configured repository; refusing to replace it");
    }
    const from = await gitRead(installedPath, ["rev-parse", "HEAD"]);
    if (from === request.version) throw new GatewayError("conflict", `${repo} is already at ${from}; nothing to update`);
    const target = `${repo}@${request.version}`;
    return this.planned({ kind, source: request.source, target, name: repo, from, version: request.version, reason: request.reason, installedPath, packages: packagesAfter(target) });
  }

  private planned(input: Omit<PackageUpdatePlan, "review">): PackageUpdatePlan {
    const identity = { operation: PACKAGE_UPDATE_ACTION, kind: input.kind, source: input.source, target: input.target, name: input.name, from: input.from, version: input.version };
    const items = [{ label: `Package ${input.name}`, before: input.from, after: input.version, detail: `${input.source}\nUser package (global)`, exact: JSON.stringify(identity) }];
    if (input.target !== input.source) {
      items.push({ label: "Configured source", before: input.source, after: input.target, detail: "sources.packages (global) pin", exact: JSON.stringify({ source: input.source, target: input.target }) });
    }
    const review = changeReview(identity, { title: input.kind === "npm"
      ? `Update ${input.name} to exactly ${input.version}`
      : `Update ${input.name} to commit ${input.version}`, requiresTap: true, reason: input.reason, items });
    return { ...input, review };
  }

  private applyUpdate(request: PackageUpdateRequest, digest: string, requester: Actor, accepted: NativeChangeAcceptance): Promise<ChangeResult> {
    const changes = this.changes!;
    return changes.withTarget({ kind: "global" }, () => this.trackAdministrative(work => this.mutex.run(async () => {
      const plan = await this.planUpdate(request, requester);
      if (plan.review.digest !== digest) throw new GatewayError("conflict", "The package changed since review; nothing was applied");
      if (plan.kind === "git" && await gitRead(plan.installedPath!, ["status", "--porcelain", "--untracked-files=no"]) !== "") {
        throw new GatewayError("conflict", "The installed checkout has local edits to tracked files; refusing to replace them");
      }
      await changes.record.recover();
      const changeId = randomUUID();
      const entry = { commandId: accepted.commandId, actor: { kind: "ui" as const, id: accepted.deviceId }, target: { kind: "global" as const },
        layer: "global" as const, key: PACKAGE_UPDATE_ACTION, op: "set" as const,
        after: { ...plan.review, requester: { kind: requester.kind, id: requester.id } }, reason: request.reason, action: true as const };
      await changes.record.append([{ ...entry, changeId, at: new Date().toISOString(), status: "started" }]);
      const { manager, settings } = await this.manager(request.cwd, false);
      const writes: PlannedWrite[] = [{ store: { kind: "global" }, instance: instanceId("sources.packages", {}), changeId, value: plan.packages }];
      await this.outside?.begin(writes);
      manager.setProgressCallback(event => { work?.progress(); this.broadcast("packages.progress", { operationId: changeId, event } as unknown as JsonValue); });
      try {
        settings.setPackages(plan.packages);
        await this.flushSettings(settings);
        await manager.install(plan.target, { local: false });
        const after = plan.kind === "npm"
          ? await installedVersion(manager.getInstalledPath(plan.source, "user"))
          : await gitRead(plan.installedPath!, ["rev-parse", "HEAD"]);
        if (after !== plan.version) throw new Error(`Installed ${after ?? "nothing"} instead of exact ${plan.version}`);
      } catch (error) {
        this.reload?.();
        await changes.record.append([{ ...entry, changeId: randomUUID(), refersTo: changeId, at: new Date().toISOString(), status: "failed",
          failure: "Package update did not complete cleanly; inspect the configured source and installed package before retrying" }])
          .catch(publication => { throw asUncertainOutcome(publication, "Package update failed and its audit could not be published; inspect before retrying"); });
        throw asUncertainOutcome(error, "Package update may have occurred; inspect the configured source and installed package before retrying");
      } finally {
        manager.setProgressCallback(undefined);
        await this.outside?.end(writes, new Map([[changeId, { changeId }]]));
      }
      await changes.record.append([{ ...entry, changeId: randomUUID(), refersTo: changeId, at: new Date().toISOString(), status: "applied" }])
        .catch(error => { throw asUncertainOutcome(error, "Package applied but history publication failed"); });
      this.broadcast("packages.changed", { cwd: request.cwd });
      this.reload?.();
      return { status: "applied", review: plan.review, changes: [{ changeId, key: PACKAGE_UPDATE_ACTION, layer: "global",
        status: "applied", undoable: false, result: { source: plan.source, target: plan.target, from: plan.from, version: plan.version } }] };
    })));
  }

  async mutate(action: "remove" | "update", source: string | undefined, cwd: string, local: boolean): Promise<{ operationId: string }> {
    return this.trackAdministrative((work) => this.mutex.run(async () => {
      if (source === MANAGED_SUBAGENTS_SOURCE) {
        throw new GatewayError("conflict", "Tron manages pi-subagents; package commands cannot change its bundled payload");
      }
      const operationId = randomUUID();
      let manager: DefaultPackageManager | undefined;
      let mutationAdmitted = false;
      try {
        const managed = await this.manager(cwd, local);
        manager = managed.manager;
        manager.setProgressCallback((event) => {
          work?.progress();
          this.broadcast("packages.progress", { operationId, event } as unknown as JsonValue);
        });
        const { settings } = managed;
        const writes: PlannedWrite[] = [{ store: local ? { kind: "project", root: managed.project.projectDir } : { kind: "global" },
          instance: instanceId("sources.packages", {}), changeId: operationId, value: undefined }];
        await this.outside?.begin(writes);
        try {
        if (action === "remove") {
          if (source === undefined) throw new GatewayError("invalid_request", "Package source is required");
          mutationAdmitted = true;
          await manager.removeAndPersist(source, { local });
          await this.flushSettings(settings);
        } else if (source === undefined) {
          mutationAdmitted = true;
          await manager.update();
        } else {
          this.ensureConfiguredSource(manager, source, local);
          mutationAdmitted = true;
          await manager.install(source, { local });
        }
        } finally {
          await this.outside?.end(writes, new Map());
        }
        this.broadcast("packages.completed", { operationId, success: true });
      } catch (error) {
        try {
          this.broadcast("packages.completed", {
            operationId,
            success: false,
            error: error instanceof Error ? error.message : String(error),
          });
        } catch { }
        throw mutationAdmitted
          ? asUncertainOutcome(error, "The admitted package operation has an unproven outcome; reconcile package state before issuing another command")
          : error;
      } finally {
        manager?.setProgressCallback(undefined);
      }
      return { operationId };
    }));
  }
}
