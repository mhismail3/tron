import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, expect, it, vi } from "vitest";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { waitFor } from "../../test-support/wait-for.js";

// Calibrate the real canonical crossing, not a projected entry-count getter.
const limits = vi.hoisted(() => ({ entries: 100 }));
vi.mock("./home-chapter-state.js", async importOriginal => ({
  ...await importOriginal<typeof import("./home-chapter-state.js")>(),
  get HOME_HARD_ENTRIES() { return limits.entries; },
}));

afterEach(async () => { vi.restoreAllMocks(); await disposeFixtures(); });

it("keeps the canonical admission fence when an exact chapter-limit Stop cannot join", async () => {
  const f = await fixture();
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const slot = await f.registry.acquire(f.home.sessionId);
  f.faux.setResponses([fauxAssistantMessage("canonical baseline")]);
  await slot.prompt("initialize canonical fence evidence");
  await waitFor(() => slot.snapshot().configurationBlocker === null, "initial Home settlement");
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  let entered = false;
  f.faux.setResponses([async () => {
    entered = true;
    await gate;
    return fauxAssistantMessage("owned provider settlement");
  }]);
  // Fail the real writer's Stop boundary; the model and canonical writer stay live.
  const stop = vi.spyOn(slot, "abort").mockRejectedValue(new Error("controlled exact Stop join failure"));
  const running = slot.prompt("cross the canonical entry boundary");
  void running.catch(() => {});
  try {
    await waitFor(() => entered, "owned provider entered");
    while (slot.canonicalEntryCount < limits.entries) {
      slot.sessionManager.appendCustomEntry("failed-stop-crossing", { retained: true });
    }
    await waitFor(() => f.events.some(event => event.topic === "session.diagnostic"
      && (event.payload as { data?: { code?: string } }).data?.code === "home-chapter-limit-stop-failed"), "failed exact Stop diagnostic");
    const branch = slot.sessionManager.getBranch();
    const bytes = await readFile(slot.sessionFile!);
    const providerRequests = f.faux.state.callCount;
    await expect(slot.prompt("must remain fenced")).rejects.toMatchObject({
      code: "conflict", details: { reason: "chapter-limit-stop" },
    });
    expect(slot.sessionManager.getBranch()).toEqual(branch);
    expect(await readFile(slot.sessionFile!)).toEqual(bytes);
    expect(f.faux.state.callCount).toBe(providerRequests);
    await mkdir("test-results/home-canonical-guard", { recursive: true });
    await writeFile("test-results/home-canonical-guard/failed-stop.json", JSON.stringify({
      boundary: "hard-entries", crossingEntries: slot.canonicalEntryCount,
      failureDiagnosed: true, admissionFenced: true, canonicalBytesPreserved: true, providerRequestsPreserved: true,
    }, null, 2));
  } finally {
    stop.mockRestore();
    const stopping = slot.abort("agent");
    release();
    await Promise.allSettled([running, stopping]);
  }
});
