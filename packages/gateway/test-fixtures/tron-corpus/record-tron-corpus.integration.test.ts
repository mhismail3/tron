import { mkdtemp, rm, cp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { STORES, TRON_CORPUS_HOME, directories, fileDigests, prepareHome } from "../../test-support/tron-store-corpus.js";

/**
 * Records the persisted-store corpus (`npm run record:tron-corpus`, #1465): every
 * store in `STORES` is written by its real owner into a fresh Tron home, which then
 * replaces `test-fixtures/tron-corpus/home`. The data is synthetic and the home
 * contains no credentials beyond the generated device-token hashes.
 *
 * Re-recording is a behavior event for review: store locks compare against the
 * committed corpus, so a new corpus is only committed with the change that needs it
 * (a migration slice records the old corpus first).
 */
it("records every listed store with its current owner", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-store-corpus-record-"));
  const home = join(root, "home");
  try {
    await prepareHome(home);
    for (const store of STORES.filter((item) => !item.live)) await store.record(home);
    // Nothing the recorder leaves behind may be machine- or user-specific.
    const digests = await fileDigests(home);
    for (const path of Object.keys(digests)) {
      const text = await readFile(join(home, path), "utf8").catch(() => "");
      expect(text, path).not.toContain(root);
      expect(text, path).not.toMatch(/\/Users\/[a-z]/u);
    }
    await rm(TRON_CORPUS_HOME, { recursive: true, force: true });
    await cp(home, TRON_CORPUS_HOME, { recursive: true });
    await writeFile(join(TRON_CORPUS_HOME, "..", "manifest.json"), `${JSON.stringify({
      stores: STORES.filter((store) => !store.live).map((store) => ({ module: store.module, lock: store.name, paths: store.paths })),
      directories: await directories(home),
      files: digests,
    }, null, 2)}\n`);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}, 120_000);
