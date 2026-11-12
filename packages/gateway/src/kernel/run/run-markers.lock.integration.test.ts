import crypto from "node:crypto";
import { lstat, mkdir, mkdtemp, open, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished, vi } from "vitest";
import { RunMarkerStore } from "./run-markers.js";

it("run-markers-paths: mark, complete, reassert, clear, bounds and admission", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-run-markers-"));
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(Date.parse("2026-01-01T00:00:00.000Z"));
  onTestFinished(async () => { vi.useRealTimers(); await rm(home, { recursive: true, force: true }); });
  const advance = (ms: number) => { vi.setSystemTime(Date.now() + ms); };
  const store = new RunMarkerStore(home);
  const directory = join(home, "state", "runtime-markers");
  const all = async () => ({
    evidence: Object.fromEntries([...(await store.evidence())].sort(([a], [b]) => a.localeCompare(b))),
    interrupted: [...await store.interruptedSessionIds()].sort(),
  });
  const at = (minute: number) => `2026-01-01T00:${String(minute).padStart(2, "0")}:00.000Z`;
  const second = (n: number) => `2026-01-01T00:00:0${n}.000Z`;
  const markers = async (): Promise<Record<string, unknown>> => {
    const names = await readdir(directory).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return []; throw error; });
    return Object.fromEntries(await Promise.all(names.sort().map(async (name) =>
      [name.replace(/\.json$/u, ""), JSON.parse(await readFile(join(directory, name), "utf8"))])));
  };
  const doc = (sessionId: string, operations: unknown[]) => ({ version: 2, sessionId, operations });
  const op = (operationId: string, acceptedAt: string, completion?: [string, string]) =>
    ({ operationId, acceptedAt, ...(completion ? { assistantCompletionId: completion[0], assistantCompletedAt: completion[1] } : {}) });
  const ownership = "Run marker operation already owns a different assistant completion";
  const bound = "Run marker completion evidence exceeds its bound";

  expect(await all(), "evidence and interrupted ids before the directory exists").toEqual({ evidence: {}, interrupted: [] });
  expect(await store.evidenceFor("s1"), "evidence for an unknown session").toEqual([]);
  expect(await markers()).toEqual({});
  await store.mark("s1", "op-1");
  expect(await markers(), "mark s1 op-1").toEqual({ s1: doc("s1", [op("op-1", second(0))]) });
  advance(1_000);
  await store.mark("s1", "op-1");
  expect(await markers(), "mark s1 op-1 again is unchanged").toEqual({ s1: doc("s1", [op("op-1", second(0))]) });
  await store.mark("s1", "op-2");
  expect(await markers(), "mark s1 op-2").toEqual({ s1: doc("s1", [op("op-1", second(0)), op("op-2", second(1))]) });
  await store.markAssistantCompletion("s1", "op-2", "c-2", at(1));
  const s1Completed = doc("s1", [op("op-1", second(0)), op("op-2", second(1), ["c-2", at(1)])]);
  expect(await markers(), "complete s1 op-2").toEqual({ s1: s1Completed });
  const inode = async (sessionId: string) => (await lstat(join(directory, `${sessionId}.json`))).ino;
  const completedInode = await inode("s1");
  await store.markAssistantCompletion("s1", "op-2", "c-2", at(1));
  expect(await inode("s1"), "complete s1 op-2 again does not republish the marker").toBe(completedInode);
  for (const [label, run, message] of [
    ["complete s1 op-2 at another time", () => store.markAssistantCompletion("s1", "op-2", "c-2", at(2)), ownership],
    ["complete s1 op-2 with another completion", () => store.markAssistantCompletion("s1", "op-2", "c-3", at(1)), ownership],
    ["complete an unmarked operation", () => store.markAssistantCompletion("s1", "op-9", "c-9", at(1)), "Run marker ownership changed before assistant completion admission"],
    ["an oversized operation id", () => store.markAssistantCompletion("s1", "x".repeat(257), "c-1", at(1)), bound],
    ["an oversized completion id", () => store.markAssistantCompletion("s1", "op-1", "c".repeat(257), at(1)), bound],
    ["an oversized completion time", () => store.markAssistantCompletion("s1", "op-1", "c-1", "t".repeat(129)), bound],
    ["an empty completion id", () => store.markAssistantCompletion("s1", "op-1", "", at(1)), bound],
  ] as const) await expect(run(), label).rejects.toThrow(expect.objectContaining({ message: message }));
  expect(await markers(), "a repeated completion and every refusal commit nothing").toEqual({ s1: s1Completed });

  await store.reassertAssistantCompletion("s1", "op-1", "c-1", at(3));
  const s1Reasserted = doc("s1", [op("op-1", second(0), ["c-1", at(3)]), op("op-2", second(1), ["c-2", at(1)])]);
  expect(await markers(), "reassert s1 op-1 stamps its completion").toEqual({ s1: s1Reasserted });
  const reassertedInode = await inode("s1");
  await store.reassertAssistantCompletion("s1", "op-1", "c-1", at(3));
  expect(await inode("s1"), "reassert s1 op-1 again does not republish the marker").toBe(reassertedInode);
  await expect(store.reassertAssistantCompletion("s1", "op-1", "c-4", at(3)), "reassert with another completion").rejects.toThrow(expect.objectContaining({ message: ownership }));
  await expect(store.reassertAssistantCompletion("s2", "op-r", "c-r", "t".repeat(129)), "reassert with an oversized completion time").rejects.toThrow(expect.objectContaining({ message: bound }));
  expect(await markers(), "a repeated reassertion and its refusals commit nothing").toEqual({ s1: s1Reasserted });
  advance(1_000);
  await store.reassertAssistantCompletion("s2", "op-r", "c-r", at(4));
  const s2 = doc("s2", [op("op-r", second(2), ["c-r", at(4)])]);
  expect(await markers(), "reassert an unmarked s2 operation recreates it").toEqual({ s1: s1Reasserted, s2 });
  for (const id of ["o".repeat(257), ""]) await expect(store.mark("s2", id), `mark ${JSON.stringify(id.slice(0, 8))}`).rejects.toThrow(expect.objectContaining({ message: "Run marker operation identifier exceeds its bound" }));
  for (let index = 1; index <= 15; index += 1) await store.mark("s3", `op-${index}`);
  expect((await store.evidenceFor("s3")).length, "s3 holds fifteen operations").toBe(15);
  await store.reassertAssistantCompletion("s3", "op-16", "c-16", at(5));
  const s3Operations = () => [...Array.from({ length: 15 }, (_v, index) => op(`op-${index + 1}`, second(2))), op("op-16", second(2), ["c-16", at(5)])];
  expect(await markers(), "reassert a sixteenth s3 operation").toEqual({ s1: s1Reasserted, s2, s3: doc("s3", s3Operations()) });
  await expect(store.mark("s3", "op-17"), "mark a seventeenth s3 operation").rejects.toThrow(expect.objectContaining({ message: "Run marker operation bound reached before durable admission" }));
  await expect(store.reassertAssistantCompletion("s3", "op-17", "c-17", at(5)), "reassert a seventeenth s3 operation")
    .rejects.toThrow(expect.objectContaining({ message: "Run marker operation bound reached before terminal ownership reassertion" }));
  await store.reassertAssistantCompletion("s3", "op-1", "c-1", at(5));
  const s3Held = s3Operations();
  s3Held[0] = op("op-1", second(2), ["c-1", at(5)]);
  expect(await markers(), "reassert a held s3 operation at the bound").toEqual({ s1: s1Reasserted, s2, s3: doc("s3", s3Held) });
  expect(await all(), "evidence and interrupted ids").toEqual({ evidence: { s1: s1Reasserted.operations, s2: s2.operations, s3: s3Held }, interrupted: ["s1", "s2", "s3"] });

  await store.clear("s1", "op-9");
  expect(await markers(), "clear an unknown s1 operation is unchanged").toEqual({ s1: s1Reasserted, s2, s3: doc("s3", s3Held) });
  await store.clear("s1", "op-1");
  expect(await markers(), "clear s1 op-1 keeps op-2").toEqual({ s1: doc("s1", [op("op-2", second(1), ["c-2", at(1)])]), s2, s3: doc("s3", s3Held) });
  await store.clear("s1", "op-2");
  expect(await markers(), "clear s1 op-2 removes the marker").toEqual({ s2, s3: doc("s3", s3Held) });
  await store.clear("s3");
  expect(await markers(), "clear all of s3").toEqual({ s2 });
  await store.clear("s9");
  expect(await markers(), "clear all of an unknown session").toEqual({ s2 });
  expect(await all(), "evidence and interrupted ids after clearing").toEqual({ evidence: { s2: s2.operations }, interrupted: ["s2"] });
  {
    let calls = 0;
    let entered!: () => void;
    let release!: () => void;
    const held = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let thirdEntered!: () => void;
    const third = new Promise<void>((resolve) => { thirdEntered = resolve; });
    const lanes = new RunMarkerStore(home, { fileSystem: { open, rename, rm, mkdir: (async (...args: Parameters<typeof mkdir>) => {
      calls += 1;
      if (calls === 2) { entered(); await gate; }
      if (calls === 3) thirdEntered();
      return mkdir(...args);
    }) as typeof mkdir } });
    const first = lanes.mark("s5", "op-a");
    const queued = lanes.mark("s5", "op-b");
    await first;
    await held;
    const late = lanes.mark("s5", "op-c");
    const overtook = await Promise.race([third.then(() => true), new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 500))]);
    release();
    await Promise.all([queued, late]);
    expect(overtook, "a write arriving behind a queued write waits for it").toBe(false);
    expect((await lanes.evidenceFor("s5")).map((operation) => operation.operationId), "and loses no operation").toEqual(["op-a", "op-b", "op-c"]);
    expect(await markers()).toEqual({ s2, s5: doc("s5", ["op-a", "op-b", "op-c"].map((id) => op(id, second(2)))) });
  }
  await store.clear("s5");
  expect(await markers(), "clear all of s5").toEqual({ s2 });

  const operation = (id: string, extra: Record<string, unknown> = {}) => ({ operationId: id, acceptedAt: at(6), ...extra });
  const marker = (sessionId: string, document: unknown) => writeFile(join(directory, `${sessionId}.json`), JSON.stringify(document));
  const written: Record<string, unknown> = {
    "version-1": { version: 1, sessionId: "version-1", operationId: "op", acceptedAt: at(7) },
    "version-3": { version: 3, sessionId: "version-3", operations: [operation("a")] },
    "current-other-session": { version: 2, sessionId: "someone-else", operations: [operation("a")] },
    "current-empty": { version: 2, sessionId: "current-empty", operations: [] },
    "current-object-operations": { version: 2, sessionId: "current-object-operations", operations: { length: 1 } },
    "current-string-operations": { version: 2, sessionId: "current-string-operations", operations: "abc" },
    "current-seventeen": { version: 2, sessionId: "current-seventeen", operations: Array.from({ length: 17 }, (_v, index) => operation(`op-${index}`)) },
    "current-sixteen": { version: 2, sessionId: "current-sixteen", operations: Array.from({ length: 16 }, (_v, index) => operation(`op-${index}`)) },
    "current-duplicate": { version: 2, sessionId: "current-duplicate", operations: [operation("a"), operation("a")] },
    "current-null-operation": { version: 2, sessionId: "current-null-operation", operations: [null] },
    "current-list-id": { version: 2, sessionId: "current-list-id", operations: [operation("a"), { ...operation("b"), operationId: ["b"] }] },
    "current-empty-time": { version: 2, sessionId: "current-empty-time", operations: [operation("a", { acceptedAt: "" })] },
    "current-oversized-time": { version: 2, sessionId: "current-oversized-time", operations: [operation("a", { acceptedAt: "t".repeat(129) })] },
    "current-half-complete": { version: 2, sessionId: "current-half-complete", operations: [operation("a", { assistantCompletedAt: at(9) })] },
    "current-oversized-completion": { version: 2, sessionId: "current-oversized-completion", operations: [operation("a", { assistantCompletionId: "c".repeat(257), assistantCompletedAt: at(9) })] },
    "current-complete": { version: 2, sessionId: "current-complete", operations: [operation("a", { assistantCompletionId: "c-a", assistantCompletedAt: at(9) }), operation("b")] },
  };
  await mkdir(directory, { recursive: true });
  for (const [sessionId, document] of Object.entries(written)) await marker(sessionId, document);
  expect(await markers(), "write hand-made markers").toEqual({ ...written, s2 });
  const sixteen = Array.from({ length: 16 }, (_v, index) => operation(`op-${index}`));
  const admitted: Record<string, unknown[]> = {
    "current-sixteen": sixteen,
    "current-complete": [operation("a", { assistantCompletionId: "c-a", assistantCompletedAt: at(9) }), operation("b")],
  };
  expect(Object.fromEntries(await Promise.all(Object.keys(written).map(async (sessionId) => [sessionId, await store.evidenceFor(sessionId)]))),
    "each hand-made marker's admitted evidence").toEqual(Object.fromEntries(Object.keys(written).map((sessionId) => [sessionId, admitted[sessionId] ?? []])));
  expect(await all(), "evidence and interrupted ids over hand-made markers: every marker file is interrupted, only admitted ones carry evidence")
    .toEqual({ evidence: { ...admitted, s2: s2.operations }, interrupted: [...Object.keys(written), "s2"].sort() });
  await store.mark("current-duplicate", "fresh");
  const afterFresh = { ...written, s2, "current-duplicate": doc("current-duplicate", [op("fresh", second(2))]) };
  expect(await markers(), "mark over an unreadable marker replaces it").toEqual(afterFresh);
  await store.clear("current-complete", "b");
  const afterClear = { ...afterFresh, "current-complete": doc("current-complete", [operation("a", { assistantCompletionId: "c-a", assistantCompletedAt: at(9) })]) };
  expect(await markers(), "clear one operation of the current marker").toEqual(afterClear);
  {
    const foreign = join(directory, `s4.json.${process.pid}.${"ab".repeat(6)}.tmp`);
    await writeFile(foreign, "foreign");
    const original = crypto.randomBytes;
    try {
      crypto.randomBytes = ((size: number) => Buffer.alloc(size, 0xab)) as typeof crypto.randomBytes;
      syncBuiltinESMExports();
      const refusal = await store.mark("s4", "op-1").then(() => "written", (error: NodeJS.ErrnoException) => error.code);
      expect({ refusal, foreignKept: await readFile(foreign, "utf8").catch(() => "removed") }, "a write whose temporary name is taken keeps the foreign file")
        .toEqual({ refusal: "EEXIST", foreignKept: "foreign" });
    } finally {
      crypto.randomBytes = original;
      syncBuiltinESMExports();
      await rm(foreign, { force: true });
    }
  }
  expect(await markers(), "and writes no s4 marker").toEqual(afterClear);
});
