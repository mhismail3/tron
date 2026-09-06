import { once } from "node:events";
import { Worker } from "node:worker_threads";
import { parseSessionEntries, type FileEntry } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { branchFromParsedSession, type ParsedSessionBranch } from "./session-branch.js";

const header = {
  type: "session",
  version: 3,
  id: "child-session",
  timestamp: "2026-01-01T00:00:00.000Z",
  cwd: "/tmp/child",
  parentSession: "/tmp/parent.jsonl",
} as const;

function entriesWithParents(parents: Array<string | null>, ids = parents.map((_, index) => `entry-${index}`)): FileEntry[] {
  const lines = [header, ...ids.map((id, index) => ({
    type: "custom",
    customType: "test",
    id,
    parentId: parents[index]!,
    timestamp: `2026-01-01T00:00:0${index}.000Z`,
    data: { id },
  }))];
  return parseSessionEntries(lines.map((entry) => JSON.stringify(entry)).join("\n"));
}

async function parseInWorker(entries: FileEntry[]): Promise<ParsedSessionBranch | undefined> {
  const worker = new Worker(`
    const { parentPort, workerData } = require("node:worker_threads");
    import(workerData).then(({ branchFromParsedSession }) => {
      parentPort.postMessage({ type: "ready" });
      parentPort.on("message", entries => {
        parentPort.postMessage({ type: "result", value: branchFromParsedSession(entries) });
      });
    }).catch(error => parentPort.postMessage({ type: "error", message: String(error) }));
  `, {
    eval: true,
    execArgv: ["--experimental-strip-types"],
    workerData: new URL("./session-branch.ts", import.meta.url).href,
  });
  try {
    expect(await once(worker, "message", { signal: AbortSignal.timeout(5_000) })).toEqual([{ type: "ready" }]);
    const result = once(worker, "message", { signal: AbortSignal.timeout(1_000) });
    worker.postMessage(entries);
    const [message] = await result;
    if (message.type === "error") throw new Error(message.message);
    expect(message.type).toBe("result");
    return message.value as ParsedSessionBranch | undefined;
  } finally {
    await worker.terminate();
  }
}

describe("read-only session branch parser", () => {
  it.each([
    { name: "self-cycle", entries: entriesWithParents(["entry-0"]) },
    { name: "two-node cycle", entries: entriesWithParents(["entry-1", "entry-0"]) },
    {
      name: "ancestry entering a cycle",
      entries: entriesWithParents(["cycle-b", "cycle-a", "cycle-a"], ["cycle-a", "cycle-b", "leaf"]),
    },
  ])("rejects $name without blocking the test process", async ({ entries }) => {
    await expect(parseInWorker(entries)).resolves.toBeUndefined();
  });

  it("preserves header identity and selected leaf-to-root ordering with a shared ancestor and sibling", () => {
    const entries = entriesWithParents([null, "ancestor", "ancestor"], ["ancestor", "sibling", "selected"]);
    expect(branchFromParsedSession(entries)).toEqual({
      sessionId: "child-session",
      parentSession: "/tmp/parent.jsonl",
      branch: [
        expect.objectContaining({ id: "ancestor", parentId: null }),
        expect.objectContaining({ id: "selected", parentId: "ancestor" }),
      ],
      leafEntryId: "selected",
    });
  });

  it("rejects ancestry with a missing parent", () => {
    const entries = entriesWithParents(["missing"]);
    expect(branchFromParsedSession(entries)).toBeUndefined();
  });
});
