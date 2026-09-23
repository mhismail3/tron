import { homedir } from "node:os";
import { DefaultResourceLoader, SettingsManager, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import { AsyncMutex } from "../util/async-mutex.js";
import type { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import type { AuthBroker } from "./auth-broker.js";

interface ProviderRegistration {
  providerId: string;
  extensionPath: string;
  register: () => void;
}

/** Owns user-scope Pi provider registrations for Gateway administration. */
export class GlobalProviderResources {
  private readonly mutex = new AsyncMutex();
  private readonly providersByExtension = new Map<string, Set<string>>();
  private readonly runtimeByExtension = new Map<string, ReturnType<DefaultResourceLoader["getExtensions"]>["runtime"]>();
  private activeRuntime: ReturnType<DefaultResourceLoader["getExtensions"]>["runtime"] | undefined;

  private constructor(
    private readonly loader: DefaultResourceLoader,
    private readonly modelRuntime: ModelRuntime,
    private readonly auth: AuthBroker,
    private readonly workRegistry: GatewayWorkRegistry | undefined,
    private readonly log: (level: "error" | "warning" | "info", message: string) => void,
    private readonly broadcast: () => void,
  ) {
    this.activeRuntime = loader.getExtensions().runtime;
  }

  static async create(options: {
    cwd: string;
    agentDir: string;
    modelRuntime: ModelRuntime;
    auth: AuthBroker;
    workRegistry?: GatewayWorkRegistry;
    log: (level: "error" | "warning" | "info", message: string) => void;
    broadcast: () => void;
  }): Promise<GlobalProviderResources> {
    const cwd = options.cwd || homedir();
    const settingsManager = SettingsManager.create(cwd, options.agentDir, { projectTrusted: false });
    const loader = new DefaultResourceLoader({ cwd, agentDir: options.agentDir, settingsManager });
    const resources = new GlobalProviderResources(
      loader,
      options.modelRuntime,
      options.auth,
      options.workRegistry,
      options.log,
      options.broadcast,
    );
    await resources.reload();
    return resources;
  }

  /** Reload only user/global resources. Project settings are deliberately untrusted. */
  requestReload(): void {
    this.auth.requestGlobalProviderRefresh(async () => {
      try {
        await this.reload();
      } catch (error) {
        this.log("error", `Global provider resources could not be reloaded: ${error instanceof Error ? error.message : String(error)}`);
      }
    });
  }

  private async reload(): Promise<void> {
    const work = this.workRegistry?.begin({
      kind: "administrative-provider-package-operation",
      hostEpoch: this.workRegistry.runtimeEpoch,
    });
    try {
      await this.mutex.run(async () => {
        const previousRuntime = this.activeRuntime;
        const previousRuntimes = new Set(this.runtimeByExtension.values());
        if (previousRuntime) previousRuntimes.add(previousRuntime);
        await this.loader.reload({ resolveProjectTrust: async () => false });
        const loaded = this.loader.getExtensions();
        const runtime = loaded.runtime;
        const registrations: ProviderRegistration[] = [
          ...runtime.pendingProviderRegistrations.map(({ name, config, extensionPath }) => ({
            providerId: name,
            extensionPath,
            register: () => this.modelRuntime.registerProvider(name, config),
          })),
          ...runtime.pendingNativeProviderRegistrations.map(({ provider, extensionPath }) => ({
            providerId: provider.id,
            extensionPath,
            register: () => this.modelRuntime.registerNativeProvider(provider),
          })),
        ];
        const nextOwners = new Map<string, Set<string>>();
        const failedPaths = new Set(loaded.errors.map(({ path }) => path));
        const failures: string[] = [];
        for (const registration of registrations) {
          try {
            registration.register();
            const owned = nextOwners.get(registration.extensionPath) ?? new Set<string>();
            owned.add(registration.providerId);
            nextOwners.set(registration.extensionPath, owned);
          } catch (error) {
            failures.push(`Extension provider ${registration.providerId} from ${registration.extensionPath} failed to register: ${error instanceof Error ? error.message : String(error)}`);
            const previous = this.providersByExtension.get(registration.extensionPath);
            if (previous?.has(registration.providerId)) {
              const owned = nextOwners.get(registration.extensionPath) ?? new Set<string>();
              owned.add(registration.providerId);
              nextOwners.set(registration.extensionPath, owned);
            }
          }
        }
        // A failed extension reload keeps its last working provider registration.
        for (const [path, providerIds] of this.providersByExtension) {
          if (failedPaths.has(path)) nextOwners.set(path, new Set([...(nextOwners.get(path) ?? []), ...providerIds]));
        }
        const retainedProviderIds = new Set([...nextOwners.values()].flatMap((ids) => [...ids]));
        const previousProviderIds = new Set([...this.providersByExtension.values()].flatMap((ids) => [...ids]));
        for (const providerId of previousProviderIds) {
          if (!retainedProviderIds.has(providerId)) this.modelRuntime.unregisterProvider(providerId);
        }
        runtime.pendingProviderRegistrations = [];
        runtime.pendingNativeProviderRegistrations = [];
        this.providersByExtension.clear();
        for (const [path, providerIds] of nextOwners) {
          this.providersByExtension.set(path, providerIds);
          if (!failedPaths.has(path)) this.runtimeByExtension.set(path, runtime);
        }
        for (const path of [...this.runtimeByExtension.keys()]) {
          if (!nextOwners.has(path)) this.runtimeByExtension.delete(path);
        }
        this.activeRuntime = runtime;
        const retainedRuntimes = new Set(this.runtimeByExtension.values());
        retainedRuntimes.add(runtime);
        for (const previous of previousRuntimes) {
          if (!retainedRuntimes.has(previous)) previous.invalidate("Global provider extension resources were reloaded");
        }
        const result = await this.modelRuntime.refresh({ allowNetwork: false });
        for (const failure of failures) this.log("error", failure);
        for (const diagnostic of loaded.errors) this.log("error", `Global extension ${diagnostic.path} failed to load: ${diagnostic.error}`);
        for (const [providerId, error] of result.errors) this.log("warning", `Global provider ${providerId} refresh failed: ${error.message}`);
        this.broadcast();
      });
    } finally {
      work?.settle();
    }
  }
}
