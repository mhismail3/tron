import type { ExtensionUIContext, Theme } from "../../pi/coding-agent.js";
import type { TUI } from "../../pi/tui.js";
import type { ExtensionFrame, ExtensionOwner, ExtensionSurface } from "../../../protocol/types.js";
import { CapturingTuiMainScreen } from "./capturing-tui-main-screen.js";
import { ComponentRegistry, type ComponentRecord, type RemoteComponentFactory } from "./component-registry.js";
import { ExtensionPresentationStore } from "./extension-presentation-store.js";
import { boundedExtensionFrame, parseExtensionFrame } from "./frame-parser.js";
import { InMemoryTerminal } from "./in-memory-terminal.js";
import { type ComponentDiagnostic } from "./recording-component.js";
import { boundedDisplayError, stripTerminalControls } from "./terminal-sanitizer.js";
import { currentExtensionOwner } from "../extension-execution-context.js";

const MAX_HOST_COMPONENTS = 24;
const MAX_HOST_DIAGNOSTICS = 16;
const MAX_HOST_KEY_BYTES = 256;

function widgetSurfaceId(key: string): string {
  return `widget:${Buffer.from(key, "utf8").toString("base64url")}`;
}

interface WidgetMeta {
  owner?: Pick<ExtensionOwner, "source" | "kind">;
  placement: "aboveEditor" | "belowEditor";
}

/**
 * Per-presentation-epoch Pi host. RuntimeSlot binds this context in RPC mode so
 * retained component widgets can publish bounded read-only frames while every
 * semantic API continues through SemanticUIBroker and the same presentation
 * store. RPC mode has no native path for blocking custom or overlay UI, so
 * `custom()` is refused with a diagnostic and never invokes its factory.
 */
export class RemotePiExtensionHost {
  private readonly baseContext: ExtensionUIContext;
  private terminal?: InMemoryTerminal;
  private screen?: CapturingTuiMainScreen;
  private tuiProxy?: TUI;
  private registry?: ComponentRegistry;
  private renderQueued = false;
  private renderActive = false;
  private retired = false;
  private readonly surfaceDigests = new Map<string, string>();
  private readonly widgets = new Map<string, WidgetMeta>();
  private pendingDiagnostics: ComponentDiagnostic[] = [];
  private readonly pendingSurfaces = new Map<string, ExtensionSurface>();
  private readonly pendingRemovals = new Set<string>();

  constructor(readonly semantic: { presentation: ExtensionPresentationStore; context(): ExtensionUIContext }) {
    this.baseContext = semantic.context();
  }

  get presentation(): ExtensionPresentationStore { return this.semantic.presentation; }
  get hostEpoch(): string { return this.presentation.hostEpoch; }

  /** Re-render retained component surfaces after a native semantic UI mutation. */
  rerender(): void { if (!this.retired) this.requestRender(true); }

