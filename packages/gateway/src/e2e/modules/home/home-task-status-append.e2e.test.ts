import { afterEach, expect, it, vi } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import type { SessionManager } from "@earendil-works/pi-coding-agent";
import { homeOwnerOf } from "../../../../test-support/gateway-registry.js";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../../../test-support/home-task-fixture.js";

/** One real canonical append landing inside a status read's evidence cut: after the
 * cut's first stat and before its read. The append itself is the worker session's own
 * SDK append, as a late provider notice or a resumed successor makes. */
const appendDuringCut = vi.hoisted(() => ({
  path: undefined as string | undefined,
  append: undefined as (() => Promise<void>) | undefined,
  appended: 0,
}));

vi.mock("../../../kernel/session/canonical-reader.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../../kernel/session/canonical-reader.js")>();
  return {
    ...actual,
    readCanonicalSessionFile: async (options: Parameters<typeof actual.readCanonicalSessionFile>[0]) => {
      const append = appendDuringCut.append;
      if (append && options.path === appendDuringCut.path) {
        appendDuringCut.append = undefined;
        await append();
        appendDuringCut.appended += 1;
      }
      return actual.readCanonicalSessionFile(options);
    },
  };
});

afterEach(async () => {
  appendDuringCut.append = undefined;
  await disposeFixtures();
});

it("reads a settled task's status while its worker session receives a later canonical append", async () => {
  const f = await fixture();
  f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
  const run = await dispatch(f);
  const settled = await run.completion;
  expect(settled).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "final" } });
  const worker = await f.registry.acquire(run.sessionId);
  const manager = (worker as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
  const before = manager.getEntries().length;
  appendDuringCut.path = worker.sessionFile;
  appendDuringCut.append = async () => { manager.appendCustomEntry("tron-test-late-append", { after: "settlement" }); };
  const status = await homeOwnerOf(f.registry).taskStatus(run.taskId);
  expect(appendDuringCut.appended, "the append landed inside the status read's evidence cut").toBe(1);
  expect(manager.getEntries()).toHaveLength(before + 1);
  expect(status).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "final" }, reportRef: settled.reportRef });
});
