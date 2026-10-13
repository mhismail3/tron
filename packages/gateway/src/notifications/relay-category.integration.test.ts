import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { NotificationGrantStore } from "./grant-store.js";
import { NotificationService } from "./notification-service.js";
import { PushRelayClient } from "./relay-client.js";
import { waitFor } from "../../test-support/wait-for.js";

/**
 * Decision 35 at the real relay boundary: the Gateway sends `category` only to a
 * relay whose capabilities advertise it. An older relay (no capabilities route,
 * which rejects unknown fields) must receive the same waiting push without it.
 * The fake relays below apply the relay's field allowlist, so a leaked field is a
 * delivery failure rather than a silent pass. Retained evidence for one run lives
 * at `packages/gateway/test-results/relay-category.integration.json`.
 */
const REPORT_PATH = join(process.cwd(), "test-results", "relay-category.integration.json");
const report: {
  generatedAt: string;
  cases: Array<{ name: string; passed: boolean; evidence: Record<string, unknown> }>;
} = { generatedAt: new Date().toISOString(), cases: [] };

afterAll(async () => {
  await mkdir(dirname(REPORT_PATH), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
});

const RELAY_ORIGIN = "https://push.example.test";
const GRANT = {
  deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
  secret: Buffer.alloc(32, 7).toString("base64url"), previewsEnabled: true,
  relayOrigin: RELAY_ORIGIN, notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true,
};
const BASE_FIELDS = new Set(["version", "kind", "notificationKind", "interruptionLevel", "requestId", "message", "title", "sessionId", "machineId", "expiresAt"]);

type RelayMode = "older" | "current";
interface FakeRelay {
  origin: string;
  /** Decoded bodies of accepted or rejected notification POSTs, in arrival order. */
  received: Array<Record<string, unknown>>;
  capabilityProbes: number;
}

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const release of cleanup.splice(0).reverse()) await release();
});

