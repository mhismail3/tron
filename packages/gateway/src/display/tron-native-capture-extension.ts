import { Type } from "@earendil-works/pi-ai";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { BrowserLiveViewRegistry } from "./browser-live-view.js";

const parameters = Type.Object({
  action: Type.Union([Type.Literal("catalog"), Type.Literal("view"), Type.Literal("stop")]),
  handle: Type.Optional(Type.String({ minLength: 1, maxLength: 200 })),
  region: Type.Optional(Type.Object({
    x: Type.Number({ minimum: 0 }), y: Type.Number({ minimum: 0 }),
    width: Type.Number({ exclusiveMinimum: 0 }), height: Type.Number({ exclusiveMinimum: 0 }),
  }, { additionalProperties: false, description: "Optional crop for a display handle, in display-local points from its top-left corner; must remain within the catalog width/height. Not screenshot pixels." })),
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
      label: "Mac live view",
      description: "List visible Mac windows and displays (catalog), select an exact returned handle (view), or stop this session's native views (stop). A display handle can show the whole display or an explicit region in display-local points within its catalog width/height. Window handles show the whole selected window. Read-only capture requires the installed Tron Native Host and Screen Recording permission. No keyboard/mouse input. View returns an opaque reference for display with source.kind=native_live; capture starts only while viewed. Visibility changes resume only the retained exact source and crop after the previous stream joins. Stop or source loss ends the reference; list/select again. No raw PID/window/display ID, target rediscovery, or input replay.",
      parameters,
      executionMode: "sequential",
      execute: async (_id, params, signal): Promise<{ content: Array<{ type: "text"; text: string }>; details: Record<string, unknown> }> => {
        signal?.throwIfAborted();
        if ((params.action === "view") !== (params.handle !== undefined)) throw new Error("Only view requires a returned source handle");
        if (params.action !== "view" && params.region !== undefined) throw new Error("Only view accepts a display region");
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
        const view = await input.views.registerNative(sessionId, params.handle!, params.region);
        if (signal?.aborted) {
          input.views.retireView(sessionId, view.viewId, view.generation);
          await input.views.joinRetirements();
          signal.throwIfAborted();
        }
        const source = { kind: "native_live" as const, viewId: view.viewId, generation: view.generation };
        return { content: [{ type: "text", text: JSON.stringify({ source, title: view.title,
          instruction: "Use display with this exact source to show the selected Mac source. Capture starts only while viewed." }) }], details: { source } };
      },
    });
  };
}
