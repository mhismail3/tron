import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { BROWSER_LIVE_VIEW_SCHEMA, type BrowserLiveViewDescriptor, type DisplayProjection } from "../modules/display/contract.js";

// A descriptor alone is not tool-result provenance. Bind the provider admission
// to this canonical call/session without keeping a second per-call registry.
// Restart loses browser registrations too; these receipts are deliberately ephemeral.
const key = randomBytes(32);
interface BrowserToolReference {
  sessionId: string;
  toolCallId: string;
  descriptor: BrowserLiveViewDescriptor;
  automatic: boolean;
  app?: NonNullable<DisplayProjection["app"]>;
  seal: string;
}
function signature(sessionId: string, toolCallId: string, descriptor: BrowserLiveViewDescriptor, automatic: boolean, app?: DisplayProjection["app"]): Buffer {
  return createHmac("sha256", key).update(JSON.stringify([
    sessionId, toolCallId, descriptor.schema, descriptor.viewId, descriptor.generation,
    descriptor.title, descriptor.fallbackText, automatic, app,
  ])).digest();
}
export function sealBrowserToolReference(sessionId: string, toolCallId: string, descriptor: BrowserLiveViewDescriptor, automatic: boolean, app?: DisplayProjection["app"]): BrowserToolReference {
  return { sessionId, toolCallId, descriptor, automatic, ...(app ? { app } : {}), seal: signature(sessionId, toolCallId, descriptor, automatic, app).toString("hex") };
}
export function admitBrowserToolReference(
  toolName: unknown, toolCallId: unknown, details: unknown, sessionId?: string,
): Pick<BrowserToolReference, "descriptor" | "automatic" | "app"> | undefined {
  if (toolName !== "agent_browser" || typeof toolCallId !== "string" || typeof sessionId !== "string"
    || !details || typeof details !== "object") return;
  const ref = (details as Record<string, unknown>).tronBrowserReference as BrowserToolReference | undefined;
  if (!ref || ref.toolCallId !== toolCallId || typeof ref.sessionId !== "string" || ref.sessionId.length > 256
    || ref.sessionId !== sessionId || typeof ref.automatic !== "boolean" || typeof ref.seal !== "string" || !/^[a-f0-9]{64}$/.test(ref.seal)) return;
  const descriptor = ref.descriptor;
  if (!descriptor || descriptor.schema !== BROWSER_LIVE_VIEW_SCHEMA
    || ![descriptor.viewId, descriptor.generation, descriptor.title, descriptor.fallbackText]
      .every(value => typeof value === "string" && value.length > 0 && value.length <= 2048)) return;
  return timingSafeEqual(Buffer.from(ref.seal, "hex"), signature(ref.sessionId, toolCallId, descriptor, ref.automatic, ref.app))
    ? { descriptor, automatic: ref.automatic, ...(ref.app ? { app: ref.app } : {}) } : undefined;
}
