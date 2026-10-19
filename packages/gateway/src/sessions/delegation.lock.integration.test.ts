import { readFile, realpath } from "node:fs/promises";
import { fauxAssistantMessage, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";
import { startScriptedChild, type ChildModelServer } from "../../test-support/home-task-subagent-child.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { waitFor } from "../../test-support/wait-for.js";

/**
 * Kernel subagent lock (restructure plan §6.4, V3) for the `gateway/delegation`
 * module: one foreground subagent run through the real managed pi-subagents
 * install, a real child Pi process and the real `RuntimeRegistry`. The parent's
 * model is the faux provider; the child's model is the scripted local HTTP model
 * server the Home task subagent cases use, which answers `CHILD-DONE`.
 *
 * This lock enters at the registry, not the WebSocket: the delegation kernel's
 * contract is the session's canonical record and its process activity, which
 * the transport only projects. It runs in the nested serial pass
 * (`vitest.nested.config.ts`) because it activates the managed install and
 * spawns a real child. It records the parent's provider requests, canonical
 * JSONL, the settled subagent process activity and the child's canonical
 * session, compared with `locks/delegation-subagent.golden.json`.
 */

const MODULE = "gateway/delegation";
const BOUND = { boundMs: 30_000 };
const servers: ChildModelServer[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) await server.close();
  await disposeFixtures();
});

function messages(context: TranscriptContext): string[] {
  return context.messages.filter((message) => (message as { role?: unknown }).role !== "system")
    .map((message) => String((message as { role?: unknown }).role));
}

describe("gateway/delegation kernel locks", () => {
  it("subagent: a foreground subagent runs a real child to completion and returns its answer to the parent", async () => {
    const f = await fixture(false, false, undefined, true);
    const server = await startScriptedChild(f);
    servers.push(server);
    const requests: string[][] = [];
    f.faux.setResponses([
      (context) => {
        requests.push(messages(context));
        return fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task: "Lock child task", async: false }, { id: "lock-subagent" })], { stopReason: "toolUse" });
      },
      (context) => { requests.push(messages(context)); return fauxAssistantMessage("The child finished."); },
    ]);
    const slot = await f.registry.create(f.cwd);
    await slot.prompt("delegate the lock task");
    await waitFor(() => !slot.isBusy && !slot.catalogHasActiveSubagents, "the parent and its child to settle", BOUND);
    const roots = [f.root, await realpath(f.root)];
    const normalization = { roots, stableIds: ["lock-subagent"] };
    const canonical = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line));
    const activity = (slot.snapshot().processActivities ?? []).filter((item) => item.kind === "subagent");
    const childFile = canonical.flatMap((entry) => {
      const details = entry.type === "message" && entry.message.role === "toolResult" ? entry.message.details : undefined;
      const results = (details as { results?: Array<{ sessionFile?: string }> } | undefined)?.results ?? [];
      return results.flatMap((result) => result.sessionFile ? [result.sessionFile] : []);
    })[0];
    const child = childFile
      ? (await readFile(childFile, "utf8")).trimEnd().split("\n").map((line) => normalizeTraceValue(JSON.parse(line), normalization))
      : [];
    const trace = {
      lock: "delegation-subagent",
      providerRequests: requests as unknown as TraceValue[],
      canonicalJsonl: canonical.map((entry) => normalizeTraceValue(entry, normalization)),
      processActivity: activity.map((item) => normalizeTraceValue(item, normalization)),
      childJsonl: child,
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        const result = canonical.find((entry) => entry.type === "message" && entry.message.role === "toolResult");
        expect(result?.message.toolName).toBe("subagent");
        expect(result?.message.isError).toBe(false);
        expect(JSON.stringify(result?.message.content)).toContain("CHILD-DONE");
        expect(requests).toHaveLength(2);
        expect(child.length).toBeGreaterThan(0);
        expect(JSON.stringify(child)).toContain("Lock child task");
      },
    });
  }, 60_000);
});
