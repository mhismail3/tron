import crypto from "node:crypto";
import { mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { join } from "node:path";
import { it } from "vitest";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { RunMarkerStore } from "./run-markers.js";

/**
 * `gateway/run` mutation-path lock for the run-marker store (plan §6.5 V4, §6.6;
 * test-support/store-path-lock.ts): mark, assistant completion, terminal reassertion
 * and clear, their bounds and conflicts, the documents each commits, and which
 * hand-written markers (legacy and current) a read admits.
 */
it("run-markers-paths: mark, complete, reassert, clear, bounds and admission", async () => {
  const log = await storePathLock({ module: "gateway/run", name: "run-markers-paths", testFileUrl: import.meta.url, owned: "gateway/runtime-markers" });
  const store = new RunMarkerStore(log.home);
  const directory = join(log.home, "gateway", "runtime-markers");
  const all = async () => ({
    evidence: Object.fromEntries([...(await store.evidence())].sort(([a], [b]) => a.localeCompare(b))),
    interrupted: [...await store.interruptedSessionIds()].sort(),
  });
  const at = (minute: number) => `2026-01-01T00:${String(minute).padStart(2, "0")}:00.000Z`;

  await log.step("evidence and interrupted ids before the directory exists", all);
  await log.step("evidence for an unknown session", () => store.evidenceFor("s1"));
  await log.step("mark s1 op-1", () => store.mark("s1", "op-1"), "result");
  log.advance(1_000);
  await log.step("mark s1 op-1 again is unchanged", () => store.mark("s1", "op-1"));
  await log.step("mark s1 op-2", () => store.mark("s1", "op-2"), "result");
  await log.step("complete s1 op-2", () => store.markAssistantCompletion("s1", "op-2", "c-2", at(1)), "result");
  await log.step("complete s1 op-2 again is unchanged", () => store.markAssistantCompletion("s1", "op-2", "c-2", at(1)));
  await log.step("complete s1 op-2 at another time conflicts", () => store.markAssistantCompletion("s1", "op-2", "c-2", at(2)), "refused");
  await log.step("complete s1 op-2 with another completion conflicts", () => store.markAssistantCompletion("s1", "op-2", "c-3", at(1)), "refused");
  await log.step("complete an unmarked operation is refused", () => store.markAssistantCompletion("s1", "op-9", "c-9", at(1)), "refused");
  await log.step("an oversized operation id is refused", () => store.markAssistantCompletion("s1", "x".repeat(257), "c-1", at(1)), "refused");
  await log.step("an oversized completion id is refused", () => store.markAssistantCompletion("s1", "op-1", "c".repeat(257), at(1)), "refused");
  await log.step("an oversized completion time is refused", () => store.markAssistantCompletion("s1", "op-1", "c-1", "t".repeat(129)), "refused");
  await log.step("an empty completion id is refused", () => store.markAssistantCompletion("s1", "op-1", "", at(1)), "refused");
  await log.step("reassert s1 op-1 stamps its completion", () => store.reassertAssistantCompletion("s1", "op-1", "c-1", at(3)), "result");
  await log.step("reassert s1 op-1 again is unchanged", () => store.reassertAssistantCompletion("s1", "op-1", "c-1", at(3)));
  await log.step("reassert s1 op-1 with another completion conflicts", () => store.reassertAssistantCompletion("s1", "op-1", "c-4", at(3)), "refused");
  await log.step("reassert with an oversized completion time is refused", () => store.reassertAssistantCompletion("s2", "op-r", "c-r", "t".repeat(129)), "refused");
  log.advance(1_000);
  await log.step("reassert an unmarked s2 operation recreates it", () => store.reassertAssistantCompletion("s2", "op-r", "c-r", at(4)), "result");
  await log.step("mark an oversized operation id is refused", () => store.mark("s2", "o".repeat(257)), "refused");
  await log.step("mark an empty operation id is refused", () => store.mark("s2", ""), "refused");
  for (let index = 1; index <= 15; index += 1) await store.mark("s3", `op-${index}`);
  await log.step("s3 holds fifteen operations", () => store.evidenceFor("s3").then((operations) => operations.length));
  await log.step("reassert a sixteenth s3 operation", () => store.reassertAssistantCompletion("s3", "op-16", "c-16", at(5)), "result");
  await log.step("mark a seventeenth s3 operation is refused", () => store.mark("s3", "op-17"), "refused");
  await log.step("reassert a seventeenth s3 operation is refused", () => store.reassertAssistantCompletion("s3", "op-17", "c-17", at(5)), "refused");
  await log.step("reassert a held s3 operation at the bound", () => store.reassertAssistantCompletion("s3", "op-1", "c-1", at(5)), "result");
  await log.step("evidence and interrupted ids", all);
  await log.step("clear an unknown s1 operation is unchanged", () => store.clear("s1", "op-9"));
  await log.step("clear s1 op-1 keeps op-2", () => store.clear("s1", "op-1"));
  await log.step("clear s1 op-2 removes the marker", () => store.clear("s1", "op-2"));
  await log.step("clear all of s3", () => store.clear("s3"));
  await log.step("clear all of an unknown session", () => store.clear("s9"));
  await log.step("evidence and interrupted ids after clearing", all);
  // One session lane serializes every write, including a call that arrives while an
  // earlier queued write is in flight. The store's own file-system option holds the
  // second write inside its directory step; the third call must wait for it, never
  // read the marker beside it and lose its operation.
  await log.step("a write arriving behind a queued write waits for it", async () => {
    let calls = 0;
    let entered!: () => void;
    let release!: () => void;
    const held = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let thirdEntered!: () => void;
    const third = new Promise<void>((resolve) => { thirdEntered = resolve; });
    const lanes = new RunMarkerStore(log.home, { fileSystem: { open, rename, rm, mkdir: (async (...args: Parameters<typeof mkdir>) => {
      calls += 1;
      if (calls === 2) { entered(); await gate; }
      if (calls === 3) thirdEntered();
      return mkdir(...args);
    }) as typeof mkdir } });
    const first = lanes.mark("s5", "op-a");
    const second = lanes.mark("s5", "op-b");
    await first;
    await held;
    const late = lanes.mark("s5", "op-c");
    // Correct code never reaches a third write before the second is released.
    const overtook = await Promise.race([third.then(() => true), new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 500))]);
    release();
    await Promise.all([second, late]);
    return { overtook, operations: (await lanes.evidenceFor("s5")).map((operation) => operation.operationId) };
  });
  await log.step("clear all of s5", () => store.clear("s5"));

  const operation = (id: string, extra: Record<string, unknown> = {}) => ({ operationId: id, acceptedAt: at(6), ...extra });
  const marker = (sessionId: string, document: unknown) => writeFile(join(directory, `${sessionId}.json`), JSON.stringify(document));
  const legacy = { version: 1, operationId: "legacy-op", acceptedAt: at(7) };
  const written: Record<string, unknown> = {
    "legacy-complete": { ...legacy, sessionId: "legacy-complete", assistantCompletionId: "c-l", assistantCompletedAt: at(8) },
    "legacy-open": { ...legacy, sessionId: "legacy-open" },
    "legacy-other-session": { ...legacy, sessionId: "someone-else" },
    "legacy-half-complete": { ...legacy, sessionId: "legacy-half-complete", assistantCompletionId: "c-l" },
    "legacy-version-3": { ...legacy, version: 3, sessionId: "legacy-version-3" },
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
  await log.step("write hand-made markers", async () => { for (const [sessionId, document] of Object.entries(written)) await marker(sessionId, document); });
  await log.step("each hand-made marker's admitted evidence", async () => Object.fromEntries(await Promise.all(Object.keys(written)
    .map(async (sessionId) => [sessionId, await store.evidenceFor(sessionId)]))));
  await log.step("evidence and interrupted ids over hand-made markers", all);
  await log.step("complete the legacy marker rewrites it as current", () => store.markAssistantCompletion("legacy-open", "legacy-op", "c-l", at(10)), "result");
  await log.step("mark over an unreadable marker replaces it", () => store.mark("current-duplicate", "fresh"), "result");
  await log.step("clear one operation of the current marker", () => store.clear("current-complete", "b"));
  // A temporary name already taken is not this write's to remove: fixed temporary-name
  // bytes make the collision deterministic, and the foreign file must survive the refusal.
  await log.step("a write whose temporary name is taken keeps the foreign file", async () => {
    const foreign = join(directory, `s4.json.${process.pid}.${"ab".repeat(6)}.tmp`);
    await writeFile(foreign, "foreign");
    const original = crypto.randomBytes;
    try {
      crypto.randomBytes = ((size: number) => Buffer.alloc(size, 0xab)) as typeof crypto.randomBytes;
      syncBuiltinESMExports();
      const refusal = await store.mark("s4", "op-1").then(() => "written", (error: NodeJS.ErrnoException) => error.code);
      return { refusal, foreignKept: await readFile(foreign, "utf8").catch(() => "removed") };
    } finally {
      crypto.randomBytes = original;
      syncBuiltinESMExports();
      await rm(foreign, { force: true });
    }
  });
  await log.finish();
});
