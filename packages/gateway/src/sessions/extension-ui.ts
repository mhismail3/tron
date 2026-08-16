import { randomUUID } from "node:crypto";
import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import type { ExtensionInteraction, ExtensionUIState, ExtensionWidget, JsonValue } from "../protocol/types.js";
import { GatewayError } from "../errors.js";

interface PendingInteraction {
  wire: ExtensionInteraction;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer?: NodeJS.Timeout;
  cleanupAbort?: () => void;
}

type UIBroadcast = (topic: string, payload: JsonValue) => void;

const PORTABLE_WIDGET_WIDTH = 76;
const PORTABLE_WIDGET_LINES = 12;
const PORTABLE_WIDGET_LINE_BYTES = 512;
const MAX_WIDGET_RENDERED_LINES = 256;
const MAX_STATUSES = 32;
const MAX_WIDGETS = 24;
const MAX_PENDING_INTERACTIONS = 8;
const MAX_SELECT_OPTIONS = 64;
const MAX_INTERACTION_BYTES = 192 * 1_024;
const MAX_EDITOR_BYTES = 192 * 1_024;
const MAX_EXTENSION_UI_STATE_BYTES = 640 * 1_024;
const MAX_INTERACTION_TIMEOUT_MS = 24 * 60 * 60_000;
const MAX_KEY_BYTES = 256;
const MAX_TITLE_BYTES = 4 * 1_024;
const MAX_MESSAGE_BYTES = 32 * 1_024;
const MAX_OPTION_BYTES = 2 * 1_024;
const MAX_STATUS_BYTES = 4 * 1_024;
const MAX_WORKING_BYTES = 8 * 1_024;
const MAX_NOTIFICATION_BYTES = 32 * 1_024;

function encodedBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value));
}

function requireBoundedString(value: string, maximumBytes: number, field: string): void {
  if (typeof value !== "string" || encodedBytes(value) > maximumBytes) {
    throw new GatewayError("conflict", `Extension UI ${field} exceeds its bounded capacity`);
  }
}

function boundedUtf8Prefix(value: string, maximumBytes: number): string {
  const encoded = Buffer.from(value);
  if (encoded.length <= maximumBytes) return value;
  const decoder = new TextDecoder("utf-8", { fatal: true });
  for (let end = maximumBytes; end >= Math.max(0, maximumBytes - 3); end -= 1) {
    try { return decoder.decode(encoded.subarray(0, end)); }
    catch { /* Remove only an incomplete terminal UTF-8 sequence. */ }
  }
  return "";
}

function plainWidgetTheme(): unknown {
  return new Proxy({}, {
    get: () => (...args: unknown[]) => String(args.at(-1) ?? ""),
  });
}

function stripTerminalPresentation(value: string): string {
  return value
    .replace(/\u001B\][^\u0007]*(?:\u0007|\u001B\\)/g, "")
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
    .trimEnd();
}

function boundedWidgetLines(lines: string[]): string[] {
  if (lines.length > MAX_WIDGET_RENDERED_LINES) return [];
  const bounded: string[] = [];
  for (const source of lines) {
    let sourcePrefix = source.slice(0, PORTABLE_WIDGET_LINE_BYTES * 4);
    const finalCodeUnit = sourcePrefix.charCodeAt(sourcePrefix.length - 1);
    if (finalCodeUnit >= 0xD800 && finalCodeUnit <= 0xDBFF) sourcePrefix = sourcePrefix.slice(0, -1);
    const line = boundedUtf8Prefix(
      stripTerminalPresentation(sourcePrefix),
      PORTABLE_WIDGET_LINE_BYTES,
    );
    if (line) bounded.push(line);
    if (bounded.length >= PORTABLE_WIDGET_LINES) break;
  }
  return bounded;
}

