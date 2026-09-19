import { randomUUID } from "node:crypto";
import { access } from "node:fs/promises";
import { resolve } from "node:path";
import {
  DefaultPackageManager,
  SettingsManager,
  type ResolvedPaths,
} from "@earendil-works/pi-coding-agent";
import { GatewayError, asUncertainOutcome } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { TrustService } from "./trust-service.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

interface ConfiguredPackageProjection {
  source: string;
  scope: "user" | "project";
  filtered: boolean;
  installedPath?: string;
}

interface PackageUpdateProjection {
  source: string;
  displayName: string;
  type: string;
  scope: "user" | "project";
}

const MAXIMUM_PACKAGES = 256;
const MAXIMUM_RESOURCE_ITEMS = 1_000;
const MAXIMUM_PACKAGE_UPDATES = 256;
const MAXIMUM_PACKAGE_STRING_BYTES = 8_192;
const MAXIMUM_PACKAGE_RESPONSE_BYTES = 768 * 1_024;

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

export function validatePackageInventory(packages: ConfiguredPackageProjection[], resources: ResolvedPaths): void {
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

export function validatePackageUpdates(updates: PackageUpdateProjection[]): void {
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

  constructor(
    private readonly agentDir: string,
    private readonly trust: TrustService,
    private readonly broadcast: (topic: string, payload: JsonValue) => void,
    private readonly workRegistry?: GatewayWorkRegistry,
  ) {}

  private async manager(cwdInput: string, requireProjectTrust: boolean): Promise<{ manager: DefaultPackageManager; settings: SettingsManager }> {
    const trust = requireProjectTrust
      ? await this.trust.requireResolved(cwdInput)
      : await this.trust.inspect(cwdInput).then((inspection) => ({ cwd: inspection.cwd, trusted: inspection.effectiveDecision === true }));
    const settings = SettingsManager.create(trust.cwd, this.agentDir, { projectTrusted: trust.trusted });
    // The SDK deliberately exposes load failures through drainErrors rather than
    // throwing from getters. Never let a malformed settings file look like an
    // empty package inventory or authorize a mutation against that false view.
    if (settings.drainErrors().length > 0) {
      throw new GatewayError("conflict", "Canonical package settings could not be loaded");
    }
    return { manager: new DefaultPackageManager({ cwd: trust.cwd, agentDir: this.agentDir, settingsManager: settings }), settings };
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

  private async validateInstallSource(source: string, cwd: string): Promise<void> {
    const trimmed = source.trim();
    if (!trimmed) throw new GatewayError("invalid_request", "Package source is required");
    // Pi treats bare names and file: URLs as local paths. Reject a missing
    // path before admitting the SDK mutation; unlike an admitted npm/git
    // command, this is a definite no-effect validation failure.
    const remote = /^(?:npm|git|github|http|https|ssh):/u.test(trimmed);
    if (!remote) {
      const path = trimmed.startsWith("file:") ? trimmed.slice("file:".length) : trimmed;
      try {
        await access(resolve(cwd, path));
      } catch {
        throw new GatewayError("not_found", `Package source path does not exist: ${path}`);
      }
    }
    if (trimmed.startsWith("npm:") && trimmed.slice("npm:".length).trim() === "") {
      throw new GatewayError("invalid_request", "Package source is required");
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
      const { manager } = await this.manager(cwd, false);
      const packages = manager.listConfiguredPackages();
      const resources = await manager.resolve(async () => "skip");
      validatePackageInventory(packages, resources);
      return { packages, resources };
    }));
  }

  async checkUpdates(cwd: string): Promise<unknown> {
    return this.trackAdministrative(() => this.mutex.run(async () => {
      const { manager } = await this.manager(cwd, false);
      const updates = await manager.checkForAvailableUpdates();
      validatePackageUpdates(updates);
      return { updates };
    }));
  }

  async mutate(action: "install" | "remove" | "update", source: string | undefined, cwd: string, local: boolean): Promise<{ operationId: string }> {
    return this.trackAdministrative((work) => this.mutex.run(async () => {
      const operationId = randomUUID();
      let manager: DefaultPackageManager | undefined;
      // Set at mutation admission, before invoking the SDK. The pinned SDK has
      // no atomicity receipt: install/remove/update can apply an earlier item
      // and then throw. Once admitted, every failure is therefore fenced as
      // unknown rather than permitting a replay that duplicates side effects.
      let effectApplied = false;
      try {
        const managed = await this.manager(cwd, local);
        manager = managed.manager;
        manager.setProgressCallback((event) => {
          work?.progress();
          this.broadcast("packages.progress", { operationId, event } as unknown as JsonValue);
        });
        const { settings } = managed;
        if (action === "install") {
          if (source === undefined) throw new GatewayError("invalid_request", "Package source is required");
          await this.validateInstallSource(source, cwd);
          effectApplied = true;
          await manager.install(source, { local });
          manager.addSourceToSettings(source, { local });
          await this.flushSettings(settings);
        } else if (action === "remove") {
          if (source === undefined) throw new GatewayError("invalid_request", "Package source is required");
          effectApplied = true;
          await manager.remove(source, { local });
          manager.removeSourceFromSettings(source, { local });
          await this.flushSettings(settings);
        } else if (source === undefined) {
          // An omitted source retains Pi's existing "update all" command.
          effectApplied = true;
          await manager.update();
        } else {
          // Pi's public update(source) intentionally updates every matching
          // scope. The RPC identifies one row, so use the public scoped install
          // seam to refresh only that row's user/project installation while
          // leaving its existing settings entry untouched.
          this.ensureConfiguredSource(manager, source, local);
          effectApplied = true;
          await manager.install(source, { local });
        }
        this.broadcast("packages.completed", { operationId, success: true });
      } catch (error) {
        this.broadcast("packages.completed", {
          operationId,
          success: false,
          error: error instanceof Error ? error.message : String(error),
        });
        throw effectApplied
          ? asUncertainOutcome(error, "The package change was applied but its settings could not be persisted; refresh package state before retrying")
          : error;
      } finally {
        manager?.setProgressCallback(undefined);
      }
      return { operationId };
    }));
  }
}
