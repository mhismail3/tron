import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../../test-support/gateway-lock-harness.js";

it("previews schedules, fences stale writes and keeps definitions across a Gateway restart", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-automation-rpc-lock-"));
  let gateway: LockGateway | undefined;
  try {
    gateway = await startLockGateway("automation-rpc", { automations: true, root });
    let phone = await gateway.connect("phone");
    const from = "2099-01-01T00:00:00.000Z";
    const records: Array<{ id: string; revision: number }> = [];
    for (const hour of [9, 10, 11]) {
      const at = `2099-01-01T${String(hour).padStart(2, "0")}:00:00.000Z`;
      const created = await phone.request("automation.create", { commandId: gateway.commandId(), definition: {
        name: `Scheduled ${hour}`, activation: "enabled", target: { kind: "workspace", cwd: gateway.cwd, sessionPolicy: "newPerRun" },
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
    const staleWrite = await phone.request("automation.pause", {
      commandId: gateway.commandId(), automationId: records[0]!.id, expectedRevision: records[0]!.revision + 1,
    });
    expect(staleWrite).toMatchObject({ ok: false, error: { code: "conflict" } });
    const paused = await phone.request("automation.pause", {
      commandId: gateway.commandId(), automationId: records[0]!.id, expectedRevision: records[0]!.revision,
    });
    expect(paused.ok).toBe(true);
    await gateway.dispose({ keepRoot: true });
    gateway = undefined;
    gateway = await startLockGateway("automation-rpc", { automations: true, root });
    phone = await gateway.connect("reconnected");
    const persisted = await phone.request("automation.list");
    expect(persisted.ok).toBe(true);
    expect(persisted.result.items.map((item: { id: string }) => item.id).sort()).toEqual(records.map(record => record.id).sort());
    expect(persisted.result.items.find((item: { id: string }) => item.id === records[0]!.id)).toMatchObject({ activation: "paused" });
    const artifact = join(process.cwd(), "test-results", "automation-rpc");
    await mkdir(artifact, { recursive: true });
    await writeFile(join(artifact, "trace.json"), JSON.stringify({ preview: preview.result,
      refused: staleWrite.error.code,
      persisted: persisted.result.items.map((item: { name: string; revision: number; activation: string }) =>
        ({ name: item.name, revision: item.revision, activation: item.activation })).sort((a: { name: string }, b: { name: string }) => a.name.localeCompare(b.name)),
    }, null, 2) + "\n");
  } finally {
    try { await gateway?.dispose({ keepRoot: true }); } finally { await rm(root, { recursive: true, force: true }); }
  }
}, 60_000);
