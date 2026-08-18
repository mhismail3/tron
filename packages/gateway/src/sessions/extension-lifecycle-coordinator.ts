import type { ExtensionHostActivity } from "../extensions/host/extension-presentation-store.js";

/** Tracks host-observable extension work without interpreting extension-owned state. */
export class ExtensionLifecycleCoordinator {
  private pendingCommands = 0;
  private pendingPrompts = 0;
  private pendingPreflights = 0;
  private shutdownRequested = false;
  private drainRequested = false;
  private permittedStartsAfterDrain = 0;
  private retired = false;

  constructor(
    private activity: ExtensionHostActivity,
    private readonly hasRuntimeWork: () => boolean = () => false,
  ) {}

  replaceActivity(activity: ExtensionHostActivity): void { this.activity = activity; }

  get hasPendingCommands(): boolean { return this.pendingCommands > 0; }
  get hasPendingPrompts(): boolean { return this.pendingPrompts > 0; }
  get hasPendingUI(): boolean { return this.activity.hasPendingInteraction || this.activity.hasPendingComponentFactory; }
  get hasRetainedPresentation(): boolean { return this.activity.hasRetainedPresentation; }
  get isShutdownRequested(): boolean { return this.shutdownRequested; }
  get isDraining(): boolean { return this.drainRequested; }
  /** Work that makes trust/resource mutation unsafe. Decorative state is excluded. */
  get preventsOperationalQuiescence(): boolean {
    return this.pendingCommands > 0 || this.pendingPrompts > 0 || this.hasPendingUI
      || this.activity.hasInputLease || this.activity.hasScheduledRender || this.activity.hasBlockingPresentation
      || this.shutdownRequested || this.hasRuntimeWork();
  }
  /** Automatic eviction also retains reconnect-visible presentation. */
  get preventsEviction(): boolean {
    return this.preventsOperationalQuiescence || this.hasRetainedPresentation || this.activity.hasMountedPresentation;
  }
  get preventsAdministrativeDrain(): boolean { return this.preventsOperationalQuiescence; }

  requestShutdown(): void { if (!this.retired) this.shutdownRequested = true; }
  beginDrain(): void {
    if (this.retired || this.drainRequested) return;
    this.drainRequested = true;
    this.permittedStartsAfterDrain = this.pendingPreflights;
  }
  admitAgentStartDuringDrain(): boolean {
    if (!this.drainRequested) return true;
    if (this.permittedStartsAfterDrain <= 0) return false;
    this.permittedStartsAfterDrain -= 1;
    return true;
  }
  beginPreflight(): void {
    if (this.retired || this.drainRequested) throw new Error("Extension host is not accepting prompt preflight");
    this.pendingPreflights += 1;
  }
  endPreflight(): void { this.pendingPreflights = Math.max(0, this.pendingPreflights - 1); }
  trackPrompt<T>(operation: Promise<T>, settled: () => void): Promise<T> {
    if (this.retired) return Promise.reject(new Error("Extension host epoch was retired"));
    this.pendingPrompts += 1;
    return operation.finally(() => { this.pendingPrompts = Math.max(0, this.pendingPrompts - 1); settled(); });
  }
  trackCommand<T>(operation: Promise<T>, settled: () => void): Promise<T> {
    if (this.retired) return Promise.reject(new Error("Extension host epoch was retired"));
    this.pendingCommands += 1;
    return operation.finally(() => { this.pendingCommands = Math.max(0, this.pendingCommands - 1); settled(); });
  }
  retire(): void {
    this.retired = true;
    this.shutdownRequested = false;
    this.drainRequested = false;
    this.permittedStartsAfterDrain = 0;
    this.pendingPreflights = 0;
  }
}