  context(): ExtensionUIContext {
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
        if (!host.admitComponent(key)) return;
        const previous = host.widgets.get(key);
        const owner = currentExtensionOwner();
        host.widgets.set(key, { placement: options?.placement === "belowEditor" ? "belowEditor" : "aboveEditor", ...(owner ? { owner } : {}) });
        // Registry admission may reject a replacement while a bounded factory
        // is pending. Restore metadata when that admission does not commit.
        if (!host.mountComponent(key, content as RemoteComponentFactory)) {
          if (previous === undefined) host.widgets.delete(key); else host.widgets.set(key, previous);
        }
      },
      custom() {
        if (host.retired) return Promise.reject(new Error("Extension host epoch was retired"));
        const error = new Error("Blocking component UI is deferred in RPC mode");
        host.recordDiagnostic({ code: "render-invalid", message: error.message });
        return Promise.reject(error);
      },
    };
  }

  private admitComponent(key: string): boolean {
    if (this.retired) return false;
    if (this.registry?.has(key)) return true;
    if ((this.registry?.recordCount ?? 0) >= MAX_HOST_COMPONENTS || this.widgets.size >= MAX_HOST_COMPONENTS) {
      this.recordDiagnostic({ code: "render-invalid", message: "Extension component capacity is full" });
      return false;
    }
    return true;
  }

  private ensureRegistry(): ComponentRegistry {
    if (this.retired) throw new Error("Extension host epoch was retired");
    if (this.registry) return this.registry;
    this.terminal = new InMemoryTerminal();
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
      onDiagnostic: (diagnostic) => this.recordDiagnostic(diagnostic),
      onActivity: (count) => { if (!this.retired) this.presentation.setPendingComponentFactories(count); },
    });
    this.markRenderScheduled();
    screen.start();
    return this.registry;
  }

  private mountComponent(key: string, factory: RemoteComponentFactory): boolean {
    const admitted = this.ensureRegistry().set(key, factory);
    if (!admitted) this.recordDiagnostic({ code: "render-invalid", message: "Extension component capacity is full" });
    return admitted;
  }

  private mountRecord(record: ComponentRecord): void {
    if (!this.screen || record.state !== "mounted" || !this.widgets.has(record.key)) return;
    try {
      this.screen.addChild(record.recording);
      this.screen.renderNow(true);
    } catch {
      this.registry?.remove(record.key);
    }
  }

  private retireRecord(record: ComponentRecord): void {
    try { if (record.recording) this.screen?.removeChild(record.recording); }
    catch (error) { this.recordDiagnostic({ code: "dispose-failed", message: boundedDisplayError(error) }); }
    this.removeSurface(widgetSurfaceId(record.key));
  }

  private removeComponent(key: string): void {
    this.registry?.remove(key);
    this.widgets.delete(key);
    this.removeSurface(widgetSurfaceId(key));
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

  private publishCapturedSurfaces(): void {
    if (this.retired || !this.registry || !this.terminal) return;
    this.renderActive = true;
    for (const record of this.registry.mountedRecords) {
      const meta = this.widgets.get(record.key);
      if (!meta) continue;
      const lines = record.recording.capturedLines;
      if (!lines) continue;
      const parsed = parseExtensionFrame(lines);
      for (const diagnostic of parsed.diagnostics) this.recordDiagnostic({ code: diagnostic.code as ComponentDiagnostic["code"], message: diagnostic.message });
      const frame = { ...parsed.frame, lines: parsed.frame.lines.map((line) => ({ plainText: line.plainText, runs: line.runs.map((run) => ({ text: run.text, style: { ...run.style } })) })), width: this.terminal.columns, height: parsed.frame.lines.length };
      const id = widgetSurfaceId(record.key);
      this.stageSurface({ id, kind: "widget", placement: meta.placement, lifecycle: "retained", revision: this.nextRevision(id), focused: false, inputMode: "none", frame,
        ...(meta.owner ? { provenance: { source: meta.owner.source, ...(meta.owner.kind ? { kind: meta.owner.kind } : {}) } } : {}) });
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
    const width = Math.min(this.terminal?.columns ?? 80, 160);
    const bounded = boundedExtensionFrame(stripTerminalControls(`[Extension component unavailable: ${diagnostic.message}]`, false), width);
    const frame: ExtensionFrame = { width, height: 1, lines: bounded.lines.map((line) => ({ plainText: line.plainText, runs: line.runs.map((run) => ({ text: run.text, style: { ...run.style } })) })), plainText: bounded.plainText };
    const id = widgetSurfaceId(key);
    this.stageSurface({ id, kind: "widget", placement: this.widgets.get(key)?.placement ?? "aboveEditor", lifecycle: "retained", revision: this.nextRevision(id), focused: false, inputMode: "none", frame });
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

  retire(): void {
    if (this.retired) return;
    for (const id of this.presentation.state().surfaces.filter((surface) => surface.id.startsWith("widget:")).map((surface) => surface.id)) this.pendingRemovals.add(id);
    this.pendingSurfaces.clear();
    this.flushPresentation();
    this.registry?.retireAll();
    this.widgets.clear();
    this.surfaceDigests.clear();
    this.pendingDiagnostics = [];
    this.screen?.stop({ preserveScreen: true });
    this.presentation.setPendingComponentFactories(0);
    this.presentation.setScheduledRenders(0);
    this.renderQueued = false;
    this.renderActive = false;
    this.retired = true;
    this.presentation.retire();
  }
}
