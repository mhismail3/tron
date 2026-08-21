import type { Component, TUI } from "@earendil-works/pi-tui";
import type { Theme } from "@earendil-works/pi-coding-agent";
import { RecordingComponent, type ComponentDiagnostic } from "./recording-component.js";
import { boundedDisplayError } from "./terminal-sanitizer.js";

export type RemoteComponentFactory = (tui: TUI, theme: Theme) => Component | Promise<Component>;
export type ComponentRecordState = "pending" | "mounted" | "failed" | "retired" | "disposed";
export interface ComponentRecord { readonly key: string; readonly hostEpoch: string; readonly generation: number; readonly recording: RecordingComponent; state: ComponentRecordState; factoryPending: boolean }

export interface ComponentRegistryOptions {
  readonly hostEpoch: string;
  readonly tui: TUI;
  readonly theme: Theme;
  readonly onMount: (record: ComponentRecord) => void;
  readonly onRetire: (record: ComponentRecord) => void;
  readonly onDiagnostic?: (diagnostic: ComponentDiagnostic) => void;
  readonly onFactoryFailure?: (key: string, generation: number, diagnostic: ComponentDiagnostic) => void;
  readonly onFactorySettled?: (key: string, generation: number) => void;
  readonly onActivity?: (pendingFactories: number) => void;
  readonly maxRecords?: number;
}

/** Bounded identity/generation ownership for retained Pi component factories. */
export class ComponentRegistry {
  private readonly records = new Map<string, ComponentRecord>();
  private readonly generations = new Map<string, number>();
  private pendingFactories = 0;
  private retired = false;
  constructor(private readonly options: ComponentRegistryOptions) {}
  get pendingFactoryCount(): number { return this.pendingFactories; }
  get recordCount(): number { return this.records.size; }
  has(key: string): boolean { return this.records.has(key); }
  currentGeneration(key: string): number | undefined { return this.generations.get(key); }
  get mountedRecords(): readonly ComponentRecord[] { return [...this.records.values()].filter((record) => record.state === "mounted"); }

  set(key: string, factory: RemoteComponentFactory): boolean {
    // Reject before touching the current generation. In particular, a retired
    // registry must not remove an existing record while rejecting a late
    // replacement.
    if (this.retired) return false;
    const maximumRecords = this.options.maxRecords ?? 24;
    if (this.pendingFactories >= maximumRecords) return false;
    if (!this.records.has(key) && this.records.size >= maximumRecords) return false;
    this.remove(key);
    const generation = (this.generations.get(key) ?? 0) + 1;
    this.generations.set(key, generation);
    const record = { key, hostEpoch: this.options.hostEpoch, generation, recording: undefined as unknown as RecordingComponent, state: "pending" as ComponentRecordState, factoryPending: true };
    this.records.set(key, record);
    this.pendingFactories += 1;
    this.options.onActivity?.(this.pendingFactories);
    let result: Component | Promise<Component>;
    try { result = factory(this.options.tui, this.options.theme); }
    catch (error) {
      this.finishFactory(record); record.state = "failed";
      this.reportFailure(record, { code: "render-failed", message: boundedDisplayError(error) });
      this.options.onFactorySettled?.(key, generation);
      this.releaseGeneration(record);
      return true;
    }
    Promise.resolve(result).then((component) => {
      const current = this.owns(record);
      this.finishFactory(record);
      this.options.onFactorySettled?.(key, generation);
      this.releaseGeneration(record);
      if (!current || !component || typeof component.render !== "function" || typeof component.invalidate !== "function") {
        if (component && typeof component.render === "function") this.disposeLate(component);
        if (current) { record.state = "failed"; this.reportFailure(record, { code: "render-invalid", message: "Component factory returned an invalid component" }); }
        return;
      }
      record.recording = new RecordingComponent(component, this.options.onDiagnostic ? { onDiagnostic: this.options.onDiagnostic } : {});
      if (!this.isCurrent(record)) { record.state = "retired"; record.recording.dispose(); record.state = "disposed"; return; }
      record.state = "mounted";
      this.options.onMount(record);
    }, (error) => {
      this.finishFactory(record);
      this.options.onFactorySettled?.(key, generation);
      this.releaseGeneration(record);
      if (this.isCurrent(record)) { record.state = "failed"; this.reportFailure(record, { code: "render-failed", message: boundedDisplayError(error) }); }
    });
    return true;
  }

  remove(key: string): void {
    const record = this.records.get(key); if (!record) return;
    this.records.delete(key);
    this.retire(record);
    if (!record.factoryPending && this.generations.get(key) === record.generation) this.generations.delete(key);
  }
  retireAll(): void { this.retired = true; for (const key of [...this.records.keys()]) this.remove(key); this.records.clear(); this.options.onActivity?.(this.pendingFactories); }
  private reportFailure(record: ComponentRecord, diagnostic: ComponentDiagnostic): void {
    if (!this.retired && this.records.get(record.key) === record && this.options.onFactoryFailure) this.options.onFactoryFailure(record.key, record.generation, diagnostic);
    else this.options.onDiagnostic?.(diagnostic);
  }
  private finishFactory(record: ComponentRecord): void {
    if (!record.factoryPending) return;
    record.factoryPending = false;
    this.pendingFactories = Math.max(0, this.pendingFactories - 1);
    this.options.onActivity?.(this.pendingFactories);
  }
  private releaseGeneration(record: ComponentRecord): void {
    if (!this.records.has(record.key) && this.generations.get(record.key) === record.generation) this.generations.delete(record.key);
  }
  private owns(record: ComponentRecord): boolean { return !this.retired && this.records.get(record.key) === record && record.hostEpoch === this.options.hostEpoch; }
  private isCurrent(record: ComponentRecord): boolean { return this.owns(record) && record.state === "pending"; }
  private retire(record: ComponentRecord): void {
    if (record.state === "retired" || record.state === "disposed") return;
    record.state = "retired";
    this.options.onRetire(record);
    if (record.recording) { record.recording.dispose(); record.state = "disposed"; }
  }
  private disposeLate(component: Component): void { try { (component as Component & { dispose?: () => void }).dispose?.(); } catch (error) { this.options.onDiagnostic?.({ code: "dispose-failed", message: boundedDisplayError(error) }); } }
}
