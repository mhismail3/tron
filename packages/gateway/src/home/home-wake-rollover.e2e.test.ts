import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, expect, it, vi } from "vitest";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { disposeFixtures, dispatch, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import { homeOwnerOf } from "../../test-support/gateway-registry.js";

/** A result that settles after Home's chapter rolled over wakes Home in the reserved
 * successor (#1518). Before the fix the wake was refused `unavailable` and the result
 * waited for the maintainer's next message while Home showed "Recovery needed". */
afterEach(async () => { vi.restoreAllMocks(); await disposeFixtures(); });

type Entry = { type: string; customType?: string; message?: { role: string } };
const results = (entries: readonly Entry[]) => entries.filter(entry => entry.type === "custom_message" && entry.customType === "tron.home-task-result.v1");

it("wakes Home in the reserved successor when a result settles after a chapter rollover", async () => {
  const f = await fixture();
  const model = f.faux.getModel();
  await setHomeMemoryModels(f.registry, [{ provider: model.provider, id: model.id }]);
  f.faux.setResponses([fauxAssistantMessage("Hello reply")]);
  const sealed = await f.registry.acquire(f.home.sessionId);
  await sealed.prompt("hello");
  await waitFor(async () => sealed.snapshot().operation === undefined, "hello settled");
  let release!: () => void;
  const worker = new Promise<void>(resolve => { release = resolve; });
  f.faux.setResponses([async () => { await worker; return fauxAssistantMessage([reportCall("rv", "Rollover result")], { stopReason: "toolUse" }); },
    fauxAssistantMessage("Successor wake reply")]);
  const run = await dispatch(f, "task-rollover");
  // The delegating turn crosses the soft limit at its quiescent boundary, as in production.
  const owner = homeOwnerOf(f.registry) as unknown as {
    options: { sessions: { chapterMetrics(sessionId: string): Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
    chapterQuiescent(sessionId: string): Promise<void>;
  };
  const measured = owner.options.sessions.chapterMetrics;
  owner.options.sessions.chapterMetrics = async () => ({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
  await owner.chapterQuiescent(f.home.sessionId);
  owner.options.sessions.chapterMetrics = measured;
  const pending = await homeOwnerOf(f.registry).status();
  expect(pending.phase).toBe("rollover-pending");
  expect(pending.sessionId).not.toBe(f.home.sessionId);
  release();
  await run.completion;
  await waitFor(async () => (await homeOwnerOf(f.registry).taskResult("task-rollover")).wake?.state === "acknowledged", "wake acknowledged");
  const status = await homeOwnerOf(f.registry).status();
  expect(status).toMatchObject({ sessionId: pending.sessionId });
  expect(status.phase).not.toBe("rollover-pending");
  const entries = (await f.registry.acquire(pending.sessionId)).canonicalSessionEntries() as Entry[];
  expect(results(entries)).toHaveLength(1);
  expect(entries.some(entry => entry.type === "message" && entry.message?.role === "user")).toBe(false);
  expect(results(sealed.canonicalSessionEntries() as Entry[])).toHaveLength(0);
}, 60_000);
