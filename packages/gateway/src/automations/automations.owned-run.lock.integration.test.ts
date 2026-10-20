import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { waitFor } from "../../test-support/wait-for.js";

/**
 * Automation owned-run lock (restructure E0c, `docs/restructure/k0-kernel.md` §7)
 * for the `gateway/automations` module.
 *
 * The real Gateway (`gateway-lock-harness.ts`, option `automations`) runs the
 * production automation store, scheduler, executor and service. The phone
 * runs one turn in a chat, then creates two automations over the socket and runs each now: a session prompt
 * into its open chat (the executor leases it through `OwnedSessionDispatch`)
 * and a workspace prompt (the registry creates an owned session per run). Each
 * run reads a file through a tool, so the owned operation spans a tool round
 * trip. The lock records the client exchanges (command-receipted mutations,
 * the settled automation and run reads), event shapes, provider requests, both
 * sessions' canonical JSONL (ownership markers and invocation receipts), the
 * automation records, every command receipt, and the runtime-marker store the
 * acknowledged runs leave empty.
 */

const MODULE = "gateway/automations";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

/**
 * Per-run digests the shared normalization keeps because they are not under an
 * identity key: the occurrence id and the command-receipt identity hash (both
 * digests of generated ids) and the assistant completion id (a generated Pi
 * entry id). Each distinct value becomes `<key:N>` in first-appearance order, so
 * a run, its receipt and its reads still visibly name the same occurrence.
 */
const DERIVED_IDENTITIES = new Set(["occurrenceId", "identityHash", "assistantCompletionId"]);
function stabilizeDerivedIdentities(value: TraceValue): TraceValue {
  const seen = new Map<string, string>();
  const visit = (node: TraceValue, key?: string): TraceValue => {
    if (typeof node === "string" && key !== undefined && DERIVED_IDENTITIES.has(key)) {
      const scoped = `${key}\0${node}`;
      if (!seen.has(scoped)) seen.set(scoped, `<${key}:${[...seen.keys()].filter((entry) => entry.startsWith(`${key}\0`)).length + 1}>`);
      return seen.get(scoped)!;
    }
    if (Array.isArray(node)) return node.map((child) => visit(child));
    if (node !== null && typeof node === "object") return Object.fromEntries(Object.entries(node).map(([name, child]) => [name, visit(child, name)]));
    return node;
  };
  return visit(value);
}

/** The ids of a session's assistant entries, raw, in file order. */
async function assistantEntryIds(gateway: LockGateway, sessionId: string): Promise<string[]> {
  const slot = await gateway.registry.acquire(sessionId);
  return (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").flatMap((line) => {
    const entry = JSON.parse(line) as { id?: string; type?: string; message?: { role?: string } };
    return entry.type === "message" && entry.message?.role === "assistant" ? [entry.id!] : [];
  });
}

interface RunRecord { runId?: string; state?: string; executionSessionId?: string; assistantCompletionId?: string }
interface AutomationFile { currentRun?: RunRecord | null; lastRun?: RunRecord | null }

