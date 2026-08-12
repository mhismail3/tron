import { randomUUID } from "node:crypto";
import { DefaultPackageManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { JsonValue } from "../protocol/types.js";
import type { TrustService } from "./trust-service.js";
import { AsyncMutex } from "../util/async-mutex.js";

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
    return { packages: manager.listConfiguredPackages(), resources: await manager.resolve(async () => "skip") };
  }

  async checkUpdates(cwd: string): Promise<unknown> {
    const manager = await this.manager(cwd, false);
    return { updates: await manager.checkForAvailableUpdates() };
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