function renderPortableWidget(content: unknown): string[] | undefined {
  if (Array.isArray(content)) {
    if (content.length > MAX_WIDGET_RENDERED_LINES || !content.every((line) => typeof line === "string")) return undefined;
    return boundedWidgetLines(content);
  }
  if (typeof content !== "function") return undefined;
  try {
    const component = content(undefined, plainWidgetTheme()) as { render?: (width: number) => unknown } | undefined;
    if (!component || typeof component.render !== "function") return undefined;
    const rendered = component.render(PORTABLE_WIDGET_WIDTH);
    if (!Array.isArray(rendered) || rendered.length > MAX_WIDGET_RENDERED_LINES
      || !rendered.every((line) => typeof line === "string")) return undefined;
    return boundedWidgetLines(rendered);
  } catch {
    // A TUI-only widget may depend on terminal state. It remains optional and
    // must never destabilize the authoritative session projection.
    return undefined;
  }
}

/**
 * Bridges the portable subset of Pi extension UI onto Tron's native protocol.
 * Arbitrary TUI components intentionally degrade exactly like Pi RPC custom():
 * they resolve undefined instead of failing the extension.
 */
export class ExtensionUIBroker {
  private readonly pending = new Map<string, PendingInteraction>();
  private readonly statuses = new Map<string, string>();
  private readonly widgets = new Map<string, ExtensionWidget>();
  private editorText = "";
  private editorRevision = 0;
  private workingMessage: string | undefined;
  private workingVisible = true;
  private hiddenThinkingLabel: string | undefined;
  private title: string | undefined;

  constructor(private readonly broadcast: UIBroadcast) {}

  interactions(): ExtensionInteraction[] {
    return [...this.pending.values()].map((pending) => pending.wire);
  }

  state(): ExtensionUIState {
    return this.projectedState();
  }

  private projectedState(overrides: Partial<ExtensionUIState> = {}): ExtensionUIState {
    return {
      statuses: Object.fromEntries(this.statuses),
      working: {
        ...(this.workingMessage ? { message: this.workingMessage } : {}),
        visible: this.workingVisible,
      },
      ...(this.hiddenThinkingLabel ? { hiddenThinkingLabel: this.hiddenThinkingLabel } : {}),
      widgets: [...this.widgets.values()],
      ...(this.title ? { title: this.title } : {}),
      editorRevision: this.editorRevision,
      editorText: this.editorText,
      pendingInteractions: this.interactions(),
      ...overrides,
    };
  }

  private requireStateCapacity(overrides: Partial<ExtensionUIState>): void {
    if (encodedBytes(this.projectedState(overrides)) > MAX_EXTENSION_UI_STATE_BYTES) {
      throw new GatewayError("busy", "Extension UI state reached its bounded capacity", true);
    }
  }

  respond(id: string, value: unknown, cancelled: boolean): void {
    const pending = this.pending.get(id);
    if (!pending) throw new GatewayError("not_found", "Extension interaction is no longer pending");
    this.finish(pending);
    if (cancelled) pending.resolve(undefined);
    else pending.resolve(value);
  }

  cancelAll(reason = "Session closed"): void {
    for (const pending of [...this.pending.values()]) {
      this.finish(pending);
      pending.reject(new GatewayError("cancelled", reason));
    }
  }

  private finish(pending: PendingInteraction): void {
    this.pending.delete(pending.wire.id);
    if (pending.timer) clearTimeout(pending.timer);
    pending.cleanupAbort?.();
    this.broadcast("session.interactions", this.interactions() as unknown as JsonValue);
  }

