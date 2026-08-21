import type { ExtensionUIContext, KeybindingsManager as PiKeybindingsManager } from "@earendil-works/pi-coding-agent";
import { Theme } from "@earendil-works/pi-coding-agent";
import {
  KeybindingsManager as TuiKeybindingsManager,
  TUI_KEYBINDINGS,
  type Component,
  type OverlayHandle,
  type OverlayOptions,
  type TUI,
} from "@earendil-works/pi-tui";
import type { ExtensionFrame, ExtensionSurface } from "../../protocol/types.js";
import { CapturingTuiMainScreen } from "./capturing-tui-main-screen.js";
import { ComponentRegistry, type ComponentRecord, type RemoteComponentFactory } from "./component-registry.js";
import { ExtensionPresentationStore } from "./extension-presentation-store.js";
import { boundedExtensionFrame, parseExtensionFrame } from "./frame-parser.js";
import { InMemoryTerminal } from "./in-memory-terminal.js";
import { type ComponentDiagnostic } from "./recording-component.js";
import { boundedDisplayError, stripTerminalControls } from "./terminal-sanitizer.js";
import { currentExtensionOwner } from "../owner-attribution.js";

export interface RemotePiExtensionHostOptions {
  columns?: number;
  rows?: number;
  /** Production RPC has no truthful native path for blocking component UI. */
  enableBlockingCustom?: boolean;
}
export const MAX_HOST_COMPONENTS = 24;
export const MAX_HOST_DIAGNOSTICS = 16;
const MAX_HOST_KEY_BYTES = 256;

export function widgetSurfaceId(key: string): string {
  return `widget:${Buffer.from(key, "utf8").toString("base64url")}`;
}

type SurfacePlacement = "aboveEditor" | "belowEditor" | "fullscreen";
type SurfaceKind = "widget" | "custom";
type SurfaceLifecycle = "retained" | "blocking";
type CustomComponent = Component & { dispose?(): void };
type CustomFactory<T> = (
  tui: TUI,
  theme: Theme,
  keybindings: PiKeybindingsManager,
  done: (result: T) => void,
) => CustomComponent | Promise<CustomComponent>;

interface SurfaceMeta {
  owner?: { source: string };
  kind: SurfaceKind;
  placement: SurfacePlacement;
  lifecycle: SurfaceLifecycle;
  inputMode: "none" | "keys";
  callId?: string;
}

type FoundationExtensionUIContext = Omit<ExtensionUIContext, "custom"> & {
  custom: <T>(factory: CustomFactory<T>, options?: CustomOptions) => Promise<T>;
};

interface CustomOptions {
  overlay?: boolean;
  overlayOptions?: OverlayOptions | (() => OverlayOptions);
  onHandle?: (handle: OverlayHandle) => void;
}

interface CustomCall<T> {
  readonly key: string;
  readonly resolve: (value: T) => void;
  readonly reject: (error: unknown) => void;
  settled: boolean;
  factorySettled: boolean;
  retired: boolean;
}

/**
 * Per-presentation-epoch Pi host. RuntimeSlot binds this context in RPC mode so
 * retained component widgets can publish bounded read-only frames while every
 * semantic API continues through SemanticUIBroker and the same presentation
 * store. Blocking custom and overlay UI remain disabled in production.
 */
export class RemotePiExtensionHost {
  private readonly baseContext: ExtensionUIContext;
  private terminal?: InMemoryTerminal;
  private screen?: CapturingTuiMainScreen;
  private tuiProxy?: TUI;
  private keybindings?: PiKeybindingsManager;
  private registry?: ComponentRegistry;
  private renderQueued = false;
  private renderActive = false;
  private retired = false;
  private readonly placements = new Map<string, SurfacePlacement>();
  private readonly surfaceDigests = new Map<string, string>();
  private readonly surfaceMeta = new Map<string, SurfaceMeta>();
  private customCall: CustomCall<unknown> | undefined;
  private callSequence = 0;
  private pendingDiagnostics: ComponentDiagnostic[] = [];
  private readonly pendingSurfaces = new Map<string, ExtensionSurface>();
  private readonly pendingRemovals = new Set<string>();

  constructor(
    readonly semantic: { presentation: ExtensionPresentationStore; context(): ExtensionUIContext },
    private readonly options: RemotePiExtensionHostOptions = {},
  ) {
    this.baseContext = semantic.context();
  }

