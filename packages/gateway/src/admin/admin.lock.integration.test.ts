import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";

/**
 * Kernel settings-change lock (packages/gateway/docs/scenario-locks.md#locks) for the `gateway/admin`
 * module: the one settings change path (`settings.change`, docs/settings-model.md)
 * through the real Gateway over a loopback WebSocket, as the iPhone uses it.
 *
 * Effects are asserted by name: the resolution before and after a Global
 * change, the same key resolved for a live chat, the change response and its
 * review, the history entry, the Mac `settings.json` the change wrote, the files
 * under the settings record, and that nothing reached the relay boundary.
 */

const KEY = "run.retry.maxRetries";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

describe("gateway/admin kernel locks", () => {
  it("settings change: a Global change is recorded, resolved everywhere and reaches a live chat", async () => {
    const gateway = await startLockGateway("admin-settings-change", { settings: { retry: { maxRetries: 4 } } });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    const opened = await phone.request("session.open", { sessionId });
    expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);

    const before = await phone.request("settings.resolve", { target: { kind: "global" }, keys: [KEY] });
    const changed = await phone.request("settings.change", {
      commandId: gateway.commandId(), target: { kind: "global" }, reason: "Retry transient provider failures longer",
      changes: [{ key: KEY, layer: "global", op: "set", value: 6, expected: 4 }],
    });
    const after = await phone.request("settings.resolve", { target: { kind: "global" }, keys: [KEY] });
    const chat = await phone.request("settings.resolve", { target: { kind: "session", sessionId }, keys: [KEY] });
    const history = await phone.request("settings.history", { limit: 10 });

    for (const response of [before, changed, after, chat, history]) expect(response.ok, JSON.stringify(response)).toBe(true);
    // Each resolution as `key=value (display) @layer [layer:value...] overridden`.
    const resolved = (response: { result?: any }) => response.result.keys.map((key: { key: string; value: unknown; display: string; layer: string;
      overridden: boolean; layers: Array<{ layer: string; value?: unknown; applied: boolean }> }) =>
      `${key.key}=${String(key.value)} (${key.display}) @${key.layer} [${key.layers.map((layer) => `${layer.layer}:${String(layer.value ?? "-")}`).join(" ")}]${key.overridden ? " overridden" : ""}`);
    expect(resolved(before)).toEqual([`${KEY}=4 (4 retries) @global [global:4] overridden`]);
    expect(resolved(after)).toEqual([`${KEY}=6 (6 retries) @global [global:6] overridden`]);
    expect(resolved(chat)).toEqual([`${KEY}=6 (6 retries) @global [project:- session:- global:6]`]);
    expect(before.result.keys[0].presentation).toMatchObject({ label: "Retries", effect: "next-request", timing: "live", editable: true, sessionOverridable: true });
    expect(changed.result).toMatchObject({ status: "applied",
      changes: [{ key: KEY, layer: "global", before: 4, after: 6, status: "applied", changeId: expect.any(String) }],
      review: { title: "Retries", reason: "Retry transient provider failures longer", requiresTap: false, items: [{ label: "Retries", before: "4 retries", after: "6 retries",
        exact: JSON.stringify({ target: { kind: "global" }, key: KEY, layer: "global", qualifiers: {}, op: "set", before: 4, after: 6 }) }] } });
    expect(history.result.entries).toEqual([expect.objectContaining({ key: KEY, layer: "global", op: "set", before: 4, after: 6, status: "applied",
      changeId: changed.result.changes[0].changeId, reason: "Retry transient provider failures longer", target: { kind: "global" }, actor: expect.objectContaining({ kind: "ui" }),
      presentation: { actor: "You", display: { before: "4 retries", after: "6 retries" }, label: "Retries", layer: "Global", section: "run" } })]);
    // The Mac settings file holds the new value beside the harness's other settings; the change is recorded under the settings store.
    expect(await gateway.file(join(gateway.agentDir, "settings.json"))).toEqual({ compaction: { enabled: false, keepRecentTokens: 120, reserveTokens: 2048 },
      defaultModel: "faux-1", defaultProvider: "tron-lock-admin-settings-change", retry: { maxRetries: 6 }, sessionDir: "<tmp>/sessions" });
    expect(await gateway.tree(join(gateway.tronHome, "gateway", "settings"))).toEqual(["changes/000000.jsonl", "changes/index.json", "observed.json"]);
    expect(gateway.notifications).toEqual([]);
  });
});