  private request(
    input: Omit<ExtensionInteraction, "id" | "expiresAt">,
    options?: { signal?: AbortSignal; timeout?: number },
  ): Promise<unknown> {
    if (options?.signal?.aborted) return Promise.reject(new GatewayError("cancelled", "Interaction cancelled"));
    try {
      requireBoundedString(input.title, MAX_TITLE_BYTES, "interaction title");
      if (input.message !== undefined) requireBoundedString(input.message, MAX_MESSAGE_BYTES, "interaction message");
      if (input.placeholder !== undefined) requireBoundedString(input.placeholder, MAX_TITLE_BYTES, "interaction placeholder");
      if (input.prefill !== undefined) requireBoundedString(input.prefill, MAX_EDITOR_BYTES, "interaction prefill");
      if (input.options !== undefined) {
        if (!Array.isArray(input.options)) {
          throw new GatewayError("conflict", "Extension UI select options are invalid");
        }
        if (input.options.length > MAX_SELECT_OPTIONS) {
          throw new GatewayError("conflict", "Extension UI select options exceed their bounded capacity");
        }
        for (const option of input.options) requireBoundedString(option, MAX_OPTION_BYTES, "select option");
      }
      if (this.pending.size >= MAX_PENDING_INTERACTIONS) {
        throw new GatewayError("busy", "Extension UI interactions reached their bounded capacity", true);
      }
      if (options?.timeout !== undefined
        && (!Number.isFinite(options.timeout) || !Number.isSafeInteger(options.timeout)
          || options.timeout < 1 || options.timeout > MAX_INTERACTION_TIMEOUT_MS)) {
        throw new GatewayError("conflict", "Extension UI interaction timeout is invalid");
      }
    } catch (error) {
      return Promise.reject(error);
    }
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const timeout = options?.timeout;
      const wire: ExtensionInteraction = {
        id,
        ...input,
        ...(timeout ? { expiresAt: new Date(Date.now() + timeout).toISOString() } : {}),
      };
      const interactions = [...this.interactions(), wire];
      if (encodedBytes(interactions) > MAX_INTERACTION_BYTES) {
        reject(new GatewayError("busy", "Extension UI interactions reached their bounded capacity", true));
        return;
      }
      try { this.requireStateCapacity({ pendingInteractions: interactions }); }
      catch (error) {
        reject(error);
        return;
      }
      const pending: PendingInteraction = { wire, resolve, reject };
      if (timeout) {
        pending.timer = setTimeout(() => {
          this.finish(pending);
          resolve(undefined);
        }, timeout);
      }
      if (options?.signal) {
        const abort = () => {
          this.finish(pending);
          reject(new GatewayError("cancelled", "Interaction cancelled"));
        };
        options.signal.addEventListener("abort", abort, { once: true });
        pending.cleanupAbort = () => options.signal?.removeEventListener("abort", abort);
      }
      this.pending.set(id, pending);
      this.broadcast("session.interactions", this.interactions() as unknown as JsonValue);
    });
  }

  context(): ExtensionUIContext {
    const broker = this;
    const context = {
      async select(title: string, options: string[], opts?: { signal?: AbortSignal; timeout?: number }) {
        const result = await broker.request({ method: "select", title, options }, opts);
        return typeof result === "string" && options.includes(result) ? result : undefined;
      },
      async confirm(title: string, message: string, opts?: { signal?: AbortSignal; timeout?: number }) {
        return (await broker.request({ method: "confirm", title, message }, opts)) === true;
      },
      async input(title: string, placeholder?: string, opts?: { signal?: AbortSignal; timeout?: number }) {
        const result = await broker.request(
          { method: "input", title, ...(placeholder === undefined ? {} : { placeholder }) },
          opts,
        );
        return typeof result === "string" ? result : undefined;
      },
      async editor(title: string, prefill?: string) {
        const result = await broker.request({ method: "editor", title, ...(prefill === undefined ? {} : { prefill }) });
        return typeof result === "string" ? result : undefined;
      },
      notify(message: string, type = "info") {
        requireBoundedString(message, MAX_NOTIFICATION_BYTES, "notification");
        requireBoundedString(type, MAX_KEY_BYTES, "notification type");
        broker.broadcast("session.notification", { message, type } as JsonValue);
      },
      onTerminalInput() {
        return () => {};
      },
      setStatus(key: string, text?: string) {
        requireBoundedString(key, MAX_KEY_BYTES, "status key");
        if (text !== undefined) {
          requireBoundedString(text, MAX_STATUS_BYTES, "status text");
          if (!broker.statuses.has(key) && broker.statuses.size >= MAX_STATUSES) {
            throw new GatewayError("busy", "Extension UI statuses reached their bounded capacity", true);
          }
          const statuses = new Map(broker.statuses);
          statuses.set(key, text);
          broker.requireStateCapacity({ statuses: Object.fromEntries(statuses) });
          broker.statuses.set(key, text);
        } else {
          broker.statuses.delete(key);
        }
        broker.broadcast("session.status", { key, text: text ?? null });
      },
      setWorkingMessage(message?: string) {
        if (message !== undefined) requireBoundedString(message, MAX_WORKING_BYTES, "working message");
        broker.requireStateCapacity({ working: { ...(message ? { message } : {}), visible: broker.workingVisible } });
        broker.workingMessage = message;
        broker.broadcast("session.working", { message: message ?? null, visible: broker.workingVisible });
      },
      setWorkingVisible(visible: boolean) {
        if (typeof visible !== "boolean") {
          throw new GatewayError("conflict", "Extension UI working visibility is invalid");
        }
        broker.requireStateCapacity({
          working: { ...(broker.workingMessage ? { message: broker.workingMessage } : {}), visible },
        });
        broker.workingVisible = visible;
        broker.broadcast("session.working", { message: broker.workingMessage ?? null, visible });
      },
      setWorkingIndicator() {},
      setHiddenThinkingLabel(label?: string) {
        if (label !== undefined) requireBoundedString(label, MAX_TITLE_BYTES, "thinking label");
        if (label !== undefined) broker.requireStateCapacity({ hiddenThinkingLabel: label });
        broker.hiddenThinkingLabel = label;
        broker.broadcast("session.thinkingLabel", { label: label ?? null });
      },
      setWidget(key: string, content: unknown, options?: { placement?: string }) {
        requireBoundedString(key, MAX_KEY_BYTES, "widget key");
        if (content === undefined || content === null) {
          broker.widgets.delete(key);
          broker.broadcast("session.widget", { key, lines: null });
          return;
        }
        const lines = renderPortableWidget(content);
        if (lines) {
          if (!broker.widgets.has(key) && broker.widgets.size >= MAX_WIDGETS) {
            throw new GatewayError("busy", "Extension UI widgets reached their bounded capacity", true);
          }
          const placement = options?.placement === "belowEditor" ? "belowEditor" : "aboveEditor";
          const widget: ExtensionWidget = { key, lines, placement };
          const widgets = new Map(broker.widgets);
          widgets.set(key, widget);
          broker.requireStateCapacity({ widgets: [...widgets.values()] });
          broker.widgets.set(key, widget);
          broker.broadcast("session.widget", widget as unknown as JsonValue);
        }
      },
      setFooter() {},
      setHeader() {},
      setTitle(title: string) {
        requireBoundedString(title, MAX_TITLE_BYTES, "title");
        const nextTitle = title || undefined;
        if (nextTitle !== undefined) broker.requireStateCapacity({ title: nextTitle });
        broker.title = nextTitle;
        broker.broadcast("session.title", { title: broker.title ?? null });
      },
      async custom() {
        // Pi RPC explicitly degrades custom terminal components to undefined.
        return undefined;
      },
      pasteToEditor(text: string) {
        requireBoundedString(text, MAX_EDITOR_BYTES, "editor paste");
        if (encodedBytes(broker.editorText) + encodedBytes(text) - 2 > MAX_EDITOR_BYTES) {
          throw new GatewayError("conflict", "Extension UI editor text exceeds its bounded capacity");
        }
        const fullText = broker.editorText + text;
        requireBoundedString(fullText, MAX_EDITOR_BYTES, "editor text");
        broker.requireStateCapacity({ editorText: fullText, editorRevision: broker.editorRevision + 1 });
        broker.editorText = fullText;
        broker.editorRevision += 1;
        broker.broadcast("session.editorText", { action: "paste", text, fullText, revision: broker.editorRevision });
      },
      setEditorText(text: string) {
        requireBoundedString(text, MAX_EDITOR_BYTES, "editor text");
        broker.requireStateCapacity({ editorText: text, editorRevision: broker.editorRevision + 1 });
        broker.editorText = text;
        broker.editorRevision += 1;
        broker.broadcast("session.editorText", { action: "set", text, fullText: text, revision: broker.editorRevision });
      },
      getEditorText() {
        return broker.editorText;
      },
      addAutocompleteProvider() {},
      setEditorComponent() {},
      getEditorComponent() {
        return undefined;
      },
      get theme() {
        return undefined;
      },
      getAllThemes() {
        return [];
      },
      getTheme() {
        return undefined;
      },
      setTheme() {
        return { success: false, error: "Terminal themes do not apply to the mobile client" };
      },
      getToolsExpanded() {
        return false;
      },
      setToolsExpanded() {},
    };
    return context as unknown as ExtensionUIContext;
  }
}
