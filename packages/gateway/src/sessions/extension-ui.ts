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
const PORTABLE_WIDGET_LINE_CHARACTERS = 512;

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
  return lines
    .map(stripTerminalPresentation)
    .filter(Boolean)
    .map((line) => line.slice(0, PORTABLE_WIDGET_LINE_CHARACTERS))
    .slice(0, PORTABLE_WIDGET_LINES);
}

function renderPortableWidget(content: unknown): string[] | undefined {
  if (Array.isArray(content) && content.every((line) => typeof line === "string")) {
    return boundedWidgetLines(content);
  }
  if (typeof content !== "function") return undefined;
  try {
    const component = content(undefined, plainWidgetTheme()) as { render?: (width: number) => unknown } | undefined;
    if (!component || typeof component.render !== "function") return undefined;
    const rendered = component.render(PORTABLE_WIDGET_WIDTH);
    if (!Array.isArray(rendered) || !rendered.every((line) => typeof line === "string")) return undefined;
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
    };
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
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const timeout = options?.timeout;
      const wire: ExtensionInteraction = {
        id,
        ...input,
        ...(timeout ? { expiresAt: new Date(Date.now() + timeout).toISOString() } : {}),
      };
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
        broker.broadcast("session.notification", { message, type } as JsonValue);
      },
      onTerminalInput() {
        return () => {};
      },
      setStatus(key: string, text?: string) {
        if (text === undefined) broker.statuses.delete(key);
        else broker.statuses.set(key, text);
        broker.broadcast("session.status", { key, text: text ?? null });
      },
      setWorkingMessage(message?: string) {
        broker.workingMessage = message;
        broker.broadcast("session.working", { message: message ?? null, visible: broker.workingVisible });
      },
      setWorkingVisible(visible: boolean) {
        broker.workingVisible = visible;
        broker.broadcast("session.working", { message: broker.workingMessage ?? null, visible });
      },
      setWorkingIndicator() {},
      setHiddenThinkingLabel(label?: string) {
        broker.hiddenThinkingLabel = label;
        broker.broadcast("session.thinkingLabel", { label: label ?? null });
      },
      setWidget(key: string, content: unknown, options?: { placement?: string }) {
        if (content === undefined || content === null) {
          broker.widgets.delete(key);
          broker.broadcast("session.widget", { key, lines: null });
          return;
        }
        const lines = renderPortableWidget(content);
        if (lines) {
          const placement = options?.placement === "belowEditor" ? "belowEditor" : "aboveEditor";
          const widget: ExtensionWidget = { key, lines, placement };
          broker.widgets.set(key, widget);
          broker.broadcast("session.widget", widget as unknown as JsonValue);
        }
      },
      setFooter() {},
      setHeader() {},
      setTitle(title: string) {
        broker.title = title || undefined;
        broker.broadcast("session.title", { title: broker.title ?? null });
      },
      async custom() {
        // Pi RPC explicitly degrades custom terminal components to undefined.
        return undefined;
      },
      pasteToEditor(text: string) {
        broker.editorText += text;
        broker.editorRevision += 1;
        broker.broadcast("session.editorText", { action: "paste", text, fullText: broker.editorText, revision: broker.editorRevision });
      },
      setEditorText(text: string) {
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
