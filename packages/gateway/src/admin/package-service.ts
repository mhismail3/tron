import { randomUUID } from "node:crypto";
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
      // Set once the package owner's own operation returned. Its filesystem
      // effect (an installed/removed package or a refreshed installation) has
      // already landed, so any later failure -- settings flush or progress
      // publication -- must not be reported as a clean rejection that permits a
      // replay. A failure inside the package owner's call keeps its own
      // classification; that operation owns whether it applied anything.
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
          await manager.installAndPersist(source!, { local });
          effectApplied = true;
          await this.flushSettings(settings);
        } else if (action === "remove") {
          await manager.removeAndPersist(source!, { local });
          effectApplied = true;
          await this.flushSettings(settings);
        } else if (source === undefined) {
          // An omitted source retains Pi's existing "update all" command.
          await manager.update();
          effectApplied = true;
        } else {
          // Pi's public update(source) intentionally updates every matching
          // scope. The RPC identifies one row, so use the public scoped install
          // seam to refresh only that row's user/project installation while
          // leaving its existing settings entry untouched.
          this.ensureConfiguredSource(manager, source, local);
          await manager.install(source, { local });
          effectApplied = true;
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