async function startFakeRelay(mode: RelayMode): Promise<FakeRelay> {
  const relay: FakeRelay = { origin: "", received: [], capabilityProbes: 0 };
  const server = createServer(async (request: IncomingMessage, response: ServerResponse) => {
    const path = new URL(request.url ?? "/", RELAY_ORIGIN).pathname;
    if (request.method === "GET" && path === "/v3/capabilities") {
      relay.capabilityProbes += 1;
      if (mode === "older") return reply(response, 404, { error: "not_found" });
      return reply(response, 200, { version: 1, notificationCategories: ["settings-approval"] });
    }
    if (request.method !== "POST" || path !== "/v3/notifications") return reply(response, 404, { error: "not_found" });
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    const envelope = JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
    relay.received.push(envelope);
    const allowed = mode === "current" ? new Set([...BASE_FIELDS, "category"]) : BASE_FIELDS;
    if (Object.keys(envelope).some((key) => !allowed.has(key))) return reply(response, 400, { error: "unknown_field" });
    if (envelope.category !== undefined && (envelope.category !== "settings-approval" || envelope.notificationKind !== "waiting")) {
      return reply(response, 400, { error: "invalid_request" });
    }
    return reply(response, 200, { status: "accepted_by_apns", apnsId: `apns-${String(envelope.requestId)}` });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  cleanup.push(async () => { server.close(); await once(server, "close"); });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("fake relay did not bind a TCP port");
  relay.origin = `http://127.0.0.1:${address.port}`;
  return relay;
}

function reply(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

async function fixture(mode: RelayMode) {
  const root = await mkdtemp(join(tmpdir(), "tron-relay-category-"));
  cleanup.push(() => rm(root, { recursive: true, force: true }));
  const store = new NotificationGrantStore(root);
  await store.initialize();
  const relay = await startFakeRelay(mode);
  // The Gateway addresses the public origin; the fetcher maps the same path onto the fake.
  const client = new PushRelayClient(RELAY_ORIGIN, async (url, init) =>
    await fetch(`${relay.origin}${new URL(url).pathname}`, init) as never);
  const notifications = new NotificationService(store, client);
  cleanup.push(async () => notifications.dispose());
  await notifications.initialize();
  await notifications.upsertGrant(GRANT);
  return { notifications, relay };
}

/** Waits for the admitted push's inbox row to report its accepted APNs outcome. */
async function acceptedOutcome(notifications: NotificationService, kind: "waiting" | "explicit", sessionId: string): Promise<void> {
  await waitFor(async () => (await notifications.inbox()).notifications
    .some((item) => item.kind === kind && item.sessionId === sessionId && item.outcome === "accepted_by_apns") || undefined,
  `the ${kind} push for ${sessionId} to be accepted by the relay`);
}

describe("push relay settings-approval category against relay versions", () => {
  it("omits the category when the relay does not advertise it", async () => {
    const { notifications, relay } = await fixture("older");
    const status = await notifications.enqueue({
      sessionId: "session-older-relay", sourceId: "settings-approval:request-older", kind: "waiting",
      title: "Approval needed", message: "The settings change needs approval.", category: "settings-approval",
    });
    expect(status).toBe("queued");
    await acceptedOutcome(notifications, "waiting", "session-older-relay");

    expect(relay.capabilityProbes).toBe(1);
    expect(relay.received).toHaveLength(1);
    expect(relay.received[0]).not.toHaveProperty("category");
    expect(relay.received[0]).toMatchObject({ notificationKind: "waiting", message: "The settings change needs approval." });
    report.cases.push({
      name: "omits the category when the relay does not advertise it", passed: true,
      evidence: { relayMode: "older", capabilityProbes: relay.capabilityProbes, receivedBodies: relay.received },
    });
  });

  it("sends the category only to a relay that advertises it, and never on an explicit push", async () => {
    const { notifications, relay } = await fixture("current");
    expect(await notifications.enqueue({
      sessionId: "session-current-relay", sourceId: "settings-approval:request-current", kind: "waiting",
      title: "Approval needed", message: "The settings change needs approval.", category: "settings-approval",
    })).toBe("queued");
    expect(await notifications.enqueue({
      sessionId: "session-current-relay", sourceId: "settings-applied:change-current", kind: "explicit",
      title: "Setting changed", message: "An agent changed a setting. Undo it in Tron.",
    })).toBe("queued");
    await acceptedOutcome(notifications, "waiting", "session-current-relay");
    await acceptedOutcome(notifications, "explicit", "session-current-relay");

    // Only the categorized push probes; the explicit push never asks the relay.
    expect(relay.capabilityProbes).toBe(1);
    expect(relay.received).toHaveLength(2);
    const waiting = relay.received.find((envelope) => envelope.notificationKind === "waiting");
    const explicit = relay.received.find((envelope) => envelope.notificationKind === "explicit");
    expect(waiting).toMatchObject({ category: "settings-approval" });
    expect(explicit).toBeDefined();
    expect(explicit).not.toHaveProperty("category");
    report.cases.push({
      name: "sends the category only to a relay that advertises it, and never on an explicit push", passed: true,
      evidence: { relayMode: "current", capabilityProbes: relay.capabilityProbes, receivedBodies: relay.received },
    });
  });

  it("rejects a category on a push that is not a waiting notification", async () => {
    const { notifications, relay } = await fixture("current");
    await expect(notifications.enqueue({
      sessionId: "session-explicit-category", sourceId: "settings-applied:change-rejected", kind: "explicit",
      message: "An agent changed a setting.", category: "settings-approval",
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(relay.capabilityProbes).toBe(0);
    expect(relay.received).toEqual([]);
    report.cases.push({
      name: "rejects a category on a push that is not a waiting notification", passed: true,
      evidence: { rejectedKind: "explicit", capabilityProbes: relay.capabilityProbes, receivedBodies: relay.received },
    });
  });
});
