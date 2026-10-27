import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { fauxAssistantMessage, fauxToolCall, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { singleChapterSource } from "../../../test-support/episodic-chapter-source.js";
import { EpisodicStore } from "../../episodic/episodic-store.js";
import { EpisodicMemory } from "../../episodic/episodic-memory.js";
import { EPISODIC_DEFAULTS } from "../../episodic/episodic-contract.js";
import { TronWorkspace } from "../../workspace/tron-workspace.js";

// Reproduces the old draft's unexplained 10→9 delta without changing an oracle.
// The old/new tool text is from the retained synthetic lock trace, not live notes.
it("a longer delegate diagnostic crosses the free-parent byte limit, without losing a message", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-lock-home-activation-wake-"));
  // Keep this synthetic input independent of session storage/TMPDIR while
  // preserving byte pressure on both sides of the 512-byte free-parent limit.
  const target = "/fixture/home-profile-episode/projects/retained-synthetic-lock-trace/workspaces/delegated-task/project/notes/workspace";
  const samples = [];
  try {
    for (const diagnostic of [false, true]) {
      const directory = join(root, diagnostic ? "after" : "before");
      await mkdir(directory, { recursive: true });
      const manager = SessionManager.create(join(root, "workspace"), directory);
      const admission = "Task admitted; a report is required for its result. "
        + (diagnostic ? "Profile diagnostic: Knowledge is unavailable; preferences could not be applied. " : "")
        + "Worker: tron-lock-home-activation-wake/faux-1 (same as Home), thinking off.";
      manager.appendMessage({ role: "user", content: "Delegate the lock work.", timestamp: Date.now() } satisfies Message);
      manager.appendMessage(fauxAssistantMessage([fauxToolCall("delegate", { taskId: "lock-task", intent: "Summarize notes.txt in the lock project.", target, title: "Lock task" }, "delegate") ]));
      manager.appendMessage({ role: "toolResult", toolCallId: "delegate", toolName: "delegate", content: [{ type: "text", text: admission }], isError: false, timestamp: Date.now() } satisfies Message);
      manager.appendMessage(fauxAssistantMessage("Delegated the lock task."));
      manager.appendMessage({ role: "user", content: "Read the result.", timestamp: Date.now() } satisfies Message);
      manager.appendMessage(fauxAssistantMessage("The report is ready."));
      const owner = new TronWorkspace(join(directory, "home"));
      const paidRequests: number[] = [];
      const memory = await EpisodicMemory.open({ workspace: owner, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer: async request => { paidRequests.push(request.turns.length); return fauxAssistantMessage("This case must not buy a summary."); } });
      try {
        await memory.entriesCommitted(manager.getSessionId());
        const status = memory.status();
        const persisted = await new EpisodicStore(owner, manager.getSessionId(), EPISODIC_DEFAULTS.maxStoreLineBytes).read();
        const firstFour = [...persisted.nodes.values()].filter(node => node.level === 0).sort((a, b) => a.index - b.index).slice(0, 4).map(node => node.text).join(" ");
        samples.push({ diagnostic, messages: status.messages, nodes: status.nodes, view: status.view, rawTargetBytes: Buffer.byteLength(target), firstFourBytes: Buffer.byteLength(firstFour), limit: EPISODIC_DEFAULTS.nodeBytes, paidRequests });
        expect(status.messages).toBe(6);
        expect(paidRequests).toHaveLength(0);
        expect(status.view.unbuilt).toBe(0);
      } finally { await memory.dispose(); await owner.dispose(); }
    }
    expect(samples[0]!.firstFourBytes).toBeLessThanOrEqual(samples[0]!.limit);
    expect(samples[1]!.firstFourBytes).toBeGreaterThan(samples[1]!.limit);
    expect(samples[0]!.nodes.total).toBe(10);
    expect(samples[1]!.nodes.total).toBe(9);
    await mkdir("test-results/home-profile", { recursive: true });
    await writeFile("test-results/home-profile/episodic-cause.json", JSON.stringify(samples, null, 2) + "\n");
  } finally { await rm(root, { recursive: true, force: true }); }
});
