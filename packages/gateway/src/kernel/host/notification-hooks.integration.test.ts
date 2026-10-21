import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { ModuleHost } from "./module-host.js";
import { createNotifyModule } from "../../notifications/notify-module.js";
import { NotificationGrantStore } from "../../notifications/grant-store.js";
import { NotificationService } from "../../notifications/notification-service.js";
import { PushRelayClient } from "../../notifications/relay-client.js";
import { waitFor } from "../../../test-support/wait-for.js";

it("K3 notification hooks resolve optional owners per call and admit real terminal/interaction receipts and relay envelopes", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-notification-hooks-"));
  const envelopes: Array<Record<string, unknown>> = [];
  const relayOrigin = "https://relay.lock.invalid";
  const relay = new PushRelayClient(relayOrigin, async (_url, init) => {
    envelopes.push(JSON.parse(String(init.body)) as Record<string, unknown>);
    return new Response(JSON.stringify({ status: "accepted_by_apns" }), { status: 200 }) as never;
  });
  const store = new NotificationGrantStore(home);
  const notifications = new NotificationService(store, relay);
  let available: NotificationService | undefined;
  let host: ModuleHost | undefined;
  try {
    await notifications.initialize();
    await notifications.upsertGrant({
      deviceId: "device-hooks", installationId: "installation-hooks", grantId: "grant-hooks-0001",
      secret: Buffer.alloc(32, 7).toString("base64url"), previewsEnabled: false, relayOrigin,
    });
    host = await ModuleHost.start([createNotifyModule(() => ({ notifications: available, machineId: "machine-hooks" }))], {
      tronHome: home, log: { log: () => {} },
    });
    expect(host.policy("runTerminal")!()).toBeUndefined();
    expect(host.policy("interactionRequired")!()).toBeUndefined();
    available = notifications;
    await host.policy("runTerminal")!()!({
      sessionId: "session-hooks", sourceId: "terminal-hooks", outcome: "completed", sessionTitle: "Hook session",
      observed: false, pendingBackgroundWork: 0, waitingEpisode: false,
    });
    await host.policy("interactionRequired")!()!({ sessionId: "session-hooks", interactionId: "ask-hooks", observed: false });
    await waitFor(async () => (await store.snapshot()).pending.length === 0, "both notification hooks to settle at the relay");
    const page = await notifications.inbox();
    expect(page.notifications).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "agent_finished", message: "The agent finished responding." }),
      expect.objectContaining({ kind: "ask", message: "Tron needs your input. Open Tron to respond." }),
    ]));
    expect(envelopes).toEqual(expect.arrayContaining([
      expect.objectContaining({ notificationKind: "agent_finished", sessionId: "session-hooks", machineId: "machine-hooks" }),
      expect.objectContaining({ notificationKind: "ask", sessionId: "session-hooks", machineId: "machine-hooks" }),
    ]));
    available = undefined;
    expect(host.policy("runTerminal")!()).toBeUndefined();
    expect(host.policy("interactionRequired")!()).toBeUndefined();
  } finally {
    try { await host?.stop(); } finally {
      notifications.dispose();
      await rm(home, { recursive: true, force: true });
    }
  }
});
