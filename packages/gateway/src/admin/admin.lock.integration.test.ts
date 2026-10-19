import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested } from "../../test-support/scenario-lock.js";

/**
 * Kernel settings-change lock (restructure plan §6.4, V3) for the `gateway/admin`
 * module: the one settings change path (`settings.change`, docs/settings-model.md)
 * through the real Gateway over a loopback WebSocket, as the iPhone uses it.
 *
 * The lock records the resolution before and after a Mac-layer change, the same
 * key resolved for a live chat, the change response and history, the Mac
 * `settings.json` the change wrote, the files under the settings record, and
 * the notifications enqueued at the relay boundary, compared with
 * `locks/admin-settings-change.golden.json`.
 */

const MODULE = "gateway/admin";
const KEY = "run.retry.maxRetries";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

describe("gateway/admin kernel locks", () => {
  it("settings change: a Mac-layer change is recorded, resolved everywhere and reaches a live chat", async () => {
    const gateway = await startLockGateway("admin-settings-change", { settings: { retry: { maxRetries: 4 } } });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    const opened = await phone.request("session.open", { sessionId });
    expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);

    const before = await phone.request("settings.resolve", { target: { kind: "mac" }, keys: [KEY] });
    const changed = await phone.request("settings.change", {
      commandId: gateway.commandId(), target: { kind: "mac" }, reason: "Retry transient provider failures longer",
      changes: [{ key: KEY, layer: "mac", op: "set", value: 6, expected: 4 }],
    });
    const after = await phone.request("settings.resolve", { target: { kind: "mac" }, keys: [KEY] });
    const chat = await phone.request("settings.resolve", { target: { kind: "session", sessionId }, keys: [KEY] });
    const history = await phone.request("settings.history", { limit: 10 });

    const recorded = gateway.record();
    const trace = {
      lock: "admin-settings-change",
      exchanges: recorded.exchanges,
      events: recorded.events,
      files: {
        macSettings: await gateway.file(join(gateway.agentDir, "settings.json")),
        settingsRecord: await gateway.tree(join(gateway.tronHome, "gateway", "settings")),
      },
      notifications: [...gateway.notifications],
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        for (const response of [before, changed, after, chat, history]) expect(response.ok, JSON.stringify(response)).toBe(true);
        expect(changed.result.status).toBe("applied");
        expect((trace.files.macSettings as { retry?: { maxRetries?: number } }).retry?.maxRetries).toBe(6);
        expect(JSON.stringify(after.result)).toContain('"value":6');
        expect(JSON.stringify(chat.result)).toContain('"value":6');
        expect(history.result.entries.length).toBeGreaterThan(0);
        expect(trace.files.settingsRecord.length).toBeGreaterThan(0);
      },
    });
  });
});
