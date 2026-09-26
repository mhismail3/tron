import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { RecentModelStore } from "./recent-models.js";

/**
 * Isolated coverage exists only for the failure modes the admitted-run
 * integration test in `packages/gateway/src/sessions/recent-model-usage.integration.test.ts`
 * structurally cannot produce:
 *
 * 1. A preference write that has not started when disposal begins must refuse
 *    instead of publishing into a state directory its owner already released.
 * 2. A write already admitted into the store's write mutex must still complete,
 *    so a refusal check placed outside that mutex cannot cancel work the caller
 *    was already told was under way.
 */
describe("RecentModelStore", () => {
  it("settles an admitted write at disposal and refuses later ones", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-recent-store-"));
    const path = join(home, "gateway", "model-recents.json");
    const store = new RecentModelStore(home);
    await store.initialize();

    const admitted = store.record("provider-a", "model-a");
    // Let the admitted write reach its durable I/O before disposal begins.
    await new Promise((resolve) => setImmediate(resolve));
    await store.dispose();
    expect(await admitted).toBe(true);
    // Disposal waited for that write: the document is on disk by the time the
    // owner reports done, so a caller that releases the directory can rely on it.
    const document = JSON.parse(await readFile(path, "utf8")) as { models: Array<{ id: string }> };
    expect(document.models.map((model) => model.id)).toEqual(["model-a"]);

    // A write admitted after disposal must refuse instead of recreating the
    // directory and publishing a stale preference.
    expect(await store.record("provider-b", "model-b")).toBe(false);
    const reloaded = JSON.parse(await readFile(path, "utf8")) as { models: Array<{ id: string }> };
    expect(reloaded.models.map((model) => model.id)).toEqual(["model-a"]);
  });
});
