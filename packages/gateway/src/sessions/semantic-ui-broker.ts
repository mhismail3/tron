import {
  initTheme,
  Theme,
  type ExtensionUIContext,
  type ThemeColor,
  type WorkingIndicatorOptions,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { ExtensionInteraction, ExtensionSemanticState, ExtensionWidget } from "../protocol/types.js";
import { ExtensionPresentationStore } from "../extensions/host/extension-presentation-store.js";
import { stripTerminalControls } from "../extensions/host/terminal-sanitizer.js";
import { currentExtensionOwner } from "../extensions/owner-attribution.js";

interface PendingInteraction {
  wire: ExtensionInteraction;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer?: NodeJS.Timeout;
  cleanupAbort?: () => void;
}

// Pi exposes Theme and initTheme at its package root, but not its mutable global
// theme singleton. Keep RPC sessions isolated with a host-owned baseline while
// initializing Pi's public process-global markdown helpers exactly once.
initTheme(undefined, false);
const THEME_COLORS: Record<ThemeColor, string | number> = {
  accent: 6, border: 8, borderAccent: 6, borderMuted: 8,
  success: 2, error: 1, warning: 3, muted: 8, dim: 8, text: 7,
  thinkingText: 8, userMessageText: 7, customMessageText: 7, customMessageLabel: 6,
  toolTitle: 6, toolOutput: 7, mdHeading: 6, mdLink: 4, mdLinkUrl: 8,
  mdCode: 3, mdCodeBlock: 7, mdCodeBlockBorder: 8, mdQuote: 8,
  mdQuoteBorder: 8, mdHr: 8, mdListBullet: 6, toolDiffAdded: 2,
  toolDiffRemoved: 1, toolDiffContext: 8, syntaxComment: 8, syntaxKeyword: 5,
  syntaxFunction: 6, syntaxVariable: 7, syntaxString: 2, syntaxNumber: 3,
  syntaxType: 4, syntaxOperator: 7, syntaxPunctuation: 8, thinkingOff: 8,
  thinkingMinimal: 8, thinkingLow: 4, thinkingMedium: 6, thinkingHigh: 3,
  thinkingXhigh: 5, thinkingMax: 1, bashMode: 3,
};
const THEME_BACKGROUNDS: ConstructorParameters<typeof Theme>[1] = {
  selectedBg: 8, userMessageBg: 0, customMessageBg: 0,
  toolPendingBg: 0, toolSuccessBg: 0, toolErrorBg: 0, scrollbarThumb: 8,
};
const BASELINE_THEME = new Theme(THEME_COLORS, THEME_BACKGROUNDS, "256color", { name: "tron-rpc-baseline" });

const MAX_STATUSES = 32;
const MAX_WIDGETS = 24;
const MAX_PENDING_INTERACTIONS = 8;
const MAX_SELECT_OPTIONS = 64;
const MAX_INTERACTION_BYTES = 192 * 1_024;
const MAX_EDITOR_BYTES = 192 * 1_024;
const MAX_INTERACTION_TIMEOUT_MS = 24 * 60 * 60_000;
const MAX_KEY_BYTES = 256;
const MAX_TITLE_BYTES = 4 * 1_024;
const MAX_MESSAGE_BYTES = 32 * 1_024;
const MAX_OPTION_BYTES = 2 * 1_024;
const MAX_STATUS_BYTES = 4 * 1_024;
const MAX_WORKING_BYTES = 8 * 1_024;
const MAX_NOTIFICATION_BYTES = 32 * 1_024;
const MAX_WIDGET_LINES = 12;
const MAX_WIDGET_LINE_BYTES = 512;
const MAX_INDICATOR_FRAMES = 32;
const MAX_INDICATOR_FRAME_BYTES = 256;
const MAX_EDITOR_OPERATION_RECEIPTS = 128;

function encodedBytes(value: unknown): number { return Buffer.byteLength(JSON.stringify(value)); }
function requireBoundedString(value: string, maximumBytes: number, field: string): void {
  if (typeof value !== "string" || encodedBytes(value) > maximumBytes) {
    throw new GatewayError("conflict", `Extension UI ${field} exceeds its bounded capacity`);
  }
}
function stripTerminalPresentation(value: string): string { return stripTerminalControls(value, true); }
function boundedWidgetLines(content: unknown): string[] | undefined {
  if (!Array.isArray(content) || !content.every((line) => typeof line === "string") || content.length > MAX_WIDGET_LINES) return undefined;
  return content.map((source) => {
    const line = stripTerminalPresentation(source);
    if (Buffer.byteLength(line) > MAX_WIDGET_LINE_BYTES) throw new GatewayError("conflict", "Extension UI widget line exceeds its bounded capacity");
    return line;
  });
}

/** Implements semantic Pi UI methods while the injected store exclusively owns presentation state. */
export class SemanticUIBroker {
  private active = true;
  private readonly pending = new Map<string, PendingInteraction>();
  private readonly editorOperationReceipts = new Map<string, number>();

  constructor(readonly presentation: ExtensionPresentationStore) {}

  get hostEpoch(): string { return this.presentation.hostEpoch; }
  interactions(): ExtensionInteraction[] { return this.presentation.state().pendingInteractions; }
  get hasPendingInteractions(): boolean { return this.presentation.hasPendingInteraction; }
  get hasRetainedPresentation(): boolean { return this.presentation.hasRetainedPresentation; }
  state() { return this.presentation.state(); }

  private semantic(): ExtensionSemanticState { return this.presentation.state().semanticState; }
  private assertActive(): void {
    if (!this.active) throw new GatewayError("conflict", "Extension host epoch was retired", true);
  }
  private mutate(change: (state: ExtensionSemanticState) => void): void {
    this.assertActive();
    this.presentation.transact((draft) => change(draft.semanticState));
  }

  respond(id: string, hostEpoch: string, presentationRevision: number, value: unknown, cancelled: boolean): void {
    this.assertActive();
    const pending = this.pending.get(id);
    if (!pending) throw new GatewayError("not_found", "Extension interaction is no longer pending");
    if (hostEpoch !== this.hostEpoch || presentationRevision !== pending.wire.presentationRevision) {
      throw new GatewayError("conflict", "Extension interaction scope is stale; refresh the session", true);
    }
    if (!cancelled) {
      const valid = pending.wire.method === "confirm"
        ? typeof value === "boolean"
        : pending.wire.method === "select"
          ? typeof value === "string" && pending.wire.options?.includes(value) === true
          : typeof value === "string";
      if (!valid) throw new GatewayError("invalid_request", "Extension interaction response is invalid");
    }
    this.finish(pending);
    if (cancelled) pending.resolve(undefined); else pending.resolve(value);
  }

  updateEditor(hostEpoch: string, baseRevision: number, operationId: string, text: string): { revision: number; text: string; applied: boolean } {
    this.assertActive();
    requireBoundedString(operationId, MAX_KEY_BYTES, "editor operation ID");
    requireBoundedString(text, MAX_EDITOR_BYTES, "editor text");
    operationId = stripTerminalPresentation(operationId);
    text = stripTerminalPresentation(text);
    const current = this.semantic();
    if (hostEpoch !== this.hostEpoch) return { revision: current.editorRevision, text: current.editorText, applied: false };
    if (this.editorOperationReceipts.has(operationId)) return { revision: current.editorRevision, text: current.editorText, applied: true };
    if (baseRevision !== current.editorRevision) return { revision: current.editorRevision, text: current.editorText, applied: false };
    const revision = current.editorRevision + 1;
    this.presentation.transact((draft) => {
      draft.semanticState.editorText = text;
      draft.semanticState.editorRevision = revision;
      draft.editorDirective = { action: "native", delta: text, operationId };
    });
    this.editorOperationReceipts.set(operationId, revision);
    while (this.editorOperationReceipts.size > MAX_EDITOR_OPERATION_RECEIPTS) {
      const oldest = this.editorOperationReceipts.keys().next().value as string | undefined;
      if (oldest) this.editorOperationReceipts.delete(oldest); else break;
    }
    return { revision, text, applied: true };
  }

  retire(reason = "Extension host epoch retired"): void {
    if (!this.active) return;
    this.active = false;
    for (const pending of this.pending.values()) {
      this.cleanup(pending);
      pending.reject(new GatewayError("cancelled", reason));
    }
    this.presentation.retire();
  }
  cancelAll(reason = "Session closed"): void {
    const values = [...this.pending.values()];
    if (values.length > 0) this.presentation.transact((draft) => { draft.pendingInteractions = []; });
    for (const pending of values) {
      this.cleanup(pending);
      pending.reject(new GatewayError("cancelled", reason));
    }
  }
  private cleanup(pending: PendingInteraction): void {
    this.pending.delete(pending.wire.id);
    if (pending.timer) clearTimeout(pending.timer);
    pending.cleanupAbort?.();
  }
  private finish(pending: PendingInteraction): void {
    this.cleanup(pending);
    this.presentation.transact((draft) => {
      draft.pendingInteractions = draft.pendingInteractions.filter((interaction) => interaction.id !== pending.wire.id);
    });
  }

  private request(
    input: Omit<ExtensionInteraction, "id" | "hostEpoch" | "presentationRevision" | "expiresAt">,
    options?: { signal?: AbortSignal; timeout?: number },
  ): Promise<unknown> {
    try {
      this.assertActive();
      input = {
        ...input,
        title: typeof input.title === "string" ? stripTerminalPresentation(input.title) : input.title,
        ...(input.message === undefined ? {} : { message: typeof input.message === "string" ? stripTerminalPresentation(input.message) : input.message }),
        ...(input.placeholder === undefined ? {} : { placeholder: typeof input.placeholder === "string" ? stripTerminalPresentation(input.placeholder) : input.placeholder }),
        ...(input.prefill === undefined ? {} : { prefill: typeof input.prefill === "string" ? stripTerminalPresentation(input.prefill) : input.prefill }),
        ...(input.options === undefined ? {} : { options: Array.isArray(input.options) ? input.options.map((option) => typeof option === "string" ? stripTerminalPresentation(option) : option) : input.options }),
      };
      if (options?.signal?.aborted) return Promise.resolve(input.method === "confirm" ? false : undefined);
      requireBoundedString(input.title, MAX_TITLE_BYTES, "interaction title");
      if (input.message !== undefined) requireBoundedString(input.message, MAX_MESSAGE_BYTES, "interaction message");
      if (input.placeholder !== undefined) requireBoundedString(input.placeholder, MAX_TITLE_BYTES, "interaction placeholder");
      if (input.prefill !== undefined) requireBoundedString(input.prefill, MAX_EDITOR_BYTES, "interaction prefill");
      if (input.options !== undefined) {
        if (!Array.isArray(input.options) || input.options.length > MAX_SELECT_OPTIONS) throw new GatewayError("conflict", "Extension UI select options are invalid");
        for (const option of input.options) requireBoundedString(option, MAX_OPTION_BYTES, "select option");
      }
      if (this.pending.size >= MAX_PENDING_INTERACTIONS) throw new GatewayError("busy", "Extension UI interactions reached their bounded capacity", true);
      if (options?.timeout !== undefined && (!Number.isSafeInteger(options.timeout) || options.timeout < 1 || options.timeout > MAX_INTERACTION_TIMEOUT_MS)) {
        throw new GatewayError("conflict", "Extension UI interaction timeout is invalid");
      }
    } catch (error) { return Promise.reject(error); }

    return new Promise((resolve, reject) => {
      const timeout = options?.timeout;
      const wire: ExtensionInteraction = {
        id: crypto.randomUUID(), hostEpoch: this.hostEpoch, presentationRevision: 0, ...input,
        ...(timeout ? { expiresAt: new Date(Date.now() + timeout).toISOString() } : {}),
      };
      const interactions = [...this.interactions(), wire];
      if (encodedBytes(interactions) > MAX_INTERACTION_BYTES) return reject(new GatewayError("busy", "Extension UI interactions reached their bounded capacity", true));
      const pending: PendingInteraction = { wire, resolve, reject };
      try {
        this.presentation.transact((draft) => { draft.pendingInteractions.push(wire); });
      } catch (error) { reject(error); return; }
      wire.presentationRevision = this.interactions().find((interaction) => interaction.id === wire.id)?.presentationRevision ?? 0;
      if (timeout) pending.timer = setTimeout(() => { if (this.pending.has(wire.id)) { this.finish(pending); resolve(undefined); } }, timeout);
      if (options?.signal) {
        const abort = () => { if (this.pending.has(wire.id)) { this.finish(pending); resolve(input.method === "confirm" ? false : undefined); } };
        options.signal.addEventListener("abort", abort, { once: true });
        pending.cleanupAbort = () => options.signal?.removeEventListener("abort", abort);
      }
      this.pending.set(wire.id, pending);
    });
  }

  context(): ExtensionUIContext {
    const broker = this;
    return {
      async select(title, options, opts) {
        const result = await broker.request({ method: "select", title, options }, opts);
        return typeof result === "string" && options.includes(result) ? result : undefined;
      },
      async confirm(title, message, opts) { return (await broker.request({ method: "confirm", title, message }, opts)) === true; },
      async input(title, placeholder, opts) {
        const result = await broker.request({ method: "input", title, ...(placeholder === undefined ? {} : { placeholder }) }, opts);
        return typeof result === "string" ? result : undefined;
      },
      async editor(title, prefill) {
        const result = await broker.request({ method: "editor", title, ...(prefill === undefined ? {} : { prefill }) });
        return typeof result === "string" ? result : undefined;
      },
      notify(message, type = "info") {
        broker.assertActive(); requireBoundedString(message, MAX_NOTIFICATION_BYTES, "notification"); message = stripTerminalPresentation(message);
        if (type !== "info" && type !== "warning" && type !== "error") throw new GatewayError("conflict", "Extension UI notification type is invalid");
        broker.presentation.notify(message, type);
      },
      onTerminalInput() { broker.assertActive(); return () => {}; },
      setStatus(key, text) {
        broker.assertActive(); requireBoundedString(key, MAX_KEY_BYTES, "status key"); key = stripTerminalPresentation(key);
        if (text !== undefined) { requireBoundedString(text, MAX_STATUS_BYTES, "status text"); text = stripTerminalPresentation(text); }
        const owner = currentExtensionOwner();
        broker.mutate((state) => {
          if (text !== undefined) {
            if (!(key in state.statuses) && Object.keys(state.statuses).length >= MAX_STATUSES) throw new GatewayError("busy", "Extension UI statuses reached their bounded capacity", true);
            state.statuses[key] = text;
            if (owner) state.statusOwners[key] = owner; else delete state.statusOwners[key];
          } else {
            delete state.statuses[key];
            delete state.statusOwners[key];
          }
        });
      },
      setWorkingMessage(message) {
        broker.assertActive(); if (message !== undefined) { requireBoundedString(message, MAX_WORKING_BYTES, "working message"); message = stripTerminalPresentation(message); }
        broker.mutate((state) => { if (message === undefined) delete state.working.message; else state.working.message = message; });
      },
      setWorkingVisible(visible) {
        broker.assertActive(); if (typeof visible !== "boolean") throw new GatewayError("conflict", "Extension UI working visibility is invalid");
        broker.mutate((state) => { state.working.visible = visible; });
      },
      setWorkingIndicator(options?: WorkingIndicatorOptions) {
        broker.assertActive();
        let next: ExtensionSemanticState["working"]["indicator"];
        if (options === undefined) next = { kind: "default", frames: [] };
        else {
          const frames = options.frames ?? [];
          if (!Array.isArray(frames) || frames.length > MAX_INDICATOR_FRAMES || !frames.every((frame) => typeof frame === "string")) throw new GatewayError("conflict", "Extension UI working indicator is invalid");
          const sanitizedFrames = frames.map((frame) => { const sanitized = stripTerminalPresentation(frame); requireBoundedString(sanitized, MAX_INDICATOR_FRAME_BYTES, "indicator frame"); return sanitized; });
          if (options.intervalMs !== undefined && (!Number.isSafeInteger(options.intervalMs) || options.intervalMs < 16 || options.intervalMs > 60_000)) throw new GatewayError("conflict", "Extension UI working indicator interval is invalid");
          next = { kind: sanitizedFrames.length === 0 ? "hidden" : sanitizedFrames.length === 1 ? "static" : "animated", frames: sanitizedFrames, ...(options.intervalMs === undefined ? {} : { intervalMs: options.intervalMs }) };
        }
        broker.mutate((state) => { state.working.indicator = next; });
      },
      setHiddenThinkingLabel(label) {
        broker.assertActive(); if (label !== undefined) { requireBoundedString(label, MAX_TITLE_BYTES, "thinking label"); label = stripTerminalPresentation(label); }
        broker.mutate((state) => { if (label === undefined) delete state.hiddenThinkingLabel; else state.hiddenThinkingLabel = label; });
      },
      setWidget(key, content, options) {
        broker.assertActive(); requireBoundedString(key, MAX_KEY_BYTES, "widget key"); key = stripTerminalPresentation(key);
        if (content === undefined) { broker.mutate((state) => { state.widgets = state.widgets.filter((widget) => widget.key !== key); }); return; }
        const lines = boundedWidgetLines(content);
        if (!lines) return;
        const placement = options?.placement ?? "aboveEditor";
        if (placement !== "aboveEditor" && placement !== "belowEditor") throw new GatewayError("conflict", "Extension UI widget placement is invalid");
        broker.mutate((state) => {
          const index = state.widgets.findIndex((widget) => widget.key === key);
          if (index < 0 && state.widgets.length >= MAX_WIDGETS) throw new GatewayError("busy", "Extension UI widgets reached their bounded capacity", true);
          const owner = currentExtensionOwner();
          const widget: ExtensionWidget = { key, revision: (index < 0 ? 0 : state.widgets[index]?.revision ?? 0) + 1, lines, placement, ...(owner ? { owner } : {}) };
          if (index < 0) state.widgets.push(widget); else state.widgets[index] = widget;
        });
      },
      setFooter() { broker.assertActive(); }, setHeader() { broker.assertActive(); },
      setTitle(title) { broker.assertActive(); requireBoundedString(title, MAX_TITLE_BYTES, "title"); title = stripTerminalPresentation(title); broker.mutate((state) => { if (title) state.title = title; else delete state.title; }); },
      async custom() { broker.assertActive(); return undefined as never; },
      pasteToEditor(text) {
        broker.assertActive(); requireBoundedString(text, MAX_EDITOR_BYTES, "editor paste"); text = stripTerminalPresentation(text);
        broker.presentation.transact((draft) => {
          const fullText = draft.semanticState.editorText + text;
          requireBoundedString(fullText, MAX_EDITOR_BYTES, "editor text");
          draft.semanticState.editorText = fullText;
          draft.semanticState.editorRevision += 1;
          draft.editorDirective = { action: "paste", delta: text };
        });
      },
      setEditorText(text) {
        broker.assertActive(); requireBoundedString(text, MAX_EDITOR_BYTES, "editor text"); text = stripTerminalPresentation(text);
        broker.presentation.transact((draft) => {
          draft.semanticState.editorText = text;
          draft.semanticState.editorRevision += 1;
          draft.editorDirective = { action: "set", delta: text };
        });
      },
      getEditorText() { broker.assertActive(); return broker.semantic().editorText; },
      addAutocompleteProvider() { broker.assertActive(); }, setEditorComponent() { broker.assertActive(); }, getEditorComponent() { broker.assertActive(); return undefined; },
      get theme() { broker.assertActive(); return BASELINE_THEME; }, getAllThemes() { broker.assertActive(); return []; }, getTheme() { broker.assertActive(); return undefined; },
      setTheme() { broker.assertActive(); return { success: false, error: "Remote theme switching requires the Phase 4 component host" }; },
      getToolsExpanded() { broker.assertActive(); return broker.semantic().toolsExpanded; },
      setToolsExpanded(expanded) { broker.assertActive(); if (typeof expanded !== "boolean") throw new GatewayError("conflict", "Extension UI tool expansion is invalid"); broker.mutate((state) => { state.toolsExpanded = expanded; }); },
    };
  }
}
