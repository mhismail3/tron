/** Closed Tron installation registry and APNs transport. */
import {
  CHALLENGE_PATH,
  GRANT_PATH_PREFIX,
  INSTALLATIONS_PATH,
  MAX_BODY_BYTES,
  NOTIFICATIONS_PATH,
  REGISTRY_NAME,
  type Env,
} from "./contracts";
import { ownedBuffer } from "./crypto";
import { json } from "./response";

export { PushRegistry } from "./registry";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.search || url.hash) return json({ error: "not_found" }, 404);
    const admitted =
      (request.method === "POST" && url.pathname === CHALLENGE_PATH) ||
      (request.method === "POST" && url.pathname === INSTALLATIONS_PATH) ||
      (request.method === "POST" && url.pathname === NOTIFICATIONS_PATH) ||
      (request.method === "DELETE" && exactGrantPath(url.pathname));
    if (!admitted) {
      const knownPath = url.pathname === CHALLENGE_PATH || url.pathname === INSTALLATIONS_PATH ||
        url.pathname === NOTIFICATIONS_PATH || url.pathname.startsWith(GRANT_PATH_PREFIX);
      return json({ error: knownPath ? "method_not_allowed" : "not_found" }, knownPath ? 405 : 404);
    }
    if (!env.PUSH_REGISTRY) return json({ error: "service_not_configured" }, 503);

    const read = await readBoundedBody(request, MAX_BODY_BYTES);
    if (!read.ok) return json({ error: "invalid_body_size" }, 413);
    const body: Uint8Array<ArrayBufferLike> = read.body;
    const expectsBody = request.method === "POST" && url.pathname !== CHALLENGE_PATH;
    if (expectsBody && request.headers.get("content-type")?.split(";", 1)[0].trim().toLowerCase() !== "application/json") {
      return json({ error: "unsupported_media_type" }, 415);
    }
    if (expectsBody && body.byteLength === 0) return json({ error: "invalid_body_size" }, 413);
    if (!expectsBody && body.byteLength !== 0) return json({ error: "unexpected_body" }, 400);

    const id = env.PUSH_REGISTRY.idFromName(REGISTRY_NAME);
    const headers = new Headers();
    for (const name of ["content-type", "x-tron-grant-id", "x-tron-timestamp", "x-tron-request-id", "x-tron-signature"]) {
      const value = request.headers.get(name);
      if (value !== null) headers.set(name, value);
    }
    const forwarded = new Request(`https://push.internal${url.pathname}`, {
      method: request.method,
      headers,
      ...(body.byteLength > 0 ? { body: ownedBuffer(body) } : {}),
    });
    try {
      const response = await env.PUSH_REGISTRY.get(id).fetch(forwarded);
      return new Response(response.body, {
        status: response.status,
        headers: {
          "content-type": "application/json; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    } catch {
      return json({ error: "temporarily_unavailable" }, 503);
    }
  },
};

async function readBoundedBody(request: Request, maximum: number): Promise<
  { ok: true; body: Uint8Array } | { ok: false }
> {
  const declared = request.headers.get("content-length");
  if (declared !== null) {
    if (!/^\d+$/.test(declared) || Number(declared) > maximum) return { ok: false };
  }
  const reader = request.body?.getReader();
  if (!reader) return { ok: true, body: new Uint8Array() };
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maximum) {
      await reader.cancel();
      return { ok: false };
    }
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
  return { ok: true, body };
}

function exactGrantPath(path: string): boolean {
  const suffix = path.slice(GRANT_PATH_PREFIX.length);
  return path.startsWith(GRANT_PATH_PREFIX) && /^[A-Za-z0-9_-]{16,128}$/.test(suffix);
}
