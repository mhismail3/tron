import { randomUUID } from "node:crypto";
import {
  DefaultPackageManager,
  SettingsManager,
  type ResolvedPaths,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { TrustService } from "./trust-service.js";
import { AsyncMutex } from "../util/async-mutex.js";

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
  ) {}

  private async manager(cwdInput: string, requireProjectTrust: boolean): Promise<DefaultPackageManager> {
    const trust = requireProjectTrust
      ? await this.trust.requireResolved(cwdInput)
      : await this.trust.inspect(cwdInput).then((inspection) => ({ cwd: inspection.cwd, trusted: inspection.effectiveDecision === true }));
    const settings = SettingsManager.create(trust.cwd, this.agentDir, { projectTrusted: trust.trusted });
    return new DefaultPackageManager({ cwd: trust.cwd, agentDir: this.agentDir, settingsManager: settings });
  }

  async list(cwd: string): Promise<unknown> {
    const manager = await this.manager(cwd, false);
    const packages = manager.listConfiguredPackages();
    const resources = await manager.resolve(async () => "skip");
    validatePackageInventory(packages, resources);
    return { packages, resources };
  }

  async checkUpdates(cwd: string): Promise<unknown> {
    const manager = await this.manager(cwd, false);
    const updates = await manager.checkForAvailableUpdates();
    validatePackageUpdates(updates);
    return { updates };
  }

  async mutate(action: "install" | "remove" | "update", source: string | undefined, cwd: string, local: boolean): Promise<{ operationId: string }> {
    return this.mutex.run(async () => {
      const operationId = randomUUID();
      const manager = await this.manager(cwd, local);
      manager.setProgressCallback((event) => this.broadcast("packages.progress", { operationId, event } as unknown as JsonValue));
      try {
        if (action === "install") await manager.installAndPersist(source!, { local });
        else if (action === "remove") await manager.removeAndPersist(source!, { local });
        else await manager.update(source);
        this.broadcast("packages.completed", { operationId, success: true });
      } catch (error) {
        this.broadcast("packages.completed", {
          operationId,
          success: false,
          error: error instanceof Error ? error.message : String(error),
        });
        throw error;
      } finally {
        manager.setProgressCallback(undefined);
      }
      return { operationId };
    });
  }
}
