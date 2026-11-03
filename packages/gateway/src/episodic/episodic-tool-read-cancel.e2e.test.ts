import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it } from "vitest";
import { singleChapterSource } from "../../test-support/episodic-chapter-source.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { resolveLimits } from "./episodic-contract.js";
import { EpisodicMemory } from "./episodic-memory.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const step of cleanup.splice(0).reverse()) await step(); });

// Home's memory tools (`memory_search`, `zoom`, `date`) ingest under the memory's
// lock before reading. An ingest or checkpoint holding that lock kept a stopped
// `memory_search` running for minutes; the tool's Stop must end its wait.
it("a tool read's ingest wait ends when its signal aborts while the memory's lock is held", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-episodic-cancel-"));
  cleanup.push(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, "project"), sessionDir = join(root, "sessions");
  await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
  const manager = SessionManager.create(cwd, sessionDir);
  manager.appendMessage({ role: "user", content: "first prompt", timestamp: Date.now() });
  const workspace = new TronWorkspace(join(root, "home"));
  cleanup.push(() => workspace.dispose());
  const memory = await EpisodicMemory.open({
    workspace,
    sessionId: manager.getSessionId(),
    sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!),
    limits: resolveLimits({}),
    summarizer: async () => { throw new Error("no summaries in this case"); },
  });
  cleanup.push(() => memory.dispose());

  let release!: () => void;
  let holding!: () => void;
  const held = new Promise<void>(resolve => { holding = resolve; });
  const lock = memory.withBrowserRead(() => { holding(); return new Promise<void>(resolve => { release = resolve; }); });
  await held;

  const controller = new AbortController();
  const read = memory.entriesIngested(manager.getSessionId(), controller.signal).then(() => "ingested", () => "abandoned");
  controller.abort(new Error("tool stopped"));
  const outcome = await Promise.race([read, new Promise(resolve => setTimeout(() => resolve("still waiting"), 1_000))]);
  release();
  await lock;
  expect(outcome).toBe("abandoned");
});
