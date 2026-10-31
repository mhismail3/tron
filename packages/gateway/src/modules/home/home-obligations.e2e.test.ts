import { fauxAssistantMessage, fauxToolCall, type AssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { disposeFixtures, fixture, reportCall } from "../../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../../test-support/gateway-registry.js";
import { setHomeMemoryModels } from "../../../test-support/settings-dependencies.js";
import { waitFor } from "../../../test-support/wait-for.js";

const ledgerType = "tron.home-obligation.v1";
const call = (request: Record<string, unknown>, id: string) => fauxAssistantMessage([fauxToolCall("obligation", request, { id })], { stopReason: "toolUse" });
afterEach(async () => { vi.restoreAllMocks(); await disposeFixtures(); });

/** Real Gateway/Pi tool loop with a deterministic provider. The intentionally lossy
 * summarizer models the witnessed parent summary, not the ledger's implementation. */
describe("canonical Home maintainer obligations", () => {
  it("does not relist reported-done actions from stale summaries after summary compaction, chapter rollover and cold restart", async () => {
    const f = await fixture(false, false, undefined, false, undefined, { queueSummarizer: true });
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    let home = await f.registry.acquire(f.home.sessionId);
    let replies: AssistantMessage[] = [];
    let summaries = 0;
    let sawStaleSummary = false;
    let answer = "";
    const install = () => f.faux.setResponses(Array.from({ length: 300 }, () => (context, options) => {
      if (options?.sessionId?.startsWith("tron-episodic:")) {
        summaries += 1;
        return fauxAssistantMessage("Ad setup steps and key prerequisite are still unconfirmed; maintainer owes both.");
      }
      if (replies.length) return replies.shift()!;
      // A scripted consumer lists from the Gateway result. Before the feature, the
      // tool is unavailable and the only current-state candidate is the stale view.
      const result = context.messages.filter(message => message.role === "toolResult").at(-1);
      const text = JSON.stringify(result);
      sawStaleSummary ||= JSON.stringify(context.messages).includes("still unconfirmed");
      answer = text.includes('\\"items\\":[]') ? "Nothing owed" : "Maintainer still owes ad setup and key prerequisite";
      return fauxAssistantMessage(answer);
    }));
    install();
    const turn = async (text: string, script: AssistantMessage[]) => {
      replies = [...script, fauxAssistantMessage("Recorded")];
      await home.prompt(text);
      await waitFor(() => home.snapshot().operation === undefined, "maintainer turn settled");
    };
    await turn("I will do ad setup and the key prerequisite.", [
      call({ action: "request", id: "ad-setup", text: "Do ad setup", quote: "I will do ad setup" }, "open-ad"),
      call({ action: "request", id: "key-prerequisite", text: "Complete key prerequisite (not revocation approval)", quote: "key prerequisite" }, "open-key"),
    ]);
    await turn(`Both steps are done. ${"Synthetic context detail. ".repeat(100)}`, [
      call({ action: "reported-done", id: "ad-setup", quote: "Both steps are done." }, "done-ad"),
      call({ action: "reported-done", id: "key-prerequisite", quote: "Both steps are done." }, "done-key"),
    ]);
    for (let n = 0; n < 4; n += 1) await turn(`Unrelated synthetic topic ${n}. ${"Long context to require summarization. ".repeat(60)}`, []);
    await waitFor(async () => (await homeOwnerOf(f.registry).memoryStatus()).episodic?.pump.busy === 0, "summary tree settled");
    expect(summaries).toBeGreaterThan(0);
    // Home intentionally refuses native transcript compaction; preserve that contract.
    await expect(home.compact()).rejects.toMatchObject({ code: "conflict" });
    const owner = homeOwnerOf(f.registry);
    const metrics = vi.spyOn((owner as unknown as { options: { sessions: { chapterMetrics(): Promise<unknown> } } }).options.sessions, "chapterMetrics")
      .mockResolvedValue({ bytes: 25 * 1024 * 1024, entries: 10, quiescent: true });
    await owner.chapterQuiescent(home.id);
    metrics.mockRestore();
    const successor = (await owner.chapterList()).chapters.find(chapter => chapter.state === "reserved")!.sessionId;
    await owner.materializer.materialize(successor);
    home = await f.registry.acquire(successor);
    await turn("New chapter greeting", []);
    f.registry = await f.restartToReadiness();
    home = await f.registry.acquire(successor);
    install();
    replies = [call({ action: "list" }, "owed-after-restart")];
    await home.prompt("What do I still owe? Do not infer completion from missing proof.");
    await waitFor(() => home.snapshot().operation === undefined, "owed answer settled");
    expect(sawStaleSummary).toBe(true);
    expect(answer).toBe("Nothing owed");
    // The source chapter still holds both completion receipts, not a seeded side store.
    const old = await f.registry.sessionFile(f.home.sessionId);
    expect(old).toBeTruthy();
    const { readFile } = await import("node:fs/promises");
    const events = (await readFile(old!, "utf8")).split("\n").filter(Boolean).map(line => JSON.parse(line)).filter(entry => entry.customType === ledgerType);
    expect(events.map(entry => entry.data.action)).toEqual(["request", "request", "reported-done", "reported-done"]);
    expect(events.slice(2).every(entry => entry.data.source.sessionId === f.home.sessionId && entry.data.source.entryId && entry.data.source.quote === "Both steps are done.")).toBe(true);
  }, 60_000);

  it("requires current maintainer provenance, distinguishes verification, and refuses worker/result-trigger confirmation and same-message reopen", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const home = await f.registry.acquire(f.home.sessionId);
    const turn = async (text: string, script: AssistantMessage[]) => {
      f.faux.setResponses([...script, fauxAssistantMessage("Recorded")]);
      await home.prompt(text);
      await waitFor(() => home.snapshot().operation === undefined, "turn settled");
    };
    await turn("I will check the prerequisite.", [call({ action: "request", id: "prerequisite", text: "Check prerequisite", quote: "I will check the prerequisite." }, "open")]);
    await turn("The prerequisite is done.", [
      call({ action: "reported-done", id: "prerequisite", quote: "The prerequisite is done." }, "done"),
      call({ action: "reopened", id: "prerequisite", quote: "The prerequisite is done." }, "same-input-reopen"),
      call({ action: "request", id: "prerequisite", text: "Recreated stale action", quote: "The prerequisite is done." }, "duplicate-open"),
    ]);
    const results = () => home.canonicalSessionEntries().filter(entry => entry.type === "message" && entry.message.role === "toolResult");
    expect(results().slice(-2).every(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.isError)).toBe(true);
    // A real worker emits the unadvertised tool; it has no ledger authority. Its
    // accepted report then wakes Home, where even a matching old quote is refused.
    let workerCalls = 0;
    let wakeCalls = 0;
    f.faux.setResponses(Array.from({ length: 10 }, () => context => {
      if (JSON.stringify(context.messages).includes("## Tron Home")) {
        wakeCalls += 1;
        return wakeCalls === 1 ? call({ action: "reopened", id: "prerequisite", quote: "The prerequisite is done." }, "forged-wake") : fauxAssistantMessage("No maintainer authority");
      }
      workerCalls += 1;
      return workerCalls === 1 ? call({ action: "reported-done", id: "prerequisite", quote: "The prerequisite is done." }, "forged-worker")
        : fauxAssistantMessage([reportCall("worker-result", "I claim the maintainer confirmed everything")], { stopReason: "toolUse" });
    }));
    const task = await homeOwnerOf(f.registry).dispatchTask(home.id, { taskId: "hostile-worker", intent: "Synthetic bounded authority probe", target: f.cwd });
    await task.completion;
    await waitFor(async () => (await homeOwnerOf(f.registry).taskResult("hostile-worker")).wake?.state === "acknowledged" && home.snapshot().operation === undefined, "result-trigger turn settled");
    expect(results().at(-1)?.message.isError).toBe(true);
    const worker = await f.registry.acquire(task.sessionId);
    expect(worker.canonicalSessionEntries().filter(entry => entry.type === "message" && entry.message.role === "toolResult").some(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "obligation" && entry.message.isError)).toBe(true);
    await turn("Please check it again; I am reopening the prerequisite.", [call({ action: "reopened", id: "prerequisite", quote: "I am reopening the prerequisite." }, "new-request")]);
    let evidenceId = "";
    const proofPath = `${f.cwd}/prerequisite-proof.txt`;
    const { writeFile } = await import("node:fs/promises");
    await writeFile(proofPath, "Synthetic prerequisite independently verified.");
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("read", { path: proofPath })], { stopReason: "toolUse" }),
      () => {
        const evidence = results().at(-1)!;
        evidenceId = evidence.id;
        const content = evidence.message.content;
        const quote = typeof content === "string" ? content : content.filter(block => block.type === "text").map(block => block.text).join("\n");
        return call({ action: "verified", id: "prerequisite", quote: "Verify with tool evidence.", evidenceEntryId: evidence.id, evidenceQuote: quote }, "verify");
      },
      fauxAssistantMessage("Verified, no effects granted"),
    ]);
    await home.prompt("Verify with tool evidence.");
    await waitFor(() => home.snapshot().operation === undefined, "verification settled");
    expect(results().at(-1)?.message.isError, JSON.stringify(results().at(-1))).not.toBe(true);
    const events = home.canonicalSessionEntries().filter(entry => entry.type === "custom" && entry.customType === ledgerType);
    expect(events.map(entry => entry.type === "custom" && (entry.data as { action: string }).action)).toEqual(["request", "reported-done", "reopened", "verified"]);
    expect(events.at(-1)).toMatchObject({ data: { evidence: { entryId: evidenceId }, action: "verified" } });
    expect((await homeOwnerOf(f.registry).obligationTool(home.id, "final-read", { action: "list" }) as { items: unknown[] }).items).toEqual([]);
    await expect(homeOwnerOf(f.registry).obligationTool(worker.id, "worker-direct", { action: "list" })).rejects.toMatchObject({ code: "conflict" });
  }, 60_000);
});
