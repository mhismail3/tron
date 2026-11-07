import { appendFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, expect, it, vi } from "vitest";
import { EpisodicSourceChangedError, readCanonicalSessionFile } from "./canonical-reader.js";

/** One real change to the file at an exact point of the reader's own handle use:
 * before its first read, or just before the stat that closes its first pass. */
const changeDuringRead = vi.hoisted(() => ({
  path: undefined as string | undefined,
  at: "firstRead" as "firstRead" | "endStat",
  change: undefined as (() => Promise<void>) | undefined,
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    open: async (...args: Parameters<typeof actual.open>) => {
      const handle = await actual.open(...args);
      if (String(args[0]) !== changeDuringRead.path || !changeDuringRead.change) return handle;
      const fire = async () => {
        const change = changeDuringRead.change;
        changeDuringRead.change = undefined;
        await change?.();
      };
      const target = handle as unknown as Record<"read" | "stat", (...values: unknown[]) => Promise<unknown>>;
      const read = target.read.bind(handle);
      const stat = target.stat.bind(handle);
      let stats = 0;
      target.read = async (...values) => { if (changeDuringRead.at === "firstRead") await fire(); return read(...values); };
      target.stat = async (...values) => { if (changeDuringRead.at === "endStat" && ++stats === 2) await fire(); return stat(...values); };
      return handle;
    },
  };
});

const roots: string[] = [];
afterEach(async () => {
  changeDuringRead.path = undefined;
  changeDuringRead.at = "firstRead";
  changeDuringRead.change = undefined;
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function session(): Promise<{ manager: SessionManager; path: string; sessionId: string }> {
  const root = await mkdtemp(join(tmpdir(), "tron-canonical-reader-"));
  roots.push(root);
  const manager = SessionManager.create(root, join(root, "sessions"));
  manager.appendMessage({ role: "user", content: "Start", timestamp: 1 });
  manager.appendMessage(fauxAssistantMessage("Settled"));
  return { manager, path: manager.getSessionFile()!, sessionId: manager.getSessionId() };
}

it("returns the exact prefix of a session that the SDK appends to during an append-stable read", async () => {
  const { manager, path, sessionId } = await session();
  const before = manager.getEntries().map(entry => entry.id);
  const read = (appendStable: boolean) => {
    changeDuringRead.path = path;
    changeDuringRead.change = async () => { manager.appendCustomEntry("tron-test-late-append", { appendStable }); };
    return readCanonicalSessionFile({ path, sessionId, appendStable });
  };
  await expect(read(false), "an exact cut still refuses any change").rejects.toBeInstanceOf(EpisodicSourceChangedError);
  const prefix = before.concat(manager.getEntries().at(-1)!.id);
  expect((await read(true)).map(entry => entry.id)).toEqual(prefix);
  expect(manager.getEntries()).toHaveLength(prefix.length + 1);
});

it("refuses an append-stable read when the bytes it read were rewritten in place", async () => {
  const { path, sessionId } = await session();
  const bytes = await readFile(path, "utf8");
  changeDuringRead.path = path;
  changeDuringRead.at = "endStat";
  changeDuringRead.change = async () => {
    // After the first pass read the original bytes: same inode, longer file,
    // different prefix. Not an append.
    await writeFile(path, bytes.replace("Settled", "Changed"));
    await appendFile(path, "\n");
  };
  await expect(readCanonicalSessionFile({ path, sessionId, appendStable: true }))
    .rejects.toBeInstanceOf(EpisodicSourceChangedError);
});

it("reports a malformed rewrite of already-read bytes as a changed source, not a malformed session", async () => {
  const { path, sessionId } = await session();
  const bytes = await readFile(path, "utf8");
  changeDuringRead.path = path;
  changeDuringRead.at = "endStat";
  changeDuringRead.change = async () => {
    // After the first pass: same inode, grown, and its old prefix no longer parses.
    await writeFile(path, bytes.replace(/"type":"message"/, '"type":"message"\u0000'));
    await appendFile(path, bytes.split("\n").at(-2)!.replace(/"id":"[^"]+"/, '"id":"late0000"') + "\n");
  };
  await expect(readCanonicalSessionFile({ path, sessionId, appendStable: true }))
    .rejects.toBeInstanceOf(EpisodicSourceChangedError);
});