describe("gateway/automations owned-run lock", () => {
  it("automation-owned-run: a session prompt and a workspace prompt run now through the owned-session boundary", async () => {
    const gateway = await startLockGateway("automation-owned-run", { automations: true });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    const opened = await phone.request("session.open", { sessionId });
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);

    const automationFile = (automationId: string) => join(gateway.tronHome, "gateway", "automations", `${automationId}.json`);
    const raw = async (automationId: string) => {
      return JSON.parse(await readFile(automationFile(automationId), "utf8")) as AutomationFile;
    };
    const runNow = async (definition: Record<string, unknown>, label: string) => {
      const automation = await phone.request("automation.create", { commandId: gateway.commandId(), definition });
      expect(automation.ok, JSON.stringify(automation)).toBe(true);
      const automationId = automation.result.id as string;
      const run = await phone.request("automation.runNow", {
        commandId: gateway.commandId(), automationId, expectedRevision: automation.result.revision,
      });
      expect(run.ok, JSON.stringify(run)).toBe(true);
      const runId = run.result.runId as string;
      // Settled: the terminal run is the record's last run and no run is current.
      const settled = await waitFor(async () => {
        const record = await raw(automationId);
        return record.lastRun?.runId === runId && !record.currentRun ? record.lastRun : undefined;
      }, `the ${label} run's durable terminal`);
      await gateway.settled(settled.executionSessionId!);
      return { automationId, runId, executionSessionId: settled.executionSessionId!, state: settled.state, assistantCompletionId: settled.assistantCompletionId };
    };
    const definition = (target: Record<string, unknown>, text: string, name: string) => ({
      name, activation: "draft", target,
      trigger: { kind: "once", at: "2099-01-01T09:00:00.000Z" },
      action: { kind: "sessionPrompt", text },
    });

    gateway.script([
      () => fauxAssistantMessage("Ready for scheduled checks."),
      () => fauxAssistantMessage([fauxToolCall("read", { path: "notes.txt" }, { id: "lock-automation-read" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("The scheduled check found: lock notes."),
      () => fauxAssistantMessage([fauxToolCall("read", { path: "notes.txt" }, { id: "lock-workspace-read" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("The workspace check found: lock notes."),
    ]);
    // A chat exists for the catalog once its first turn is persisted; only then can it be a target.
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId, text: "get ready for scheduled checks" })).ok).toBe(true);
    await gateway.settled(sessionId);
    const existing = await runNow(definition({ kind: "existingSession", sessionId }, "run the scheduled notes check", "Lock session check"), "session prompt");
    const workspace = await runNow(definition({ kind: "workspace", cwd: gateway.cwd, sessionPolicy: "newPerRun" },
      "run the workspace notes check", "Lock workspace check"), "workspace prompt");

    const reads: Array<[string, Record<string, unknown>]> = [
      ["automation.get", { automationId: existing.automationId }],
      ["automation.run.get", { automationId: existing.automationId, runId: existing.runId }],
      ["automation.get", { automationId: workspace.automationId }],
      ["automation.run.get", { automationId: workspace.automationId, runId: workspace.runId }],
      ["session.transcript", { sessionId }],
    ];
    for (const [method, params] of reads) {
      const read = await phone.request(method, params);
      expect(read.ok, `${method} ${JSON.stringify(read)}`).toBe(true);
    }
    const recorded = gateway.record();
    const receipts = join(gateway.tronHome, "gateway", "command-receipts");
    const completions = [(await assistantEntryIds(gateway, sessionId)).at(-1), (await assistantEntryIds(gateway, workspace.executionSessionId)).at(-1)];
    const trace = {
      lock: "automation-owned-run",
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      sessionJsonl: await gateway.canonical(sessionId),
      workspaceJsonl: await gateway.canonical(workspace.executionSessionId),
      automations: {
        session: await gateway.file(automationFile(existing.automationId)),
        workspace: await gateway.file(automationFile(workspace.automationId)),
      },
      // Receipt file names are digests of the device identity; their contents are the contract.
      commandReceipts: (await Promise.all((await gateway.tree(receipts)).map(async (name) =>
        normalizeTraceValue(JSON.parse(await readFile(join(receipts, name), "utf8")), gateway.normalization))))
        .sort((left, right) => String((left as { commandId?: string }).commandId).localeCompare(String((right as { commandId?: string }).commandId))),
      // The owned operation's runtime marker is cleared once the scheduler acknowledges the terminal.
      runtimeMarkers: await gateway.tree(join(gateway.tronHome, "gateway", "runtime-markers")),
    };
    const stable = stabilizeDerivedIdentities(trace as unknown as TraceValue);
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, "automation-owned-run"), trace: stable, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect([existing.state, workspace.state]).toEqual(["succeeded", "succeeded"]);
        expect(existing.executionSessionId).toBe(sessionId);
        // Each run names the final assistant entry of its own session as its completion.
        expect([existing.assistantCompletionId, workspace.assistantCompletionId]).toEqual(completions);
        expect(trace.commandReceipts.map((receipt) => (receipt as { method?: string }).method)).toEqual([
          "session.create", "session.prompt", "automation.create", "automation.runNow", "automation.create", "automation.runNow",
        ]);
        expect(trace.runtimeMarkers).toEqual([]);
        expect(workspace.executionSessionId).not.toBe(sessionId);
        expect(recorded.providerRequests).toHaveLength(5);
        for (const [jsonl, text] of [[trace.sessionJsonl, "run the scheduled notes check"], [trace.workspaceJsonl, "run the workspace notes check"]] as const) {
          const roles = jsonl.flatMap((entry) => {
            const role = (entry as { message?: { role?: string } }).message?.role;
            return role ? [role] : [];
          });
          expect(roles.slice(-4)).toEqual(["user", "assistant", "toolResult", "assistant"]);
          expect(JSON.stringify(jsonl)).toContain(text);
        }
      },
    });
  });
});
