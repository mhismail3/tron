import { writeFileSync } from "node:fs";
import { HomeOwner } from "../src/modules/home/home-owner.js";
import { homeTaskPolicy } from "../src/modules/home/home-task-worker-choice.js";
import { TronWorkspace } from "../src/workspace/tron-workspace.js";

const [tronHome, sessionId, marker] = process.argv.slice(2);
if (!tronHome || !sessionId || !marker) throw new Error("expected crash fixture arguments");
const owner = new HomeOwner({
  tronHome,
  trust: {} as never,
  workspace: new TronWorkspace(tronHome),
  taskPolicy: homeTaskPolicy({ settings: () => undefined, modelQueueOf: async () => [], modelRuntime: () => undefined }, { inspect: async () => { throw new Error("unused task target"); } }),
  runtimes: {
    serializeSessionMutation: async <T>(_id: string, commit: () => Promise<T>) => commit(),
    noteSessionListChanged: () => {},
    liveRuntime: () => undefined,
  } as never, agentDir: "/nonexistent-agent-dir",
  knowledge: () => undefined,
  sessions: {
    chapterMetrics: async () => ({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true }),
    hasConversation: async () => false,
  } as never,
  memoryModels: async () => [],
  memorySummarizer: () => async () => { throw new Error("unused"); },
});
await owner.initialize();
const exposed = owner as unknown as { writeLocked(record: unknown): Promise<void> };
const write = exposed.writeLocked.bind(owner);
exposed.writeLocked = async record => {
  await write(record);
  process.stdin.resume();
  writeFileSync(marker, "after\n");
  await new Promise<void>(() => {});
};
await owner.chapterQuiescent(sessionId);
