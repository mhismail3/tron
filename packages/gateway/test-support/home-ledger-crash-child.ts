import { writeFileSync } from "node:fs";
import { HomeOwner } from "../src/home/home-owner.js";
import { TronWorkspace } from "../src/workspace/tron-workspace.js";

const [tronHome, sessionId, phase, marker] = process.argv.slice(2);
if (!tronHome || !sessionId || !marker || phase !== "after") throw new Error("expected crash fixture arguments");
const owner = new HomeOwner({
  tronHome,
  trust: {} as never,
  workspace: new TronWorkspace(tronHome),
  sessions: {
    chapterMetrics: async () => ({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true }),
  } as never,
  memorySummarizer: () => ({ summarizer: async () => { throw new Error("unused"); } }),
});
await owner.initialize();
const exposed = owner as unknown as { writeLocked(record: unknown): Promise<void> };
const write = exposed.writeLocked.bind(owner);
exposed.writeLocked = async record => {
  await write(record);
  writeFileSync(marker, "after\n");
  await new Promise<void>(() => {});
};
await owner.chapterQuiescent(sessionId);
