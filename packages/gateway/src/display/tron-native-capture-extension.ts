import { Type } from "typebox";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { BrowserLiveViewRegistry } from "./browser-live-view.js";

const parameters = Type.Object({
  action: Type.Union([Type.Literal("catalog"), Type.Literal("view"), Type.Literal("stop")]),
  handle: Type.Optional(Type.String({ minLength: 1, maxLength: 200 })),
}, { additionalProperties: false });

/** Canonical session/load owns the handles. No PID/window-ID input, selection
 * fallback, screenshots in tool history, or native input is exposed here. */
export function createTronNativeCaptureExtension(input: {
  sessionId: () => string;
  views: BrowserLiveViewRegistry;
}): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "native_capture",
      label: "Mac window view",
      description: "List Mac windows (catalog), select an exact returned handle (view), or stop this session's native views (stop). Read-only capture requires the installed Tron Native Host and Screen Recording permission. No keyboard/mouse input. View returns an opaque reference for display with source.kind=native_live; it does not start capture. Pixels are produced only while the user views that display. Visibility changes resume only the retained exact window after its previous stream joins. Stop or source loss ends the reference; list/select again. No raw PID, window ID, auto-reconnect, or replay.",
      parameters,
      executionMode: "sequential",
      execute: async (_id, params, signal): Promise<{ content: Array<{ type: "text"; text: string }>; details: Record<string, unknown> }> => {
        signal?.throwIfAborted();
        if ((params.action === "view") !== (params.handle !== undefined)) throw new Error("Only view requires a returned window handle");
        const sessionId = input.sessionId();
        if (params.action === "catalog") {
          const sources = await input.views.catalogNative(sessionId, signal);
          signal?.throwIfAborted();
          return { content: [{ type: "text", text: JSON.stringify({ sources }) }], details: { sources } };
        }
        if (params.action === "stop") {
          // Accepted Stop is a domain command, not a disposable read waiter.
          await input.views.stopNative(sessionId);
          return { content: [{ type: "text", text: "This session's native views are closed." }], details: {} };
        }
        const view = await input.views.registerNative(sessionId, params.handle!);
        if (signal?.aborted) {
          input.views.retireView(sessionId, view.viewId, view.generation);
          await input.views.joinRetirements();
          signal.throwIfAborted();
        }
        const source = { kind: "native_live" as const, viewId: view.viewId, generation: view.generation };
        return { content: [{ type: "text", text: JSON.stringify({ source, title: view.title,
          instruction: "Use display with this exact source to show the selected Mac window. Capture starts only while viewed." }) }], details: { source } };
      },
    });
  };
}
