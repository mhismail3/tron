import type { ExtensionFactory, ToolResultEvent } from "@earendil-works/pi-coding-agent";
import { admitToolDisplayProjection } from "./display-contract.js";
import { admitBrowserToolReference, sealBrowserToolReference } from "./browser-tool-reference.js";

const MAX_PARENT_CALLS = 32;
const MAX_PRESENTATION_BYTES = 16 * 1_024;

interface NestedDisplayDescriptor {
  toolCallId: string;
  toolName: string;
  display: NonNullable<ReturnType<typeof admitToolDisplayProjection>>;
  browserReceipt?: ReturnType<typeof sealBrowserToolReference>;
}

/** Carries only bounded, admitted presentation metadata from nested tool results
 * into the model-issued parent's canonical details; Pi remains the transcript owner. */
export function registerNestedPresentationHandlers(pi: Parameters<ExtensionFactory>[0]): void {
  const pending = new Map<string, { calls: NestedDisplayDescriptor[]; complete: boolean }>();
  let pendingBytes = 0;

  const clear = () => { pending.clear(); pendingBytes = 0; };
  pi.on("tool_result", (event: ToolResultEvent, ctx) => {
    if (event.parentToolCallId) {
      const sessionId = ctx.sessionManager.getSessionId();
      const display = admitToolDisplayProjection(event.toolName, event.details, event.toolCallId, sessionId);
      if (!display) return;
      const prior = pending.get(event.parentToolCallId) ?? { calls: [], complete: true };
      const browserReceipt = event.toolName === "agent_browser"
        ? (() => {
            const receipt = admitBrowserToolReference(event.toolName, event.toolCallId, event.details, sessionId);
            return receipt ? sealBrowserToolReference(sessionId, event.parentToolCallId!, receipt.descriptor, receipt.automatic) : undefined;
          })()
        : undefined;
      const descriptor: NestedDisplayDescriptor = {
        toolCallId: event.toolCallId,
        toolName: event.toolName,
        display,
        ...(browserReceipt ? { browserReceipt } : {}),
      };
      const descriptorBytes = Buffer.byteLength(JSON.stringify(descriptor));
      if (prior.calls.length >= MAX_PARENT_CALLS || pendingBytes + descriptorBytes > MAX_PRESENTATION_BYTES) {
        pending.set(event.parentToolCallId, { ...prior, complete: false });
        return;
      }
      pending.set(event.parentToolCallId, { calls: [...prior.calls, descriptor], complete: prior.complete });
      pendingBytes += descriptorBytes;
      return;
    }

    const records = pending.get(event.toolCallId);
    if (!records) return;
    pending.delete(event.toolCallId);
    pendingBytes -= records.calls.reduce((size, value) => size + Buffer.byteLength(JSON.stringify(value)), 0);
    const priorDetails = event.details && typeof event.details === "object" && !Array.isArray(event.details)
      ? event.details as Record<string, unknown> : {};
    return {
      details: {
        ...priorDetails,
        tronNested: {
          display: records.calls.map(({ toolCallId, toolName, display }) => ({ toolCallId, toolName, display })),
          browserLiveViews: records.calls.flatMap(({ toolCallId, toolName, display, browserReceipt }) =>
            display.liveView && browserReceipt ? [{ toolCallId, toolName, descriptor: display.liveView, receipt: browserReceipt }] : []),
          complete: records.complete,
        },
      },
    };
  });
  pi.on("agent_end", clear);
  pi.on("session_shutdown", clear);
};