  get presentation(): ExtensionPresentationStore { return this.semantic.presentation; }
  get hostEpoch(): string { return this.presentation.hostEpoch; }
  get isTuiStarted(): boolean { return this.screen !== undefined; }
  get mountedComponentCount(): number { return this.registry?.mountedRecords.length ?? 0; }
  get pendingCustomCall(): boolean { return this.customCall !== undefined; }

  /** Re-render retained component surfaces after a native semantic UI mutation. */
  rerender(): void { if (!this.retired) this.requestRender(true); }

  context(): FoundationExtensionUIContext {
    const host = this;
    return {
      ...this.baseContext,
      setToolsExpanded(expanded) {
        host.baseContext.setToolsExpanded(expanded);
        host.requestRender(true);
      },
      setWidget(key, content, options) {
        if (typeof key !== "string" || !key || Buffer.byteLength(key, "utf8") > MAX_HOST_KEY_BYTES) {
          host.recordDiagnostic({ code: "render-invalid", message: "Widget key exceeds the bounded extension-host limit" });
          return;
        }
        if (typeof content !== "function") {
          host.removeComponent(key);
          host.baseContext.setWidget(key, content, options);
          return;
        }
        const placement = options?.placement === "belowEditor" ? "belowEditor" : "aboveEditor";
        if (!host.admitComponent(key)) return;
        const previousPlacement = host.placements.get(key);
        const previousMeta = host.surfaceMeta.get(key);
        host.placements.set(key, placement);
        const owner = currentExtensionOwner();
        host.surfaceMeta.set(key, { kind: "widget", placement, lifecycle: "retained", inputMode: "none", ...(owner ? { owner: { source: owner.source } } : {}) });
        // Registry admission may reject a replacement while a bounded factory
        // is pending. Restore metadata when that admission does not commit.
        if (!host.mountComponent(key, content as RemoteComponentFactory)) {
          if (previousPlacement === undefined) host.placements.delete(key); else host.placements.set(key, previousPlacement);
          if (previousMeta === undefined) host.surfaceMeta.delete(key); else host.surfaceMeta.set(key, previousMeta);
        }
      },
      custom<T>(factory: CustomFactory<T>, options?: CustomOptions) {
        return host.mountCustom(factory, options);
      },
    };
  }

  private admitComponent(key: string): boolean {
    if (this.retired) return false;
    if (this.registry?.has(key)) return true;
    if ((this.registry?.recordCount ?? 0) >= MAX_HOST_COMPONENTS || this.surfaceMeta.size >= MAX_HOST_COMPONENTS) {
      this.recordDiagnostic({ code: "render-invalid", message: "Extension component capacity is full" });
      return false;
    }
    return true;
  }

