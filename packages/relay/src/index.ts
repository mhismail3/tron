/**
 * Closed APNs provider relay entry point.
 *
 * The engine supplies one already-authorized device target and one fixed
 * request form. Validation, authentication, durable replay, APNs transport,
 * and response classification remain separate closed owners.
 */

import { verifyRelaySignature } from "./authentication";
import {
  MAX_BODY_BYTES,
  RELAY_PATH,
  type Env,
} from "./contracts";
import { json } from "./response";
import {
  isOpaqueId,
  validateNotificationRequest,
} from "./validation";

export { RelayLedger } from "./ledger";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    if (url.pathname !== RELAY_PATH) {
      return json({ error: "not_found" }, 404);
    }
    if (!env.TRON_RELAY_SECRET) {
      return json({ error: "relay_not_configured" }, 503);
    }

    const body = new Uint8Array(await request.arrayBuffer());
    if (body.byteLength === 0 || body.byteLength > MAX_BODY_BYTES) {
      return json({ error: "invalid_body_size" }, 413);
    }
    const timestamp = request.headers.get("x-tron-timestamp");
    const requestId = request.headers.get("x-tron-request-id");
    const signature = request.headers.get("x-tron-signature");
    if (!timestamp || !requestId || !signature || !isOpaqueId(requestId)) {
      return json({ error: "invalid_authentication_headers" }, 401);
    }
    if (
      !(await verifyRelaySignature(
        env.TRON_RELAY_SECRET,
        timestamp,
        requestId,
        body,
        signature,
      ))
    ) {
      return json({ error: "invalid_signature" }, 401);
    }

    let value: unknown;
    try {
      value = JSON.parse(new TextDecoder().decode(body));
    } catch {
      return json({ error: "invalid_json" }, 400);
    }
    const parsed = validateNotificationRequest(value);
    if (!parsed.ok) {
      return json({ error: parsed.error }, 400);
    }
    if (parsed.value.requestId !== requestId) {
      return json({ error: "request_id_mismatch" }, 400);
    }

    const ledgerId = env.RELAY_LEDGER.idFromName("notification-relay-ledger-v1");
    const response = await env.RELAY_LEDGER.get(ledgerId).fetch(
      new Request("https://relay.internal/dispatch", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(parsed.value),
      }),
    );
    return new Response(response.body, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  },
};
