import { GatewayError } from "../../errors.js";
import { normalizePublicDisplayURL } from "../../util/public-display-url.js";
import { BROWSER_LIVE_VIEW_SCHEMA, NATIVE_LIVE_VIEW_SCHEMA, type LiveViewDescriptor } from "../display/contract.js";

export type AppReference = { kind: "url"; media: "webpage" | "hls"; url: string }
  | { kind: "live"; sessionId: string; liveView: LiveViewDescriptor };
const text = (value: unknown, maximum: number): value is string => typeof value === "string" && Buffer.byteLength(value) > 0
  && Buffer.byteLength(value) <= maximum && !/[\u0000-\u001f\u007f]/.test(value);
function object(value: unknown, keys: string[]): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).some(key => !keys.includes(key))) fail();
  return value as Record<string, unknown>;
}
function fail(): never { throw new GatewayError("invalid_request", "Invalid app display reference"); }
/** Files contain inert descriptors, never transport URLs or reconnect authority.
 * Live opening still belongs to the exact display owner's active generation. */
export function readAppReference(bytes: Buffer, kind: "link" | "live"): AppReference {
  let decoded: unknown; try { decoded = JSON.parse(bytes.toString("utf8")); } catch { fail(); }
  const value = object(decoded, kind === "link" ? ["version", "kind", "media", "url"] : ["version", "kind", "sessionId", "liveView"]);
  if (value.version !== 1) fail();
  if (kind === "link") {
    if (value.kind !== "url" || value.media !== "webpage" && value.media !== "hls" || !text(value.url, 8192)) fail();
    const url = normalizePublicDisplayURL(value.url); if (!url) fail();
    return { kind: "url", media: value.media, url };
  }
  if (value.kind !== "live" || !text(value.sessionId, 200) || !/^[a-zA-Z0-9_-]+$/.test(value.sessionId)) fail();
  const view = object(value.liveView, ["schema", "viewId", "generation", "title", "fallbackText"]);
  if (view.schema !== BROWSER_LIVE_VIEW_SCHEMA && view.schema !== NATIVE_LIVE_VIEW_SCHEMA
    || !text(view.viewId, 200) || !text(view.generation, 200) || !text(view.title, 256) || !text(view.fallbackText, 4096)) fail();
  return { kind: "live", sessionId: value.sessionId, liveView: {
    schema: view.schema, viewId: view.viewId, generation: view.generation, title: view.title, fallbackText: view.fallbackText,
  } };
}
