import type { ExtensionHostActivity } from "../extensions/host/extension-presentation-store.js";

/** Tracks host-observable extension work without interpreting extension-owned state. */
export class ExtensionLifecycleCoordinator {
  private pendingCommands = 0;
  private pendingPrompts = 0;
  private readonly pendingPreflights = new Set<string>();
  /** Accepted owners that have not yet produced their one exact agent_start. */
  private readonly acceptedStarts = new Set<string>();
  /** Handles Pi emitting agent_start before its preflight callback resolves. */
  private readonly observedStarts = new Set<string>();
  private shutdownRequested = false;
  private drainRequested = false;
  private readonly permittedStartsAfterDrain = new Set<string>();
  private retired = false;

  constructor(
    private activity: ExtensionHostActivity,
    private readonly hasRuntimeWork: () => boolean = () => false,
  ) {}

  replaceActivity(activity: ExtensionHostActivity): void { this.activity = activity; }

  get hasPendingCommands(): boolean { return this.pendingCommands > 0; }
  get hasPendingPrompts(): boolean { return this.pendingPrompts > 0; }
  get hasPendingUI(): boolean { return this.activity.hasPendingInteraction || this.activity.hasPendingComponentFactory; }
  get pendingUICount(): number {
    return Number(this.activity.hasPendingInteraction)
      + Number(this.activity.hasPendingComponentFactory)
      + Number(this.activity.hasInputLease)
      + Number(this.activity.hasScheduledRender)
      + Number(this.activity.hasBlockingPresentation);
  }
  get hasRetainedPresentation(): boolean { return this.activity.hasRetainedPresentation; }
  get isShutdownRequested(): boolean { return this.shutdownRequested; }
  get isDraining(): boolean { return this.drainRequested; }
  /** Work that makes trust/resource mutation unsafe. Decorative state is excluded. */
  get preventsOperationalQuiescence(): boolean {
    return this.pendingCommands > 0 || this.pendingPrompts > 0 || this.hasPendingUI
      || this.activity.hasInputLease || this.activity.hasScheduledRender || this.activity.hasBlockingPresentation
      || this.hasRuntimeWork();
  }
  /** Automatic eviction also retains reconnect-visible presentation. */
  get preventsEviction(): boolean {
    return this.preventsOperationalQuiescence || this.hasRetainedPresentation || this.activity.hasMountedPresentation;
  }

  requestShutdown(): void { if (!this.retired) this.shutdownRequested = true; }
  beginDrain(): void {
    if (this.retired || this.drainRequested) return;
    this.drainRequested = true;
    for (const owner of this.pendingPreflights) this.permittedStartsAfterDrain.add(owner);
    for (const owner of this.acceptedStarts) this.permittedStartsAfterDrain.add(owner);
  }
  admitAgentStartDuringDrain(owner: string | undefined): boolean {
    if (owner === undefined) return !this.drainRequested;
    if (this.drainRequested && !this.permittedStartsAfterDrain.delete(owner)) return false;
    // Consume exactly one start for this owner. If Pi started before its callback,
    // resolvePreflight observes this latch and does not manufacture a second permit.
    this.pendingPreflights.delete(owner);
    this.acceptedStarts.delete(owner);
    this.observedStarts.add(owner);
    return true;
  }
  beginPreflight(owner: string): void {
    if (this.retired || this.drainRequested) throw new Error("Extension host is not accepting prompt preflight");
    if (this.pendingPreflights.has(owner) || this.acceptedStarts.has(owner)) {
      throw new Error("Extension prompt preflight owner is already active");
    }
    this.pendingPreflights.add(owner);
  }
  resolvePreflight(owner: string, accepted: boolean): void {
    this.pendingPreflights.delete(owner);
    this.permittedStartsAfterDrain.delete(owner);
    if (this.observedStarts.delete(owner) || !accepted || this.retired) return;
    this.acceptedStarts.add(owner);
    if (this.drainRequested) this.permittedStartsAfterDrain.add(owner);
  }
  cancelPreflight(owner: string): void {
    this.pendingPreflights.delete(owner);
    this.acceptedStarts.delete(owner);
    this.observedStarts.delete(owner);
    this.permittedStartsAfterDrain.delete(owner);
  }
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
    this.permittedStartsAfterDrain.clear();
    this.pendingPreflights.clear();
    this.acceptedStarts.clear();
    this.observedStarts.clear();
  }
}
