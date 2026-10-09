import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runInNewContext } from "node:vm";
import { setFlagsFromString } from "node:v8";
import { expect, it } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EPISODIC_DEFAULTS, type EpisodicLimits } from "./episodic-contract.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { readCanonicalHomeDeltas, readCanonicalHomeIndex, type HomeSourceChapter } from "./home-source.js";

/*
 * Scale measurements, run by `npm run test:scale`. Each case retains
 * `test-results/home-memory/*.json` so the numbers can be regenerated and read
 * from the same command. The reports are measurements, not proof of allocation
 * peaks or power-loss behavior.
 */

const TIMESTAMP = "2026-01-01T00:00:00.000Z";

/** Writes sealed and active chapters; `text` gives each message's content. */
async function writeChapters(root: string, chapterCount: number, messagesPerChapter: number,
  text: (chapter: number, index: number) => string): Promise<HomeSourceChapter[]> {
  const chapters: HomeSourceChapter[] = [];
  for (let chapter = 0; chapter < chapterCount; chapter++) {
    const sessionId = `chapter-${chapter}`;
    const path = join(root, `${sessionId}.jsonl`);
    const lines = [JSON.stringify({ type: "session", version: 3, id: sessionId, timestamp: TIMESTAMP, cwd: root })];
    for (let index = 0; index < messagesPerChapter; index++) {
      lines.push(JSON.stringify({ id: `${chapter}-${index}`, parentId: index === 0 ? null : `${chapter}-${index - 1}`, type: "message", timestamp: TIMESTAMP,
        message: { role: "user", content: text(chapter, index), timestamp: 0 } }));
    }
    await writeFile(path, `${lines.join("\n")}\n`);
    chapters.push({ sessionId, path, sealed: chapter < chapterCount - 1 });
  }
  return chapters;
}

/** Ingests the whole Home history once and reports live heap after GC. */
async function measureHomeHeap(root: string, chapters: HomeSourceChapter[], options: {
  limits?: Partial<EpisodicLimits>; ledgerRevision: number;
}): Promise<{ messages: number; samples: number[]; retained: number }> {
  setFlagsFromString("--expose_gc"); const collect = runInNewContext("gc") as () => void;
  const workspace = new TronWorkspace(join(root, "home"));
  let memory: EpisodicMemory | undefined;
  try {
    collect(); const baseline = process.memoryUsage().heapUsed; const samples: number[] = [];
    memory = await EpisodicMemory.open({ workspace, sessionId: "home",       sessionSource: {
        read: async function* (cursor, limits) {
          for await (const cut of readCanonicalHomeDeltas({ homeId: "home", ledgerRevision: options.ledgerRevision, chapters }, cursor, limits)) {
            collect(); samples.push(process.memoryUsage().heapUsed - baseline); yield cut;
          }
        },
        branchAtCursor: (cursor, limits) => readCanonicalHomeIndex({ homeId: "home", ledgerRevision: options.ledgerRevision, chapters }, cursor, limits),
      },
      // A provider's reply is a fresh string. A slice of the prompt would keep the
      // whole prompt (here the 128 KB context block) alive with each node's summary.
      summarizer: async request => fauxAssistantMessage(Buffer.from(request.turns.at(-1)!.text.slice(-100), "utf8").toString("utf8")),
      limits: options.limits, sleep: async () => {},
    });
    await memory.entriesCommitted("home");
    const messages = memory.status().messages;
    await memory.entriesCommitted("home");
    collect(); const retained = process.memoryUsage().heapUsed - baseline;
    return { messages, samples, retained };
  } finally { await memory?.dispose(); await workspace.dispose(); }
}

async function reportFile(name: string, report: unknown): Promise<void> {
  await mkdir("test-results/home-memory", { recursive: true });
  await writeFile(`test-results/home-memory/${name}`, JSON.stringify(report, null, 2) + "\n");
}

it("bounds live raw-source heap independently of aggregate Home chapter bytes", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-home-heap-"));
  try {
    const chapters = await writeChapters(root, 4, 64, (chapter, index) => `fact ${chapter}-${index} ` + "x".repeat(256 * 1024));
    const { messages, samples, retained } = await measureHomeHeap(root, chapters, {
      ledgerRevision: 4, limits: { recordCapChars: 256, viewBytes: 4096, jobs: 2, retryMs: 1 },
    });
    expect(messages).toBe(256);
    const report = { chapters: 4, canonicalBytesAtLeast: 64 * 1024 * 1024, messages, samples, retained, bound: 32 * 1024 * 1024 };
    await reportFile("heap.json", report);
    expect(Math.max(...samples)).toBeLessThan(report.bound);
    expect(retained).toBeLessThan(report.bound);
  } finally { await rm(root, { recursive: true, force: true }); }
}, 60000);

it("measures retained Home heap at production record caps for a 2k-message history", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-home-heap-production-"));
  try {
    // Most turns are a few hundred characters; one in twenty is a long answer.
    // Deterministic, so the measured history is the same on every run.
    const text = (chapter: number, index: number): string => {
      const size = index % 20 === 0 ? 6_000 : 400 + ((index * 37) % 1_200);
      return `turn ${chapter}-${index} ` + "lorem ipsum dolor sit amet ".repeat(Math.ceil(size / 27)).slice(0, size);
    };
    const chapters = await writeChapters(root, 4, 500, text);
    const { messages, samples, retained } = await measureHomeHeap(root, chapters, { ledgerRevision: 4 });
    expect(messages).toBe(2_000);
    const report = {
      chapters: 4, messages, retainedBytes: retained, retainedBytesPerMessage: Math.round(retained / messages),
      peakSampleBytes: Math.max(...samples), production: {
        recordCapChars: EPISODIC_DEFAULTS.recordCapChars, capChars: EPISODIC_DEFAULTS.capChars, viewBytes: EPISODIC_DEFAULTS.viewBytes,
      },
    };
    await reportFile("heap-production.json", report);
    // The catalog keeps each message's projected text and its node topology, a few
    // kilobytes at these sizes (about 1.25 KB of text per message). Nothing of a
    // summary's prompt may survive, so the bound sits well under the view's 128 KB.
    expect(retained / messages).toBeLessThan(8 * 1_024);
  } finally { await rm(root, { recursive: true, force: true }); }
}, 300_000);
