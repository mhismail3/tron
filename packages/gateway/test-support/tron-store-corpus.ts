import { createHash } from "node:crypto";
import { chmod, cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { expect } from "vitest";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceNormalization, type TraceValue } from "./scenario-lock.js";
import { recordFixed } from "./fixed-recording.js";
import { CORPUS_IDS, STORES, type StoreSpec } from "./tron-store-specs.js";
import { DERIVED_STORES } from "./tron-store-specs-derived.js";

export const CORPUS_STORES: readonly StoreSpec[] = [...STORES, ...DERIVED_STORES];

export const TRON_CORPUS_HOME = resolve(import.meta.dirname, "..", "test-fixtures", "tron-corpus", "home");

export async function fileDigests(root: string): Promise<Record<string, string>> {
  const entries = await readdir(root, { recursive: true, withFileTypes: true });
  const digests: Record<string, string> = {};
  for (const entry of entries.filter((item) => item.isFile()).sort((a, b) => join(a.parentPath, a.name).localeCompare(join(b.parentPath, b.name)))) {
    const path = join(entry.parentPath, entry.name);
    digests[relative(root, path)] = createHash("sha256").update(await readFile(path)).digest("hex");
  }
  return digests;
}

export async function prepareHome(home: string): Promise<void> {
  await mkdir(join(home, "state"), { recursive: true, mode: 0o700 });
  await chmod(home, 0o700);
}

async function ownerOnly(root: string): Promise<void> {
  await chmod(root, 0o700);
  for (const entry of await readdir(root, { recursive: true, withFileTypes: true })) {
    await chmod(join(entry.parentPath, entry.name), entry.isDirectory() ? 0o700 : 0o600);
  }
}

export async function directories(root: string): Promise<string[]> {
  const entries = await readdir(root, { recursive: true, withFileTypes: true });
  return entries.filter((entry) => entry.isDirectory()).map((entry) => relative(root, join(entry.parentPath, entry.name))).sort();
}

export async function stageCorpus(): Promise<{ home: string; normalization: TraceNormalization; dispose(): Promise<void> }> {
  await stat(TRON_CORPUS_HOME);
  const root = await mkdtemp(join(tmpdir(), "tron-store-corpus-"));
  const home = join(root, "home");
  await cp(TRON_CORPUS_HOME, home, { recursive: true });
  const manifest = JSON.parse(await readFile(join(TRON_CORPUS_HOME, "..", "manifest.json"), "utf8")) as { directories: string[] };
  for (const directory of manifest.directories) await mkdir(join(home, directory), { recursive: true });
  await ownerOnly(home);
  return {
    home,
    normalization: { roots: [root, await realpath(root)], stableIds: Object.values(CORPUS_IDS) },
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

function normalizeStoreValue(value: unknown, normalization: TraceNormalization): TraceValue {
  const roots = [...normalization.roots].sort((left, right) => right.length - left.length);
  return JSON.parse(JSON.stringify(value ?? null, (_key, item: unknown) => {
    if (typeof item !== "string") return item;
    let text = item;
    for (const root of roots) text = text.split(root).join("<tmp>");
    return text;
  })) as TraceValue;
}

export async function runStoreLock(name: string, testFileUrl: string): Promise<void> {
  const spec = CORPUS_STORES.find((store) => store.name === name);
  if (!spec) throw new Error(`No store spec named ${name}`);
  if (spec.reproducible) await expectReproducible(spec);
  const staged = spec.live ? await freshHome() : await stageCorpus();
  try {
    if (spec.live) {
      await prepareHome(staged.home);
      await spec.record(staged.home);
    }
    const kept = (digests: Record<string, string>) => Object.fromEntries(Object.entries(digests)
      .filter(([path]) => !(spec.renewed ?? []).includes(path)));
    const before = kept(await fileDigests(staged.home));
    const projection = await spec.read(staged.home);
    const after = kept(await fileDigests(staged.home));
    const owned = Object.keys(before).filter((path) => spec.paths.some((prefix) => path === prefix || path.startsWith(`${prefix}/`)));
    const trace = {
      store: spec.name,
      module: spec.module,
      ...(spec.live ? { live: spec.live, files: await liveFiles(staged.home, owned, staged.normalization) } : { files: owned }),
      projection: spec.live ? normalizeTraceValue(JSON.parse(JSON.stringify(projection)), staged.normalization)
        : normalizeStoreValue(projection, staged.normalization),
    };
    await compareWithGolden({
      module: spec.module, ...lockPaths(testFileUrl, spec.name), trace, update: lockUpdateRequested(spec.module),
      validate: () => {
        expect(after, "reading the store must not change, add or remove a byte").toEqual(before);
        expect(owned.length, "the store has persisted files").toBeGreaterThan(0);
        expect(JSON.stringify(projection).length).toBeGreaterThan(2);
      },
    });
  } finally {
    await staged.dispose();
  }
}

async function expectReproducible(spec: StoreSpec): Promise<void> {
  const fresh = await freshHome();
  const named = spec.reproducible === true ? undefined : spec.reproducible;
  const owned = (digests: Record<string, string>) => Object.fromEntries(Object.entries(digests)
    .filter(([path]) => spec.paths.some((prefix) => path === prefix || path.startsWith(`${prefix}/`))));
  const content = async (home: string) => {
    const files = owned(await fileDigests(home));
    if (!named) return files;
    for (const path of Object.keys(files)) {
      files[path] = createHash("sha256").update(named(path, await readFile(join(home, path), "utf8"))).digest("hex");
    }
    return files;
  };
  try {
    await prepareHome(fresh.home);
    await recordFixed(() => spec.record(fresh.home));
    expect(Object.keys(await fileDigests(fresh.home)).filter((path) => !path.startsWith("gateway/workspace-state/")
      && Object.keys(owned({ [path]: "" })).length === 0), "recording writes only the store's own files").toEqual([]);
    expect(await content(fresh.home), "recording the store again writes the committed bytes")
      .toEqual(await content(TRON_CORPUS_HOME));
  } finally {
    await fresh.dispose();
  }
}

async function freshHome(): Promise<{ home: string; normalization: TraceNormalization; dispose(): Promise<void> }> {
  const root = await mkdtemp(join(tmpdir(), "tron-store-live-"));
  return {
    home: join(root, "home"),
    normalization: { roots: [root, await realpath(root)], stableIds: Object.values(CORPUS_IDS) },
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

async function liveFiles(home: string, paths: readonly string[], normalization: TraceNormalization): Promise<TraceValue[]> {
  const files: TraceValue[] = [];
  for (const path of paths) {
    const bytes = await readFile(join(home, path));
    let content: TraceValue;
    try { content = normalizeTraceValue(JSON.parse(bytes.toString("utf8")), normalization); }
    catch { content = `<${bytes.length} bytes>`; }
    files.push({ path: normalizeTraceValue(path, normalization), content });
  }
  return files.sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
}
