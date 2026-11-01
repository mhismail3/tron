import { spawn } from "node:child_process";
import { once } from "node:events";
import { appendFile, copyFile, lstat, mkdir, readdir, readFile, realpath, rm, stat, utimes, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import {
  CatalogMetadataIndex,
  catalogMetadataShard,
  type CatalogMetadataIndexFailureDetail,
  type CatalogMetadataIndexFailureStage,
  type CatalogMetadataIndexPressure,
  type CatalogMetadataIndexRow,
} from "./catalog-metadata-index.js";
import { realisticCatalogRow, realisticCatalogRows, sortedCatalogRows } from "../../test-support/catalog-metadata-fixture.js";
import { catalogOwner, createColdRegistryFixture, settleCatalog, temporaryRoot } from "../../test-support/runtime-registry-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import type { RuntimeRegistry } from "../kernel/session/runtime-registry.js";

/**
 * `gateway/session-catalog` sharded catalog metadata store (#2164) over real
 * files: the store that replaced the single 8 MiB document, its bounds and
 * signals, migration of that document, pruning, and crash and corruption
 * isolation.
 */
const MIB = 1_024 * 1_024;
const LEGACY_BOUND = 8 * MIB;
const SHARD_WARN_BYTES = 2 * MIB;

type Failure = { stage: CatalogMetadataIndexFailureStage } & Partial<CatalogMetadataIndexFailureDetail>;

async function storeFixture(label: string) {
  const base = await temporaryRoot(`tron-catalog-shards-${label}-`);
  const root = join(base, "agent", "sessions");
  await mkdir(root, { recursive: true });
  const canonical = await realpath(root);
  const gateway = join(base, "tron", "gateway");
  const failures: Failure[] = [];
  const pressure: CatalogMetadataIndexPressure[] = [];
  const index = new CatalogMetadataIndex(gateway, (stage, _durationMs, detail) => { failures.push({ stage, ...detail }); },
    (reported) => { pressure.push(reported); });
  return { base, root: canonical, gateway, index, failures, pressure };
}

async function shardFiles(directory: string): Promise<Map<string, { bytes: number; ino: number; content: Buffer }>> {
  const files = new Map<string, { bytes: number; ino: number; content: Buffer }>();
  for (const name of (await readdir(directory)).sort()) {
    const shard = /^shard-([0-9a-f]{2})\.json$/u.exec(name)?.[1];
    if (!shard) continue;
    const info = await stat(join(directory, name));
    files.set(shard, { bytes: info.size, ino: info.ino, content: await readFile(join(directory, name)) });
  }
  return files;
}

/** Real canonical session files with rows stamped by the index itself, so a
 * reconcile can verify them. */
async function canonicalSessions(root: string, index: CatalogMetadataIndex, count: number) {
  const workspace = join(root, "workspace");
  await mkdir(workspace, { recursive: true });
  const rows: CatalogMetadataIndexRow[] = [];
  const time = "2026-10-01T00:00:00.000Z";
  for (let number = 0; number < count; number += 1) {
    const id = `session-${number}`;
    const path = join(workspace, `${id}.jsonl`);
    await writeFile(path, `${JSON.stringify({ type: "session", version: 3, id, cwd: "/work", timestamp: time })}\n`
      + `${JSON.stringify({ type: "message", message: { role: "user", content: `hello ${number}`, timestamp: Date.parse(time) } })}\n`);
    await utimes(path, new Date(Date.parse(time) + number * 1_000), new Date(Date.parse(time) + number * 1_000));
    rows.push((await index.entryFromSummary({ id, path, cwd: "/work", firstMessage: `hello ${number}`, createdAt: time, updatedAt: time, messageCount: 1 }))!);
  }
  const candidates = await Promise.all(rows.map(async (row) => {
    const info = await lstat(row.path);
    return { path: row.path, id: row.id, cwd: row.cwd, fileIdentity: `${info.dev}:${info.ino}`, size: info.size, mtimeMs: info.mtimeMs };
  }));
  return { rows, candidates };
}

describe("catalog metadata store (#2164)", () => {
  const registries: RuntimeRegistry[] = [];
  const agentDirectory = process.env.PI_CODING_AGENT_DIR;
  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (agentDirectory === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = agentDirectory;
  });

  it("saves and reloads a realistic 6,510-session catalog that the single 8 MiB document refused", async () => {
    const { root, gateway, index, failures, pressure } = await storeFixture("realistic");
    // The live catalog had 6,510 canonical files when the 8,387,899-byte
    // document stopped saving; this fixture has the measured row shape.
    const rows = realisticCatalogRows(root, 6_510);
    const singleDocument = Buffer.byteLength(JSON.stringify({ version: 3, root, rows }));
    expect(singleDocument).toBeGreaterThan(LEGACY_BOUND);

    expect(await index.save(root, rows)).toBe(true);
    expect(failures).toEqual([]);
    expect(sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root))).toEqual(sortedCatalogRows(rows));

    const shards = await shardFiles(join(gateway, "catalog-metadata-v3"));
    const sizes = [...shards.values()].map((file) => file.bytes);
    expect(shards.size).toBe(64);
    // Every shard sits far below the warning, which sits far below refusal.
    expect(Math.max(...sizes)).toBeLessThan(SHARD_WARN_BYTES / 4);
    expect(pressure).toEqual([]);
  });

  it("publishes a catalog over the old document bound from the catalog owner without a save failure", async () => {
    const failures: string[] = [];
    let workspace = "";
    // Names and previews at their 1,024-byte bound, so fewer files than the
    // live catalog already exceed the old single-document bound.
    const count = 3_600;
    const fixture = await createColdRegistryFixture(registries, "catalog-over-document-bound", {
      catalogIndexFailure: (stage) => { failures.push(stage); },
      beforeInitialize: async (sessionFile) => {
        workspace = join(sessionFile, "..");
        const time = Date.parse("2026-10-01T00:00:00.000Z");
        for (let start = 0; start < count; start += 200) {
          await Promise.all(Array.from({ length: Math.min(200, count - start) }, (_, offset) => {
            const number = start + offset;
            const id = `bulk-${String(number).padStart(5, "0")}-0000-4000-8000-000000000000`;
            const body = `${JSON.stringify({ type: "session", version: 3, id, cwd: "/Users/example/Workspace/project", timestamp: new Date(time).toISOString() })}\n`
              + `${JSON.stringify({ type: "session_info", name: `${number} ${"worker title ".repeat(80)}` })}\n`
              + `${JSON.stringify({ type: "message", message: { role: "user", content: `${number} ${"bounded preview text ".repeat(60)}`, timestamp: time + number } })}\n`
              + `${JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "done" }], timestamp: time + number + 1 } })}\n`;
            return writeFile(join(workspace, `2026-10-01T00-00-00-000Z_${id}.jsonl`), body);
          }));
        }
      },
    });
    await settleCatalog(fixture.registry);
    expect(failures).toEqual([]);
    const sessionRoot = await realpath(join(fixture.agentDir, "sessions"));
    const stored = await new CatalogMetadataIndex(join(fixture.root, "tron", "gateway")).load(sessionRoot);
    expect(stored?.length).toBe(count + 1);
    expect(Buffer.byteLength(JSON.stringify({ version: 3, root: sessionRoot, rows: stored }))).toBeGreaterThan(LEGACY_BOUND);
    expect(sortedCatalogRows(stored)).toEqual(sortedCatalogRows(catalogOwner(fixture.registry).rows()
      .map(({ delegated: _delegated, ...row }) => row)));
  }, 120_000);

  it("prunes only rows whose canonical file is gone, keeping archived, delegated and unprovable sessions", async () => {
    const fixture = await createColdRegistryFixture(registries, "catalog-prune");
    const workspace = join(fixture.sessionFile, "..");
    const time = "2026-10-01T00:00:00.000Z";
    const session = async (path: string, id: string, extra = "") => {
      await mkdir(join(path, ".."), { recursive: true });
      await writeFile(path, `${JSON.stringify({ type: "session", version: 3, id, cwd: fixture.cwd, timestamp: time })}\n`
        + `${JSON.stringify({ type: "message", message: { role: "user", content: `hello ${id}`, timestamp: Date.parse(time) } })}\n${extra}`);
    };
    const removed = join(workspace, "removed.jsonl");
    const kept = join(workspace, "kept.jsonl");
    const unprovable = join(workspace, "unprovable.jsonl");
    const child = join(fixture.sessionFile.slice(0, -".jsonl".length), "forks", "child.jsonl");
    await session(removed, "removed-session");
    await session(kept, "kept-session");
    await session(unprovable, "unprovable-session");
    await session(child, "child-session");
    await settleCatalog(fixture.registry);
    const sessionRoot = await realpath(join(fixture.agentDir, "sessions"));
    const reader = new CatalogMetadataIndex(join(fixture.root, "tron", "gateway"));
    const ids = async () => (await reader.load(sessionRoot))?.map((row) => row.id).sort();
    const parentId = fixture.manager.getSessionId();
    expect(await ids()).toEqual(["child-session", "kept-session", parentId, "removed-session", "unprovable-session"].sort());
    const unprovableRow = (await reader.load(sessionRoot))!.find((row) => row.id === "unprovable-session");

    await fixture.registry.setArchived(parentId, true);
    await rm(removed);
    // A partial final line makes the file unprovable: it proves neither
    // presence nor absence, so its last proven row stays.
    await appendFile(unprovable, "{\"type\":\"message\"");
    await settleCatalog(fixture.registry);

    expect(await ids()).toEqual(["child-session", "kept-session", parentId, "unprovable-session"].sort());
    expect((await reader.load(sessionRoot))!.find((row) => row.id === "unprovable-session")).toEqual(unprovableRow);
  });

  it("keeps the last accepted copy of a shard over its ceiling, reports its size and still writes the others", async () => {
    const { root, gateway, index, failures } = await storeFixture("refused-shard");
    const rows = realisticCatalogRows(root, 640);
    expect(await index.save(root, rows)).toBe(true);
    const directory = join(gateway, "catalog-metadata-v3");
    const before = await shardFiles(directory);
    const target = catalogMetadataShard(root, rows[0]!.path);
    // Rows that all land in the target shard, each at the working-directory bound.
    const heavy: CatalogMetadataIndexRow[] = [];
    for (let number = 10_000; heavy.length < 2_100; number += 1) {
      const row = realisticCatalogRow(root, number);
      if (catalogMetadataShard(root, row.path) === target) heavy.push({ ...row, cwd: "c".repeat(4_096) });
    }
    const other = rows.find((row) => catalogMetadataShard(root, row.path) !== target)!;
    const next = [...rows.filter((row) => row !== other), { ...other, messageCount: other.messageCount + 1 }, ...heavy];

    expect(await index.save(root, next)).toBe(false);
    expect(failures).toEqual([{ stage: "save", reason: "shard-bytes", shard: target, rows: expect.any(Number), bytes: expect.any(Number), limit: 8 * MIB }]);
    expect(failures[0]!.bytes).toBeGreaterThan(8 * MIB);
    const after = await shardFiles(directory);
    expect(after.get(target)!.content.equals(before.get(target)!.content)).toBe(true);
    const otherShard = catalogMetadataShard(root, other.path);
    expect(after.get(otherShard)!.content.equals(before.get(otherShard)!.content)).toBe(false);
    expect(JSON.parse(await readFile(join(directory, "manifest.json"), "utf8")).refused).toEqual([target]);
    // A refused cut is never loaded as complete, but every kept row still
    // accelerates the rebuild.
    expect(await new CatalogMetadataIndex(gateway).load(root)).toBeUndefined();

    failures.length = 0;
    expect(await index.save(root, rows)).toBe(true);
    expect(failures).toEqual([]);
    expect(sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root))).toEqual(sortedCatalogRows(rows));
  });

  it("warns once per shard well before its ceiling while the save still succeeds", async () => {
    const { root, index, failures, pressure } = await storeFixture("pressure");
    const target = catalogMetadataShard(root, realisticCatalogRow(root, 0).path);
    const heavy: CatalogMetadataIndexRow[] = [];
    for (let number = 0; heavy.length < 700; number += 1) {
      const row = realisticCatalogRow(root, number);
      if (catalogMetadataShard(root, row.path) === target) heavy.push({ ...row, cwd: "c".repeat(4_096) });
    }
    expect(await index.save(root, heavy)).toBe(true);
    expect(await index.save(root, heavy.slice(1))).toBe(true);
    expect(failures).toEqual([]);
    expect(pressure).toEqual([{ shard: target, rows: 700, bytes: expect.any(Number), limit: 8 * MIB }]);
    expect(pressure[0]!.bytes).toBeGreaterThan(SHARD_WARN_BYTES);
  });

  it("rewrites only changed shards, each by a rename, and ignores and clears temporary debris", async () => {
    const { root, gateway, index } = await storeFixture("atomic");
    const rows = realisticCatalogRows(root, 640);
    expect(await index.save(root, rows)).toBe(true);
    const directory = join(gateway, "catalog-metadata-v3");
    const before = await shardFiles(directory);
    const changed = catalogMetadataShard(root, rows[3]!.path);
    const next = rows.map((row, number) => number === 3 ? { ...row, messageCount: row.messageCount + 1 } : row);
    // Debris of an interrupted write: a temporary file the rename never reached.
    const debris = join(directory, `shard-${changed}.json.999.deadbeef0000.tmp`);
    await writeFile(debris, "{\"version\":3,\"rows\":[");
    expect(sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root))).toEqual(sortedCatalogRows(rows));

    expect(await index.save(root, next)).toBe(true);
    const after = await shardFiles(directory);
    for (const [shard, file] of after) {
      if (shard === changed) {
        expect(file.ino).not.toBe(before.get(shard)!.ino);
        expect(file.content.equals(before.get(shard)!.content)).toBe(false);
      } else {
        expect({ shard, ino: file.ino }).toEqual({ shard, ino: before.get(shard)!.ino });
      }
    }
    expect((await readdir(directory)).filter((name) => name.endsWith(".tmp"))).toEqual([]);
    expect(sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root))).toEqual(sortedCatalogRows(next));
  });

  it("never loads a crash between a shard rename and its manifest as a cut, and recovers on the next save", async () => {
    const { root, gateway, index, base } = await storeFixture("crash-state");
    const first = realisticCatalogRows(root, 640, 1);
    const second = realisticCatalogRows(root, 640, 2);
    expect(await index.save(root, first)).toBe(true);
    // The same cut saved elsewhere gives the exact bytes a later save would rename into place.
    const elsewhere = join(base, "elsewhere");
    expect(await new CatalogMetadataIndex(elsewhere).save(root, second)).toBe(true);
    const directory = join(gateway, "catalog-metadata-v3");
    const shard = catalogMetadataShard(root, second[0]!.path);
    await copyFile(join(elsewhere, "catalog-metadata-v3", `shard-${shard}.json`), join(directory, `shard-${shard}.json`));

    const reader = new CatalogMetadataIndex(gateway);
    expect(await reader.load(root)).toBeUndefined();
    // A shard a newer manifest no longer lists (a crash before its removal) is not part of that cut.
    expect(await index.save(root, first.filter((row) => catalogMetadataShard(root, row.path) !== shard))).toBe(true);
    await copyFile(join(elsewhere, "catalog-metadata-v3", `shard-${shard}.json`), join(directory, `shard-${shard}.json`));
    expect(sortedCatalogRows(await reader.load(root)))
      .toEqual(sortedCatalogRows(first.filter((row) => catalogMetadataShard(root, row.path) !== shard)));
    expect(await index.save(root, second)).toBe(true);
    expect(sortedCatalogRows(await reader.load(root))).toEqual(sortedCatalogRows(second));
  });

  it("survives SIGKILL at arbitrary points of a save: a load is one whole cut or none, and the next save completes", async () => {
    const { root, gateway, base } = await storeFixture("sigkill");
    const count = 1_500;
    const cuts = [sortedCatalogRows(realisticCatalogRows(root, count, 1)), sortedCatalogRows(realisticCatalogRows(root, count, 2))];
    const preload = pathToFileURL(fileURLToPath(new URL("../../test-support/home-ledger-crash-preload.mjs", import.meta.url))).href;
    const program = fileURLToPath(new URL("../../test-support/catalog-metadata-crash-child.ts", import.meta.url));
    const outcomes = { whole: 0, none: 0 };
    for (let kill = 0; kill < 12; kill += 1) {
      const marker = join(base, `saving-${kill}`);
      const child = spawn(process.execPath, ["--experimental-transform-types", "--import", preload, program, gateway, root, marker, String(count)],
        { stdio: ["ignore", "pipe", "pipe"] });
      let output = "";
      child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
      child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
      const exited = once(child, "exit");
      try {
        await waitFor(async () => {
          if (child.exitCode !== null) throw new Error(`crash child exited (${child.exitCode}): ${output}`);
          return lstat(marker).then(() => true, () => undefined);
        }, "crash child completed its first save");
        // Each kill lands at a different point of the alternating saves.
        await new Promise((resolve) => setTimeout(resolve, 7 * kill));
      } finally {
        child.kill("SIGKILL");
        await exited;
      }
      const loaded = sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root));
      if (loaded === undefined) outcomes.none += 1;
      else {
        outcomes.whole += 1;
        expect(cuts.some((cut) => JSON.stringify(cut) === JSON.stringify(loaded)), `kill ${kill}: a loaded cut is one saved cut`).toBe(true);
      }
    }
    const recovered = new CatalogMetadataIndex(gateway);
    expect(await recovered.save(root, realisticCatalogRows(root, count, 1))).toBe(true);
    expect(sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root))).toEqual(cuts[0]);
    expect(outcomes.whole + outcomes.none).toBe(12);
  }, 120_000);

  it.each([
    ["is not JSON", async (path: string) => { await writeFile(path, "{\"version\":3,\"rows\":["); }],
    ["is over its byte ceiling", async (path: string) => { await writeFile(path, " ".repeat(8 * MIB + 1)); }],
    ["was truncated to nothing", async (path: string) => { await writeFile(path, ""); }],
  ])("a shard that %s costs only its own rows: the others are reused and the next save repairs it", async (_label, corrupt) => {
    const { root, gateway, index } = await storeFixture("corrupt-shard");
    const { rows, candidates } = await canonicalSessions(root, index, 96);
    expect(await index.save(root, rows)).toBe(true);
    const target = catalogMetadataShard(root, rows[0]!.path);
    await corrupt(join(gateway, "catalog-metadata-v3", `shard-${target}.json`));

    const reader = new CatalogMetadataIndex(gateway);
    expect(await reader.load(root)).toBeUndefined();
    const rebuilt: string[] = [];
    const reconciled = await reader.reconcile(root, candidates, async (candidate) => {
      rebuilt.push(candidate.path);
      return rows.find((row) => row.path === candidate.path);
    });
    expect(rebuilt.sort()).toEqual(rows.filter((row) => catalogMetadataShard(root, row.path) === target).map((row) => row.path).sort());
    expect(reconciled?.unproven).toEqual([]);
    expect(sortedCatalogRows(reconciled?.rows)).toEqual(sortedCatalogRows(rows));

    expect(await reader.save(root, reconciled!.rows)).toBe(true);
    expect(sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root))).toEqual(sortedCatalogRows(rows));
  });

  it("migrates a realistic v2 document on first load and removes it only after the shards read back", async () => {
    const { root, gateway, index, failures } = await storeFixture("migrate");
    // The live v2 document held 5,353 rows in 8,387,899 bytes, just under its
    // bound. This fixture's temporary root is longer, so it holds as many
    // realistic rows as fit in that many bytes.
    const legacyRows = realisticCatalogRows(root, 5_353);
    let legacyBytes = Buffer.byteLength(JSON.stringify({ version: 3, root, rows: legacyRows }));
    while (legacyBytes > 8_387_899) legacyBytes -= Buffer.byteLength(JSON.stringify(legacyRows.pop())) + 1;
    const legacy = JSON.stringify({ version: 3, root, rows: legacyRows });
    expect(Buffer.byteLength(legacy)).toBe(legacyBytes);
    expect(legacyRows.length).toBeGreaterThan(4_500);
    await mkdir(gateway, { recursive: true });
    await writeFile(join(gateway, "catalog-metadata-v2.json"), legacy, { mode: 0o600 });

    expect(sortedCatalogRows(await index.load(root))).toEqual(sortedCatalogRows(legacyRows));
    expect(failures).toEqual([]);
    expect(await lstat(join(gateway, "catalog-metadata-v2.json")).then(() => true, () => false)).toBe(false);
    expect(sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root))).toEqual(sortedCatalogRows(legacyRows));
    const modes = await Promise.all((await readdir(join(gateway, "catalog-metadata-v3")))
      .map(async (name) => (await stat(join(gateway, "catalog-metadata-v3", name))).mode & 0o777));
    expect(new Set(modes)).toEqual(new Set([0o600]));
  });

  it("never lets a migration that read the v2 document publish it over a newer save", async () => {
    const { root, gateway, index } = await storeFixture("migrate-race");
    const legacyRows = realisticCatalogRows(root, 300, 1);
    const newer = realisticCatalogRows(root, 300, 2);
    await mkdir(gateway, { recursive: true });
    await writeFile(join(gateway, "catalog-metadata-v2.json"), JSON.stringify({ version: 3, root, rows: legacyRows }), { mode: 0o600 });
    // The load reads the v2 document before it can take the write mutex; the
    // save queued at the same time takes it first.
    const [, saved] = await Promise.all([index.load(root), index.save(root, newer)]);
    expect(saved).toBe(true);
    expect(sortedCatalogRows(await new CatalogMetadataIndex(gateway).load(root))).toEqual(sortedCatalogRows(newer));
    expect(await lstat(join(gateway, "catalog-metadata-v2.json")).then(() => true, () => false)).toBe(false);
  });

  it("keeps the v2 document and serves its rows when the shards cannot be written, then migrates on a later load", async () => {
    const { root, gateway, index, failures } = await storeFixture("migrate-blocked");
    const legacyRows = realisticCatalogRows(root, 300);
    const legacy = JSON.stringify({ version: 3, root, rows: legacyRows });
    const legacyPath = join(gateway, "catalog-metadata-v2.json");
    await mkdir(gateway, { recursive: true });
    await writeFile(legacyPath, legacy, { mode: 0o600 });
    // A regular file where the store directory belongs makes every shard write fail.
    await writeFile(join(gateway, "catalog-metadata-v3"), "");

    expect(sortedCatalogRows(await index.load(root))).toEqual(sortedCatalogRows(legacyRows));
    expect(failures.map(({ stage, reason }) => ({ stage, reason }))).toEqual([{ stage: "migrate", reason: "write" }]);
    expect(await readFile(legacyPath, "utf8")).toBe(legacy);

    await rm(join(gateway, "catalog-metadata-v3"));
    // An interrupted earlier migration (shards without a manifest) is simply repeated.
    await mkdir(join(gateway, "catalog-metadata-v3"));
    await writeFile(join(gateway, "catalog-metadata-v3", `shard-${catalogMetadataShard(root, legacyRows[0]!.path)}.json`), "{");
    failures.length = 0;
    expect(sortedCatalogRows(await index.load(root))).toEqual(sortedCatalogRows(legacyRows));
    expect(failures).toEqual([]);
    expect(await lstat(legacyPath).then(() => true, () => false)).toBe(false);
  });
});
