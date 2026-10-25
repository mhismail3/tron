import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { waitFor } from "../../../test-support/wait-for.js";

// The unchanged scheduler and owned-run tests own cancellation/terminal evidence.
// This lock adds only the missing real-socket preview and cursor admission cuts.
it("binds automation timeline cursors to connection, window, revision, expiry and Gateway lifetime", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-timeline-lock-"));
  let gateway: LockGateway | undefined;
  try {
    gateway = await startLockGateway("automation-timeline", { automations: true, root });
    let phone = await gateway.connect("phone");
    const other = await gateway.connect("other");
    const from = "2099-01-01T00:00:00.000Z";
    const through = "2099-01-02T00:00:00.000Z";
    const window = { from, through, displayTimezone: "UTC", limit: 1 };
    const records: Array<{ id: string; revision: number }> = [];
    for (const hour of [9, 10, 11]) {
      const at = `2099-01-01T${String(hour).padStart(2, "0")}:00:00.000Z`;
      const created = await phone.request("automation.create", { commandId: gateway.commandId(), definition: {
        name: `Timeline ${hour}`, activation: "enabled", target: { kind: "workspace", cwd: gateway.cwd, sessionPolicy: "newPerRun" },
        trigger: { kind: "once", at }, action: { kind: "sessionPrompt", text: "A future fixture check" },
      } });
      expect(created.ok, JSON.stringify(created)).toBe(true);
      records.push(created.result);
    }
    const listed = await phone.request("automation.list");
    expect(listed.ok).toBe(true);
    expect(listed.result.items.map((item: { id: string }) => item.id).sort()).toEqual(records.map(record => record.id).sort());
    const preview = await phone.request("automation.schedule.preview", {
      trigger: { kind: "once", at: "2099-01-01T09:00:00.000Z" }, after: from, limit: 3,
    });
    expect(preview).toMatchObject({ ok: true, result: { occurrences: ["2099-01-01T09:00:00.000Z"] } });
    const page = async () => {
      const response = await phone.request("automation.timeline.list", window);
      expect(response.ok, JSON.stringify(response)).toBe(true);
      expect(response.result.nextCursor).toEqual(expect.any(String));
      return response.result;
    };
    const first = await page();
    expect(first.items[0].automationId).toBe(records[0]!.id);
    const foreign = await other.request("automation.timeline.list", { ...window, cursor: first.nextCursor });
    expect(foreign).toMatchObject({ ok: false, error: { code: "conflict" } });
    const continued = await phone.request("automation.timeline.list", { ...window, cursor: first.nextCursor });
    expect(continued.ok).toBe(true);
    expect(continued.result.items[0].automationId).toBe(records[1]!.id);
    const changedWindow = await phone.request("automation.timeline.list", {
      ...window, through: "2099-01-02T01:00:00.000Z", cursor: (await page()).nextCursor,
    });
    expect(changedWindow).toMatchObject({ ok: false, error: { code: "conflict" } });
    const oldRevision = await page();
    const staleWrite = await phone.request("automation.pause", {
      commandId: gateway.commandId(), automationId: records[0]!.id, expectedRevision: records[0]!.revision + 1,
    });
    expect(staleWrite).toMatchObject({ ok: false, error: { code: "conflict" } });
    const paused = await phone.request("automation.pause", {
      commandId: gateway.commandId(), automationId: records[0]!.id, expectedRevision: records[0]!.revision,
    });
    expect(paused.ok).toBe(true);
    const changedRevision = await phone.request("automation.timeline.list", { ...window, cursor: oldRevision.nextCursor });
    expect(changedRevision).toMatchObject({ ok: false, error: { code: "conflict" } });
    const expiring = await page();
    const afterLease = Date.now() + 61_000;
    // Elapsed wall time IS this contract: exercise the real 60-second lease,
    // without fake clocks/timers or a production injection seam. Status reads
    // keep the connection live but must not renew an unrelated timeline lease.
    await waitFor(async () => {
      expect((await phone.request("automation.status")).ok).toBe(true);
      return Date.now() >= afterLease || undefined;
    }, "real timeline lease elapsed", { intervalMs: 1_000, boundMs: 75_000 });
    const expired = await phone.request("automation.timeline.list", { ...window, cursor: expiring.nextCursor });
    expect(expired).toMatchObject({ ok: false, error: { code: "conflict" } });
    const beforeRestart = await page();
    await gateway.dispose({ keepRoot: true });
    gateway = undefined;
    gateway = await startLockGateway("automation-timeline", { automations: true, root });
    phone = await gateway.connect("reconnected");
    const retiredCursor = await phone.request("automation.timeline.list", { ...window, cursor: beforeRestart.nextCursor });
    expect(retiredCursor).toMatchObject({ ok: false, error: { code: "conflict" } });
    const persisted = await phone.request("automation.list");
    expect(persisted.ok).toBe(true);
    expect(persisted.result.items.map((item: { id: string }) => item.id).sort()).toEqual(records.map(record => record.id).sort());
    const artifact = join(process.cwd(), "test-results", "automation-rpc");
    await mkdir(artifact, { recursive: true });
    await writeFile(join(artifact, "trace.json"), JSON.stringify({ preview: preview.result,
      first: first.items.map((item: { scheduledFor: string }) => item.scheduledFor),
      continuation: continued.result.items.map((item: { scheduledFor: string }) => item.scheduledFor),
      refused: [foreign, changedWindow, staleWrite, changedRevision, expired, retiredCursor].map(response => response.error.code),
      persisted: persisted.result.items.map((item: { name: string; revision: number; activation: string }) =>
        ({ name: item.name, revision: item.revision, activation: item.activation })).sort((a: { name: string }, b: { name: string }) => a.name.localeCompare(b.name)),
    }, null, 2) + "\n");
  } finally {
    try { await gateway?.dispose({ keepRoot: true }); } finally { await rm(root, { recursive: true, force: true }); }
  }
}, 150_000);
