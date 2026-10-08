import { appendFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runInNewContext } from "node:vm";
import { setFlagsFromString } from "node:v8";
import { expect, it } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { readCanonicalHomeDeltas, readCanonicalHomeIndex } from "./home-source.js";

it("bounds live raw-source heap independently of aggregate Home chapter bytes", async () => {
  setFlagsFromString("--expose_gc"); const collect = runInNewContext("gc") as () => void;
  const root = await mkdtemp(join(tmpdir(), "tron-home-heap-"));
  const workspace = new TronWorkspace(join(root, "home"));
  let memory: EpisodicMemory | undefined;
  try {
    const chapters = [];
    for (let chapter = 0; chapter < 4; chapter++) {
      const sessionId = `chapter-${chapter}`; const path = join(root, sessionId + ".jsonl");
      chapters.push({ sessionId, path, sealed: chapter < 3 });
      await writeFile(path, JSON.stringify({ type: "session", version: 3, id: sessionId, timestamp: "2026-01-01T00:00:00.000Z", cwd: root }) + "\n");
      for (let index = 0; index < 64; index++) await appendFile(path, JSON.stringify({ id: `${chapter}-${index}`, parentId: index === 0 ? null : `${chapter}-${index - 1}`, type: "message", timestamp: "2026-01-01T00:00:00.000Z", message: { role: "user", content: `fact ${chapter}-${index} ` + "x".repeat(256 * 1024), timestamp: 0 } }) + "\n");
    }
    collect(); const baseline = process.memoryUsage().heapUsed; const samples: number[] = [];
    memory = await EpisodicMemory.open({ workspace, sessionId: "home", sessionFile: chapters[3]!.path,
      sessionSource: {
        read: async function* (cursor, limits) {
          for await (const cut of readCanonicalHomeDeltas({ homeId: "home", ledgerRevision: 4, chapters }, cursor, limits)) {
            collect(); samples.push(process.memoryUsage().heapUsed - baseline); yield cut;
          }
        },
        branchAtCursor: (cursor, limits) => readCanonicalHomeIndex({ homeId: "home", ledgerRevision: 4, chapters }, cursor, limits),
      },
      summarizer: async request => fauxAssistantMessage(request.turns.at(-1)!.text.slice(-100)),
      limits: { recordCapChars: 256, viewBytes: 4096, jobs: 2, retryMs: 1 }, sleep: async () => {},
    });
    await memory.entriesCommitted("home");
    expect(memory.status().messages).toBe(256);
    await memory.entriesCommitted("home");
    collect(); const retained = process.memoryUsage().heapUsed - baseline;
    const report = { chapters: 4, canonicalBytesAtLeast: 64 * 1024 * 1024, messages: 256, samples, retained, bound: 32 * 1024 * 1024 };
    await mkdir("test-results/home-memory", { recursive: true });
    await writeFile("test-results/home-memory/heap.json", JSON.stringify(report, null, 2) + "\n");
    expect(Math.max(...samples)).toBeLessThan(report.bound);
    expect(retained).toBeLessThan(report.bound);
  } finally { await memory?.dispose(); await workspace.dispose(); await rm(root, { recursive: true, force: true }); }
}, 60000);