  private ensureTui(): { tui: TUI; theme: Theme; keybindings: PiKeybindingsManager } {
    if (this.retired) throw new Error("Extension host epoch was retired");
    if (this.screen && this.tuiProxy && this.keybindings) return { tui: this.tuiProxy, theme: this.baseContext.theme as Theme, keybindings: this.keybindings };
    this.terminal = new InMemoryTerminal(this.options.columns, this.options.rows);
    // pi-coding-agent's public callback type extends the public pi-tui
    // manager with settings helpers. The direct host is intentionally
    // settings-neutral; the pi-tui manager is the concrete public object and
    // is structurally compatible for documented key lookup operations.
    this.keybindings = new TuiKeybindingsManager(TUI_KEYBINDINGS) as unknown as PiKeybindingsManager;
    this.screen = new CapturingTuiMainScreen(this.terminal, {
      onRender: () => this.publishCapturedSurfaces(),
      onRenderComplete: (error) => this.finishRender(error),
      onDiagnostic: (diagnostic) => this.recordDiagnostic(diagnostic),
    });
    const screen = this.screen;
    const host = this;
    this.tuiProxy = new Proxy(screen as TUI, {
      get(target, property, receiver) {
        if (property === "requestRender") return (force?: boolean) => host.requestRender(force);
        const value = Reflect.get(target, property, receiver);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    this.registry = new ComponentRegistry({
      hostEpoch: this.hostEpoch,
      tui: this.tuiProxy,
      theme: this.baseContext.theme as Theme,
      maxRecords: MAX_HOST_COMPONENTS,
      onMount: (record) => this.mountRecord(record),
      onRetire: (record) => this.retireRecord(record),
      onFactoryFailure: (key, generation, diagnostic) => this.publishFactoryFailure(key, generation, diagnostic),
      onFactorySettled: (key, generation) => this.factorySettled(key, generation),
      onDiagnostic: (diagnostic) => this.recordDiagnostic(diagnostic),
      onActivity: (count) => { if (!this.retired) this.presentation.setPendingComponentFactories(count); },
    });
    this.markRenderScheduled();
    screen.start();
    return { tui: this.tuiProxy, theme: this.baseContext.theme as Theme, keybindings: this.keybindings };
  }

  private mountComponent(key: string, factory: RemoteComponentFactory): boolean {
    const { tui } = this.ensureTui();
    const admitted = this.registry?.set(key, factory) ?? false;
    if (!admitted) this.recordDiagnostic({ code: "render-invalid", message: "Extension component capacity is full" });
    void tui;
    return admitted;
  }

  private mountCustom<T>(factory: CustomFactory<T>, options?: CustomOptions): Promise<T> {
    if (this.retired) return Promise.reject(new Error("Extension host epoch was retired"));
    if (this.options.enableBlockingCustom === false) {
      const error = new Error("Blocking component UI is deferred in RPC mode");
      this.recordDiagnostic({ code: "render-invalid", message: error.message });
      return Promise.reject(error);
    }
    if (options?.overlay === true) {
      const error = new Error("Overlay extension UI is deferred at the foundation checkpoint");
      this.recordDiagnostic({ code: "render-invalid", message: error.message });
      return Promise.reject(error);
    }
    if (this.customCall) {
      const error = new Error("Only one blocking custom extension UI call is admitted per host epoch");
      this.recordDiagnostic({ code: "render-invalid", message: error.message });
      return Promise.reject(error);
    }
    if (!this.admitComponent(`custom:${this.callSequence + 1}`)) return Promise.reject(new Error("Extension component capacity is full"));
    const { tui, theme, keybindings } = this.ensureTui();
    const callId = `c${++this.callSequence}`;
    const key = `custom:${callId}`;
    let call!: CustomCall<T>;
    const result = new Promise<T>((resolve, reject) => {
      call = { key, resolve, reject, settled: false, factorySettled: false, retired: false };
      this.customCall = call as CustomCall<unknown>;
    });
    const owner = currentExtensionOwner();
    this.surfaceMeta.set(key, { kind: "custom", placement: "fullscreen", lifecycle: "blocking", inputMode: "keys", callId, ...(owner ? { owner: { source: owner.source } } : {}) });
    const done = (value: T): void => this.finishCustom(key, value, undefined);
    const customFactory: RemoteComponentFactory = () => factory(tui, theme, keybindings, done);
    if (!this.registry?.set(key, customFactory)) {
      // No factory callback will settle a rejected admission, so release the
      // metadata transaction here rather than leaving an orphan blocking
      // surface behind.
      call.factorySettled = true;
      this.failCustom(key, new Error("Extension component capacity is full"));
    }
    return result;
  }

  private mountRecord(record: ComponentRecord): void {
    if (!this.screen || record.state !== "mounted") return;
    const meta = this.surfaceMeta.get(record.key);
    if (!meta) return;
    try {
      this.screen.addChild(record.recording);
      if (meta.kind === "custom") this.screen.setFocus(record.recording);
      this.screen.renderNow(true);
    } catch (error) {
      this.failCustom(record.key, error);
      this.registry?.remove(record.key);
    }
  }

  private retireRecord(record: ComponentRecord): void {
    try { if (record.recording) this.screen?.removeChild(record.recording); }
    catch (error) { this.recordDiagnostic({ code: "dispose-failed", message: boundedDisplayError(error) }); }
    this.removeSurface(this.surfaceId(record.key));
    if (record.key.startsWith("custom:")) this.failCustom(record.key, new Error("Extension custom UI was retired"));
  }

  private factorySettled(key: string, generation: number): void {
    const call = this.customCall;
    if (!call || call.key !== key || this.registry?.currentGeneration(key) !== generation) return;
    call.factorySettled = true;
    this.releaseCustomIfSettled(call);
  }

  private finishCustom<T>(key: string, value: T, error?: unknown): void {
    const call = this.customCall as CustomCall<T> | undefined;
    if (!call || call.key !== key || call.settled || call.retired) return;
    call.settled = true;
    if (error === undefined) call.resolve(value as T); else call.reject(error);
    this.registry?.remove(key);
    this.removeSurface(key);
    this.releaseCustomIfSettled(call as CustomCall<unknown>);
  }

  private releaseCustomIfSettled(call: CustomCall<unknown>): void {
    if (!call.settled || !call.factorySettled) return;
    if (this.customCall === call) this.customCall = undefined;
    this.surfaceMeta.delete(call.key);
  }

  private failCustom(key: string, error: unknown): void {
    const call = this.customCall;
    if (!call || call.key !== key || call.settled) return;
    this.recordDiagnostic({ code: "render-failed", message: boundedDisplayError(error) });
    this.finishCustom(key, undefined, error);
  }

  private surfaceId(key: string, kind = this.surfaceMeta.get(key)?.kind): string {
    if (kind === "custom") return key;
    // Opaque extension keys must never share identity with reserved surface
    // prefixes or with another key. Base64url is bounded to 4/3 of the input
    // bytes and contains no protocol separators.
    return widgetSurfaceId(key);
  }

  private removeComponent(key: string): void {
    this.registry?.remove(key);
    this.placements.delete(key);
    this.surfaceMeta.delete(key);
    this.removeSurface(this.surfaceId(key));
  }

  private markRenderScheduled(): void {
    if (this.retired || this.renderQueued) return;
    this.renderQueued = true;
    this.presentation.setScheduledRenders(1);
  }

  private finishRender(error?: unknown): void {
    this.renderQueued = false;
    this.renderActive = false;
    this.presentation.setScheduledRenders(0);
    if (error) this.recordDiagnostic({ code: "render-failed", message: boundedDisplayError(error) });
  }

  requestRender(force = false): void {
    if (this.retired || !this.screen || this.renderActive) return;
    if (this.renderQueued && !force) return;
    this.markRenderScheduled();
    this.screen.requestRender(force);
  }

  resize(columns: number, rows: number): boolean {
    if (!this.terminal || this.retired) return false;
    const changed = this.terminal.resize(columns, rows);
    if (changed) this.markRenderScheduled();
    return changed;
  }

  private publishCapturedSurfaces(): void {
    if (this.retired || !this.registry || !this.terminal) return;
    this.renderActive = true;
    for (const record of this.registry.mountedRecords) {
      const meta = this.surfaceMeta.get(record.key);
      if (!meta) continue;
      const capture = record.recording.capture;
      if (!capture) continue;
      const parsed = parseExtensionFrame(capture.lines);
      for (const diagnostic of parsed.diagnostics) this.recordDiagnostic({ code: diagnostic.code as ComponentDiagnostic["code"], message: diagnostic.message });
      const frame = { ...parsed.frame, lines: parsed.frame.lines.map((line) => ({ plainText: line.plainText, runs: line.runs.map((run) => ({ text: run.text, style: { ...run.style } })) })), width: this.terminal.columns, height: parsed.frame.lines.length };
      const id = this.surfaceId(record.key);
      this.stageSurface({ id, kind: meta.kind, placement: meta.placement, lifecycle: meta.lifecycle, revision: this.nextRevision(id), focused: meta.kind === "custom", inputMode: meta.inputMode, frame,
        ...(meta.owner ? { provenance: { source: meta.owner.source } } : {}) });
    }
    this.flushPresentation();
  }

  private nextRevision(id: string): number {
    const pending = this.pendingSurfaces.get(id);
    if (pending) return pending.revision;
    return (this.presentation.state().surfaces.find((surface) => surface.id === id)?.revision ?? 0) + 1;
  }

  private stageSurface(surface: ExtensionSurface): void {
    const digest = JSON.stringify({ frame: surface.frame, placement: surface.placement, focused: surface.focused, inputMode: surface.inputMode });
    if (this.surfaceDigests.get(surface.id) === digest && !this.pendingSurfaces.has(surface.id)) return;
    const existing = this.pendingSurfaces.get(surface.id);
    this.pendingSurfaces.set(surface.id, { ...surface, revision: existing?.revision ?? surface.revision });
    this.pendingRemovals.delete(surface.id);
  }

  private flushPresentation(): boolean {
    if (this.retired) return false;
    const surfaces = [...this.pendingSurfaces.values()];
    const removals = [...this.pendingRemovals];
    const diagnostics = this.pendingDiagnostics.slice(0, 8);
    if (surfaces.length === 0 && removals.length === 0 && diagnostics.length === 0) return true;
    try {
      this.presentation.transact((draft) => {
        if (removals.length) draft.surfaces = draft.surfaces.filter((surface) => !removals.includes(surface.id));
        for (const surface of surfaces) {
          const index = draft.surfaces.findIndex((candidate) => candidate.id === surface.id);
          if (index < 0) draft.surfaces.push(surface); else draft.surfaces[index] = surface;
        }
        for (const diagnostic of diagnostics) draft.diagnostics.push({ code: `component.${diagnostic.code}`, message: diagnostic.message });
        if (draft.diagnostics.length > 64) draft.diagnostics.splice(0, draft.diagnostics.length - 64);
      });
      for (const surface of surfaces) {
        this.surfaceDigests.set(surface.id, JSON.stringify({ frame: surface.frame, placement: surface.placement, focused: surface.focused, inputMode: surface.inputMode }));
        this.pendingSurfaces.delete(surface.id);
      }
      for (const id of removals) { this.pendingRemovals.delete(id); this.surfaceDigests.delete(id); }
      this.pendingDiagnostics.splice(0, diagnostics.length);
      return true;
    } catch (error) {
      if (this.pendingDiagnostics.length < MAX_HOST_DIAGNOSTICS) this.pendingDiagnostics.push({ code: "render-failed", message: boundedDisplayError(error) });
      return false;
    }
  }

  private publishFactoryFailure(key: string, generation: number, diagnostic: ComponentDiagnostic): void {
    if (this.retired || !this.registry || this.registry.currentGeneration(key) !== generation) return;
    if (key.startsWith("custom:")) {
      this.failCustom(key, new Error(diagnostic.message));
      return;
    }
    const width = Math.min(this.terminal?.columns ?? 80, 160);
    const bounded = boundedExtensionFrame(stripTerminalControls(`[Extension component unavailable: ${diagnostic.message}]`, false), width);
    const frame: ExtensionFrame = { width, height: 1, lines: bounded.lines.map((line) => ({ plainText: line.plainText, runs: line.runs.map((run) => ({ text: run.text, style: { ...run.style } })) })), plainText: bounded.plainText };
    const id = this.surfaceId(key, "widget");
    this.stageSurface({ id, kind: "widget", placement: this.placements.get(key) ?? "aboveEditor", lifecycle: "retained", revision: this.nextRevision(id), focused: false, inputMode: "none", frame });
    this.recordDiagnostic(diagnostic);
    this.flushPresentation();
  }

  private removeSurface(id: string): void {
    if (this.retired) return;
    this.pendingSurfaces.delete(id);
    this.pendingRemovals.add(id);
    this.flushPresentation();
  }

  private recordDiagnostic(diagnostic: ComponentDiagnostic): void {
    if (this.retired || this.pendingDiagnostics.length >= MAX_HOST_DIAGNOSTICS) return;
    this.pendingDiagnostics.push({ code: diagnostic.code, message: boundedDisplayError(diagnostic.message) });
    if (!this.screen) this.flushPresentation();
  }

  retire(reason = "Extension host epoch retired"): void {
    if (this.retired) return;
    for (const id of this.presentation.state().surfaces.filter((surface) => surface.id.startsWith("widget:") || surface.id.startsWith("custom:")).map((surface) => surface.id)) this.pendingRemovals.add(id);
    this.pendingSurfaces.clear();
    this.flushPresentation();
    const call = this.customCall;
    if (call && !call.settled) {
      call.retired = true;
      call.settled = true;
      call.reject(new Error(reason));
    }
    this.registry?.retireAll();
    this.surfaceMeta.clear();
    this.placements.clear();
    this.surfaceDigests.clear();
    this.pendingDiagnostics = [];
    this.screen?.stop({ preserveScreen: true });
    if (!this.retired) {
      this.presentation.setPendingComponentFactories(0);
      this.presentation.setScheduledRenders(0);
    }
    this.renderQueued = false;
    this.renderActive = false;
    this.retired = true;
    this.presentation.retire();
  }
}
