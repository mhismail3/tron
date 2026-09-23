import { homedir } from "node:os";
import { DefaultPackageManager, DefaultResourceLoader, SettingsManager, type ModelRuntime } from "@earendil-works/pi-coding-agent";
import { AsyncMutex } from "../util/async-mutex.js";
import type { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import type { AuthBroker } from "./auth-broker.js";

type ExtensionRuntime = ReturnType<DefaultResourceLoader["getExtensions"]>["runtime"];
type RegistrationKind = "provider" | "native";

interface ProviderRegistration {
  providerId: string;
  extensionPath: string;
  kind: RegistrationKind;
  runtime: ExtensionRuntime;
  register: () => void;
}

/** Owns user-scope Pi provider registrations for Gateway administration. */
export class GlobalProviderResources {
  private readonly mutex = new AsyncMutex();
  private providerContributions: ProviderRegistration[] = [];
  private activeRuntime: ExtensionRuntime | undefined;
  private requestedRevision = 0;
  private appliedRevision = 0;

  private constructor(
    private readonly loader: DefaultResourceLoader,
    private readonly packageManager: DefaultPackageManager,
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
    const packageManager = new DefaultPackageManager({ cwd, agentDir: options.agentDir, settingsManager });
    const resources = new GlobalProviderResources(
      loader,
      packageManager,
      options.modelRuntime,
      options.auth,
      options.workRegistry,
      options.log,
      options.broadcast,
    );
    resources.requestedRevision = 1;
    await resources.reload();
    return resources;
  }

  /** Serialize catalog reads against extension replacement so paged snapshots stay coherent. */
  withStableSnapshot<T>(read: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    return this.mutex.run(read, signal);
  }

  /** Reload only user/global resources. Project settings are deliberately untrusted. */
  requestReload(): void {
    this.requestedRevision += 1;
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
        while (this.appliedRevision < this.requestedRevision) {
          const revision = this.requestedRevision;
          await this.reloadOne();
          this.appliedRevision = revision;
        }
      });
    } finally {
      work?.settle();
    }
  }

  private async reloadOne(): Promise<void> {
    const previous = this.providerContributions;
    const previousRuntimes = new Set(previous.map(({ runtime }) => runtime));
    if (this.activeRuntime) previousRuntimes.add(this.activeRuntime);
    await this.loader.reload({ resolveProjectTrust: async () => false });
    const loaded = this.loader.getExtensions();
    const runtime = loaded.runtime;
    const freshProviders: ProviderRegistration[] = runtime.pendingProviderRegistrations.map(({ name, config, extensionPath }) => ({
      providerId: name,
      extensionPath,
      kind: "provider",
      runtime,
      register: () => this.modelRuntime.registerProvider(name, config),
    }));
    const freshNativeProviders: ProviderRegistration[] = runtime.pendingNativeProviderRegistrations.map(({ provider, extensionPath }) => ({
      providerId: provider.id,
      extensionPath,
      kind: "native",
      runtime,
      register: () => this.modelRuntime.registerNativeProvider(provider),
    }));
    const failedPaths = new Set(loaded.errors.map(({ path }) => path));
    const failures: string[] = [];

    // ModelRuntime.registerProvider deliberately merges re-registrations. Remove each
    // prior global extension layer, then replay every current contribution in the same
    // provider-then-native order used by createAgentSessionServices. This makes removal
    // and reorder equivalent to a fresh SDK load without disturbing built-in providers.
    const previousProviderIds = new Set(previous.map(({ providerId }) => providerId));
    for (const providerId of previousProviderIds) this.modelRuntime.unregisterProvider(providerId);
    // DefaultResourceLoader does not expose the combined package/local resource path
    // order. Resolve the same authoritative set through the SDK's public package API;
    // skip missing packages here because loader.reload already owns installation policy.
    const resolved = await this.packageManager.resolve(async () => "skip");
    const extensionOrder = resolved.extensions.filter(({ enabled }) => enabled).map(({ path }) => path);
    for (const path of [...loaded.errors.map(({ path }) => path), ...freshProviders.map(({ extensionPath }) => extensionPath), ...freshNativeProviders.map(({ extensionPath }) => extensionPath), ...previous.map(({ extensionPath }) => extensionPath)]) {
      if (!extensionOrder.includes(path)) extensionOrder.push(path);
    }
    const nextContributions = [
      ...this.replayContributions("provider", freshProviders, previous, extensionOrder, failedPaths, failures),
      ...this.replayContributions("native", freshNativeProviders, previous, extensionOrder, failedPaths, failures),
    ];

    runtime.pendingProviderRegistrations = [];
    runtime.pendingNativeProviderRegistrations = [];
    this.providerContributions = nextContributions;
    this.activeRuntime = runtime;
    const retainedRuntimes = new Set(nextContributions.map(({ runtime: owner }) => owner));
    retainedRuntimes.add(runtime);
    for (const priorRuntime of previousRuntimes) {
      if (!retainedRuntimes.has(priorRuntime)) priorRuntime.invalidate("Global provider extension resources were reloaded");
    }

    // Provider registration itself updates the synchronous catalog. Always notify after
    // that commit, even if the SDK's subsequent availability refresh rejects.
    try {
      const result = await this.modelRuntime.refresh({ allowNetwork: false });
      for (const failure of failures) this.log("error", failure);
      for (const diagnostic of loaded.errors) this.log("error", `Global extension ${diagnostic.path} failed to load: ${diagnostic.error}`);
      for (const [providerId, error] of result.errors) this.log("warning", `Global provider ${providerId} refresh failed: ${error.message}`);
    } finally {
      this.broadcast();
    }
  }

  private replayContributions(
    kind: RegistrationKind,
    fresh: ProviderRegistration[],
    previous: ProviderRegistration[],
    extensionOrder: string[],
    failedPaths: Set<string>,
    failures: string[],
  ): ProviderRegistration[] {
    const oldByKey = new Map(previous.filter((registration) => registration.kind === kind)
      .map((registration) => [`${registration.extensionPath}\0${registration.providerId}`, registration]));
    const freshByPath = new Map<string, ProviderRegistration[]>();
    for (const registration of fresh) {
      const registrations = freshByPath.get(registration.extensionPath) ?? [];
      registrations.push(registration);
      freshByPath.set(registration.extensionPath, registrations);
    }
    const accepted: ProviderRegistration[] = [];
    const register = (registration: ProviderRegistration, replacement = false): void => {
      try {
        registration.register();
        accepted.push(registration);
      } catch (error) {
        failures.push(`Extension ${replacement ? "retained" : "provider"} ${registration.providerId} from ${registration.extensionPath} failed to register: ${error instanceof Error ? error.message : String(error)}`);
        if (replacement) return;
        const prior = oldByKey.get(`${registration.extensionPath}\0${registration.providerId}`);
        if (prior) register(prior, true);
      }
    };
    for (const extensionPath of extensionOrder) {
      const freshAtPath = freshByPath.get(extensionPath) ?? [];
      const attemptedPrior = new Set<string>();
      for (const registration of freshAtPath) {
        const key = `${registration.extensionPath}\0${registration.providerId}`;
        attemptedPrior.add(key);
        register(registration);
      }
      if (failedPaths.has(extensionPath)) {
        for (const prior of previous) {
          const key = `${prior.extensionPath}\0${prior.providerId}`;
          if (prior.kind === kind && prior.extensionPath === extensionPath && !attemptedPrior.has(key)) register(prior, true);
        }
      }
    }
    return accepted;
  }
}
