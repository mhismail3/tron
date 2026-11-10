import { mkdtemp, realpath, rm, cp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { recordFixed } from "../../test-support/fixed-recording.js";
import { CORPUS_STORES, TRON_CORPUS_HOME, directories, fileDigests, prepareHome, stageCorpus } from "../../test-support/tron-store-corpus.js";

it("records every listed store with its current owner", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-store-corpus-record-"));
  const home = join(root, "home");
  const realRoot = await realpath(root);
  try {
    const named = (process.env.TRON_CORPUS_STORES ?? "").split(",").map((name) => name.trim()).filter(Boolean);
    const unknown = named.filter((name) => !CORPUS_STORES.some((store) => store.name === name && !store.live));
    expect(unknown, "TRON_CORPUS_STORES names committed corpus stores").toEqual([]);
    const recorded = CORPUS_STORES.filter((item) => !item.live && (named.length === 0 || named.includes(item.name)));
    const ownedBy = (path: string, store: (typeof CORPUS_STORES)[number]) => store.paths.some((prefix) => path === prefix || path.startsWith(`${prefix}/`));
    let kept: Record<string, string> = {};
    if (named.length) {
      const { home: staged, dispose } = await stageCorpus();
      try { await cp(staged, home, { recursive: true }); } finally { await dispose(); }
      for (const store of recorded) for (const path of store.paths) await rm(join(home, path), { recursive: true, force: true });
      kept = Object.fromEntries(Object.entries(await fileDigests(home)));
    } else {
      await prepareHome(home);
    }
    for (const store of recorded) await recordFixed(() => store.record(home));
    if (named.length) {
      const after = await fileDigests(home);
      const changed = Object.keys({ ...kept, ...after }).filter((path) => kept[path] !== after[path]
        && !recorded.some((store) => ownedBy(path, store)));
      expect(changed, "re-recording named stores changes no other store's bytes").toEqual([]);
    }
    const digests = await fileDigests(home);
    for (const path of Object.keys(digests)) {
      const text = await readFile(join(home, path), "utf8").catch(() => "");
      expect(text, path).not.toContain(root);
      expect(text, path).not.toContain(realRoot);
      expect(text, path).not.toMatch(/\/Users\/[a-z]|\/private\/var\/|\/var\/folders\//u);
    }
    await rm(TRON_CORPUS_HOME, { recursive: true, force: true });
    await cp(home, TRON_CORPUS_HOME, { recursive: true });
    await writeFile(join(TRON_CORPUS_HOME, "..", "manifest.json"), `${JSON.stringify({
      stores: CORPUS_STORES.filter((store) => !store.live).map((store) => ({ module: store.module, lock: store.name, paths: store.paths })),
      directories: await directories(home),
      files: digests,
    }, null, 2)}\n`);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}, 120_000);
