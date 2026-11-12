import { createHash } from "node:crypto";
import { appendFile, chmod, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished } from "vitest";
import { CatalogMetadataIndex, catalogActivityTimestamp, catalogMetadataShard, type CatalogMetadataIndexRow, type CatalogMetadataIndexSummary } from "./catalog-metadata-index.js";

it("catalog-metadata-index-paths: stamp, save, load, append, reconcile, admission and dispose", async () => {
  const home = join(await realpath(await mkdtemp(join(tmpdir(), "tron-catalog-metadata-"))), "home");
  onTestFinished(() => rm(join(home, ".."), { recursive: true, force: true }));
  const failures: string[] = [];
  const gateway = join(home, "state");
  const root = join(home, "sessions");
  await mkdir(root, { recursive: true });
  const index = new CatalogMetadataIndex(gateway, (stage) => { failures.push(stage); });
  const time = "2026-01-01T00:00:00.000Z";
  let tick = 0;
  const stamp = async (path: string) => { tick += 1; const at = new Date(Date.parse(time) + tick * 1_000); await utimes(path, at, at); };
  const header = (id: string, cwd = "/work") => `${JSON.stringify({ type: "session", version: 3, id, cwd, timestamp: time })}\n`;
  const message = (role: string, content: string, minute: number) => `${JSON.stringify({ type: "message", message: { role, content, timestamp: Date.parse(time) + minute * 60_000 } })}\n`;
  const session = async (name: string, content: string) => { const path = join(root, `${name}.jsonl`); await writeFile(path, content); await stamp(path); return path; };
  const summary = (id: string, path: string, extra: Partial<CatalogMetadataIndexSummary> = {}): CatalogMetadataIndexSummary =>
    ({ id, path, cwd: "/work", firstMessage: "hello", createdAt: time, updatedAt: time, messageCount: 1, ...extra });
  const candidate = async (id: string, path: string, cwd = "/work") => {
    const info = await lstat(path);
    return { path, id, cwd, fileIdentity: `${info.dev}:${info.ino}`, size: info.size, mtimeMs: info.mtimeMs };
  };
  const reported = async <T>(run: () => Promise<T>) => { failures.length = 0; const value = await run(); return { value: value ?? null, failures: [...failures] }; };
  const fileRow = async (id: string, path: string, rest: { tailBoundaryHash: string } & Partial<CatalogMetadataIndexRow>): Promise<CatalogMetadataIndexRow> => {
    const info = await lstat(path);
    return { id, path, cwd: "/work", firstMessage: "hello", createdAt: time, updatedAt: time, messageCount: 1,
      fileIdentity: `${info.dev}:${info.ino}`, size: info.size, mtimeMs: info.mtimeMs, eofOffset: info.size, ...rest };
  };
  const persisted = async (): Promise<Record<string, unknown>> => {
    const files: Record<string, unknown> = {};
    for (const name of (await readdir(gateway).catch(() => [])).sort()) {
      const path = join(gateway, name);
      if ((await lstat(path)).isDirectory()) {
        for (const inner of (await readdir(path)).sort()) files[`${name}/${inner}`] = JSON.parse(await readFile(join(path, inner), "utf8"));
      } else files[name] = JSON.parse(await readFile(path, "utf8"));
    }
    return files;
  };
  const digest = expect.stringMatching(/^[A-Za-z0-9_-]{43}$/u);
  const shardDocument = (shard: string, rows: CatalogMetadataIndexRow[]) => ({ version: 3, root, shard, rows });
  const manifestDigests = async () => ((await persisted())["catalog-metadata-v3/manifest.json"] as { shards: Array<{ shard: string; digest: string }> }).shards;

  expect(await index.load(root), "load before a document exists").toBeUndefined();
  expect(await index.reconcile(root, [], async () => undefined), "reconcile before a document exists").toBeUndefined();
  expect(await persisted()).toEqual({});
  const one = await session("one", header("s1") + message("user", "hello", 1));
  const oneTail = "DvRsLXq2pmw3J1TazkU_xCvA6WNog-m8lhRGEfn2YhE";
  let row = (await index.entryFromSummary(summary("s1", one)))!;
  expect(row, "stamp a row from a summary").toEqual(await fileRow("s1", one, { tailBoundaryHash: oneTail }));
  expect(await index.entryFromSummary(summary("s1", one, { name: "n".repeat(2_000), firstMessage: "f".repeat(2_000) })), "a long name and first message are bounded")
    .toEqual(await fileRow("s1", one, { tailBoundaryHash: oneTail, name: `${"n".repeat(1_021)}…`, firstMessage: `${"f".repeat(1_021)}…` }));
  const refusedSummaries: Array<[string, () => Promise<CatalogMetadataIndexSummary>, string[]]> = [
    ["a missing file", async () => summary("s1", join(root, "missing.jsonl")), ["rebuild"]],
    ["a directory", async () => { await mkdir(join(root, "folder.jsonl")); return summary("s1", join(root, "folder.jsonl")); }, []],
    ["a symbolic link", async () => { await symlink(one, join(root, "link.jsonl")); return summary("s1", join(root, "link.jsonl")); }, []],
    ["another session id", async () => summary("s9", one), []],
    ["another working directory", async () => ({ ...summary("s1", one), cwd: "/elsewhere" }), []],
    ["an empty file", async () => summary("s1", await session("empty", "")), []],
    ["a header that is not JSON", async () => summary("s1", await session("garbled", "{not json\n")), []],
    ["a header of another type", async () => summary("s1", await session("typed", `${JSON.stringify({ type: "message", id: "s1", cwd: "/work" })}\n`)), []],
    ["a file without a final newline", async () => summary("s1", await session("open", header("s1") + message("user", "hello", 1).trimEnd())), []],
    ["a parse of an earlier size", async () => summary("s1", one, { parsedSize: 10 }), []],
  ];
  for (const [label, prepare, stages] of refusedSummaries) {
    const input = await prepare();
    expect(await reported(() => index.entryFromSummary(input)), `no row is stamped for ${label}`).toEqual({ value: null, failures: stages });
  }
  const parsedSize = (await lstat(one)).size;
  expect(await reported(async () => index.entryFromSummary(summary("s1", one, { parsedSize }))), "a parse of the current size is stamped")
    .toEqual({ value: await fileRow("s1", one, { tailBoundaryHash: oneTail, parsedSize }), failures: [] });

  expect(await index.save(root, [row]), "save one row").toBe(true);
  const saved = { "catalog-metadata-v3/manifest.json": { version: 3, root, shards: [{ shard: "13", digest }], refused: [] },
    "catalog-metadata-v3/shard-13.json": shardDocument("13", [row]) };
  expect(await persisted(), "a save publishes a manifest and the row's shard").toEqual(saved);
  const savedDigests = await manifestDigests();
  expect(await index.load(root), "load the saved rows").toEqual([row]);
  expect(await index.load(join(home, "elsewhere")), "load for another catalog root").toBeUndefined();
  expect(await reported(() => index.save(root, Array.from({ length: 25_001 }, () => row))), "a save over the entry bound").toEqual({ value: false, failures: ["save"] });
  expect(await persisted(), "is not written").toEqual(saved);
  expect(await reported(() => index.save(root, Array.from({ length: 2_100 }, () => ({ ...row, cwd: "c".repeat(4_096) })))), "a shard over its byte bound")
    .toEqual({ value: false, failures: ["save"] });
  expect(await persisted(), "is not written, and the manifest records the refusal").toEqual({
    "catalog-metadata-v3/manifest.json": { version: 3, root, shards: [], refused: ["13"] }, "catalog-metadata-v3/shard-13.json": shardDocument("13", [row]) });
  expect(await index.save(root, [row]), "the next accepted save").toBe(true);
  expect(await persisted(), "publishes a complete cut again").toEqual(saved);
  expect(await manifestDigests(), "over the same shard bytes").toEqual(savedDigests);
  await writeFile(join(home, "blocked"), "");
  await expect(new CatalogMetadataIndex(join(home, "blocked", "gateway")).save(root, [row]), "a save into a state directory that is a file")
    .rejects.toThrow(expect.objectContaining({ message: `ENOTDIR: not a directory, mkdir '${join(home, "blocked", "cache", "catalog-metadata-v3")}'` }));
  expect(await persisted(), "the refused save leaves this store unchanged").toEqual(saved);
  expect(await index.append(row), "an unchanged row appends nothing").toEqual(row);

  await appendFile(one, message("assistant", "hi there", 2) + `${JSON.stringify({ type: "session_info", name: "Named" })}\n` + message("user", "again", 3));
  await stamp(one);
  const grown = (await index.append(row))!;
  expect(grown, "append counts the new lines").toEqual(await fileRow("s1", one, { tailBoundaryHash: "eStg-E-tSXUMOtMQKG50o0Q6c30sE5TVMJnyInohmBo",
    updatedAt: "2026-01-01T00:03:00.000Z", messageCount: 3, name: "Named" }));
  expect(grown.size, "the row covers the whole file").toBe(408);
  const appends: Array<[string, () => Promise<CatalogMetadataIndexRow>]> = [
    ["a row whose offset is not its size", async () => ({ ...grown, eofOffset: grown.size - 1 })],
    ["a row whose genuine earlier offset is not its size", async () => ({ ...grown, eofOffset: row.eofOffset, tailBoundaryHash: row.tailBoundaryHash })],
    ["a row of another file", async () => ({ ...grown, fileIdentity: "0:0" })],
    ["a row longer than the file", async () => ({ ...grown, size: grown.size + 10, eofOffset: grown.size + 10 })],
    ["a row whose tail no longer matches", async () => ({ ...grown, tailBoundaryHash: "changed" })],
    ["a row with another session id", async () => ({ ...grown, id: "s9" })],
    ["an unchanged size at another time", async () => ({ ...grown, mtimeMs: grown.mtimeMs - 1 })],
    ["an append without a final newline", async () => { await appendFile(one, "{\"type\":\"message\""); await stamp(one); return grown; }],
  ];
  for (const [label, prepare] of appends) {
    const input = await prepare();
    expect(await reported(() => index.append(input)), `no append for ${label}`).toEqual({ value: null, failures: [] });
  }
  const lines = async (name: string, appended: string) => {
    const path = await session(name, header(name) + message("user", "start", 1));
    const base = (await index.entryFromSummary(summary(name, path)))!;
    await appendFile(path, appended);
    await stamp(path);
    return base;
  };
  for (const [name, appended] of [["bad-line", "{oops\n"], ["list-line", "[1]\n"]]) {
    const base = await lines(name!, appended!);
    expect(await reported(() => index.append(base)), `no append past ${JSON.stringify(appended)}`).toEqual({ value: null, failures: [] });
  }
  const systemLine = await lines("system-line", `\n${JSON.stringify({ type: "message", message: { role: "system", content: "context" } })}\n`);
  expect(await reported(() => index.append(systemLine)), "an append skips blank lines and system messages").toEqual({ value: await fileRow("system-line",
    join(root, "system-line.jsonl"), { tailBoundaryHash: "Lz0qIpFhTpVA_2DNAl63qQj8mWdi0QN8VxOdajd77Dc" }), failures: [] });
  {
    const path = await session("metadata", header("metadata"));
    const base = (await index.entryFromSummary({ ...summary("metadata", path), firstMessage: "(no messages)", messageCount: 0 }))!;
    const at = (minute: number) => Date.parse(time) + minute * 60_000;
    const entries = [
      { type: "custom", data: 1 },
      { type: "message" },
      { type: "message", message: { role: "tool", content: "tool output" } },
      { type: "message", message: { role: "user" } },
      { type: "message", message: { role: "user", content: [null, ["x"], { type: "image" }, { type: "text", text: "first" }, { type: "text", text: "part" }], timestamp: at(5) } },
      { type: "message", timestamp: new Date(at(10)).toISOString(), message: { role: "assistant", content: "later" } },
      { type: "message", message: { role: "user", content: "older", timestamp: at(1) } },
      { type: "message", timestamp: at(20), message: { role: "assistant", content: "numbered" } },
      { type: "message", message: { role: "assistant", content: "zero", timestamp: 0 } },
      { type: "session_info", name: "  Titled  " },
    ];
    await appendFile(path, entries.map((entry) => `${JSON.stringify(entry)}\n`).join(""));
    await stamp(path);
    const named = (await index.append(base))!;
    const accumulated = { firstMessage: "first part", updatedAt: "2026-01-01T00:20:00.000Z", messageCount: 8 };
    expect(named, "an append accumulates counts, first message, name and activity time from each entry kind")
      .toEqual(await fileRow("metadata", path, { ...accumulated, name: "Titled", tailBoundaryHash: "EZE8sF8Ml8D7dnqLF2IcigyHcLBhKUHOLyqKP_B6Tnk" }));
    await appendFile(path, `${JSON.stringify({ type: "session_info", name: null })}\n`);
    await stamp(path);
    expect(await index.append(named), "a null name clears it")
      .toEqual(await fileRow("metadata", path, { ...accumulated, tailBoundaryHash: "3DViKZrSlxvYqld-rwNyWUQ2mXikj6eQGL_-jHANxL8" }));
  }
  {
    const at = Date.parse(time) + 60_000;
    expect([
      { type: "message", message: { role: "user", content: "x", timestamp: at } },
      { type: "message", timestamp: at, message: { role: "assistant", content: "x" } },
      { type: "message", timestamp: new Date(at).toISOString(), message: { role: "user", content: "x" } },
      { type: "custom", message: { role: "user", content: "x", timestamp: at } },
      { type: "message", message: [{ role: "user", content: "x", timestamp: at }] },
      { type: "message", message: { role: "tool", content: "x", timestamp: at } },
      { type: "message", message: { role: "user", timestamp: at } },
      { type: "message", message: { role: "user", content: "x", timestamp: -1 } },
      { type: "message", timestamp: "not a time", message: { role: "user", content: "x" } },
    ].map((entry) => catalogActivityTimestamp(entry) ?? null), "activity time of each entry shape").toEqual([at, at, at, null, null, null, null, null, null]);
  }
  expect(await reported(() => index.append({ ...grown, path: join(root, "missing.jsonl") })), "an append of a missing file reports its failure")
    .toEqual({ value: null, failures: ["append"] });

  const two = await session("two", header("s2") + message("user", "second", 1));
  const three = await session("three", header("s3") + message("user", "third", 1));
  const five = await session("five", header("s5") + message("user", "fifth", 1));
  await writeFile(one, header("s1") + message("user", "hello", 1));
  await stamp(one);
  row = (await index.entryFromSummary(summary("s1", one)))!;
  const twoRow = { ...(await index.entryFromSummary(summary("s2", two)))!, messageCount: 7 };
  await index.save(root, [row, twoRow]);
  const rebuilt: string[] = [];
  const rebuild = async (input: { id: string; path: string }) => { rebuilt.push(input.id); return input.id === "s3" ? undefined : summary(input.id, input.path); };
  rebuilt.length = 0;
  expect(await index.reconcile(root, [await candidate("s1", one), await candidate("s2", two, "/moved"), await candidate("s3", three),
    await candidate("s4", two), await candidate("s5", five)], rebuild), "reconcile keeps unchanged rows, rebuilds a new one and reports those it cannot prove")
    .toEqual({ rows: [row, await fileRow("s5", five, { tailBoundaryHash: "55ZojGed4cr608aWDF5W6LfuGKmNYe_lqHtDLLPYV4E" })], unproven: [two, three, two] });
  expect(rebuilt.sort(), "every changed or new candidate is rebuilt").toEqual(["s2", "s3", "s4", "s5"]);
  expect(await persisted(), "reconcile leaves the saved cut").toEqual({
    "catalog-metadata-v3/manifest.json": { version: 3, root, shards: [{ shard: "13", digest }, { shard: "26", digest }], refused: [] },
    "catalog-metadata-v3/shard-13.json": shardDocument("13", [row]), "catalog-metadata-v3/shard-26.json": shardDocument("26", [twoRow]) });
  const reconcileCut = await persisted();
  const shard13Digest = (await manifestDigests()).find(({ shard }) => shard === "13")!.digest;
  await appendFile(two, message("assistant", "reply", 2));
  await stamp(two);
  rebuilt.length = 0;
  expect(await index.reconcile(root, [await candidate("s2", two)], rebuild), "reconcile appends a grown row").toEqual({ rows: [await fileRow("s2", two,
    { tailBoundaryHash: "tsQ05_K6612aZrprQNotjfv5vlmml67zxir82zWJ8N0", updatedAt: "2026-01-01T00:02:00.000Z", messageCount: 8 })], unproven: [] });
  expect(rebuilt, "without a rebuild").toEqual([]);
  expect(await persisted(), "reconciling a grown row writes nothing").toEqual(reconcileCut);
  await writeFile(two, header("s2") + message("user", "replaced", 1));
  await stamp(two);
  rebuilt.length = 0;
  expect(await index.reconcile(root, [await candidate("s2", two)], rebuild), "reconcile rebuilds a row whose file was replaced")
    .toEqual({ rows: [await fileRow("s2", two, { tailBoundaryHash: "r44hzeWEZKxuC4JuseTRFgLzBGRJvQZoFzHqZ-VnT1Q" })], unproven: [] });
  expect(rebuilt).toEqual(["s2"]);
  expect(await persisted(), "reconciling a replaced row writes nothing").toEqual(reconcileCut);
  {
    const locked = await session("locked", header("s6") + message("user", "locked", 1));
    const lockedRow = (await index.entryFromSummary(summary("s6", locked)))!;
    expect(lockedRow).toEqual(await fileRow("s6", locked, { tailBoundaryHash: "wwghYw0JCHl8FzHrCgysA92kV1Pv_Czk7l0d9msWJg8" }));
    await index.save(root, [row, lockedRow]);
    const listed = await candidate("s6", locked);
    if (process.getuid?.() === 0) throw new Error("This lock runs as an unprivileged user");
    await chmod(locked, 0o000);
    rebuilt.length = 0;
    try {
      expect(await reported(async () => ({ result: await index.reconcile(root, [listed], rebuild), rebuilt: [...rebuilt].sort() })),
        "reconcile reports a candidate it can no longer read unproven").toEqual({ value: { result: { rows: [], unproven: [locked] }, rebuilt: ["s6"] }, failures: ["append", "rebuild"] });
    } finally { await chmod(locked, 0o600); }
    expect(await persisted(), "a save replaces the shards it no longer holds").toEqual({
      "catalog-metadata-v3/manifest.json": { version: 3, root, shards: [{ shard: "13", digest }, { shard: "32", digest }], refused: [] },
      "catalog-metadata-v3/shard-13.json": shardDocument("13", [row]), "catalog-metadata-v3/shard-32.json": shardDocument("32", [lockedRow]) });
    expect((await manifestDigests())[0], "the unchanged shard keeps its digest").toEqual({ shard: "13", digest: shard13Digest });
  }
  const lockedCut = await persisted();
  {
    const progress: unknown[] = [];
    expect(await index.reconcile(root, [await candidate("s1", one)], rebuild, (state) => { progress.push(state); return true; }),
      "a stopped reconcile reports every candidate unproven").toEqual({ rows: [], unproven: [one] });
    expect(progress).toEqual([{ proven: 0, unproven: 0 }]);
    expect(await persisted(), "a stopped reconcile writes nothing").toEqual(lockedCut);
  }
  {
    let asked = 0;
    expect(await index.reconcile(root, [await candidate("s3", three)], rebuild, () => { asked += 1; return asked > 1; }),
      "a reconcile stopped before a rebuild reports it unproven").toEqual({ rows: [], unproven: [three] });
    expect(asked).toBe(2);
    expect(await persisted(), "a reconcile stopped before a rebuild writes nothing").toEqual(lockedCut);
  }
  {
    const progress: unknown[] = [];
    const many = await Promise.all(Array.from({ length: 17 }, () => candidate("s1", one)));
    const result = await index.reconcile(root, many, rebuild, (state) => { progress.push(state); return false; });
    expect({ rows: result?.rows.length, unproven: result?.unproven, progress }, "reconcile proves seventeen candidates in two batches")
      .toEqual({ rows: 17, unproven: [], progress: [{ proven: 0, unproven: 0 }, { proven: 16, unproven: 0 }] });
    expect(await persisted(), "proving seventeen candidates writes nothing").toEqual(lockedCut);
  }

  const canonical = await realpath(root);
  const valid = { ...row };
  const shard = catalogMetadataShard(canonical, valid.path);
  const shardPath = join(index.directory, `shard-${shard}.json`);
  const document = (rows: unknown[], extra: Record<string, unknown> = {}) => JSON.stringify({ version: 3, root: canonical, shard, rows, ...extra });
  const loadWritten = async (content: string) => {
    await rm(index.directory, { recursive: true, force: true });
    await mkdir(index.directory, { recursive: true });
    await writeFile(shardPath, content);
    const digest = createHash("sha256").update(content).digest("base64url");
    await writeFile(join(index.directory, "manifest.json"), JSON.stringify({ version: 3, root: canonical, shards: [{ shard, digest }], refused: [] }));
    try {
      const rows = await index.load(root);
      return rows === undefined ? "ignored" : rows.length;
    } finally {
      await rm(index.directory, { recursive: true, force: true });
    }
  };
  const admitted = 1;
  const ignored = "ignored";
  const automation = { kind: "automation", automationId: "01234567-89ab-4def-8123-456789abcdef" };
  for (const [label, content, verdict] of [
    ["a hand-written document", document([valid]), admitted],
    ["a document of another version", document([valid], { version: 2 }), ignored],
    ["a document for another root", document([valid], { root: "/elsewhere" }), ignored],
    ["a document for another shard", document([valid], { shard: shard === "00" ? "01" : "00" }), ignored],
    ["a document with an overlong root", document([valid], { root: "r".repeat(4_097) }), ignored],
    ["a document whose rows are not a list", document([], { rows: { length: 0 } }), ignored],
    ["a document that is a list", "[]", ignored],
    ["a document that is null", "null", ignored],
    ["a document that is not JSON", "{", ignored],
    ["a row automation origin", document([{ ...valid, creationOrigin: automation }]), admitted],
    ["a row with a parent and a name", document([{ ...valid, parentSessionPath: "/parent.jsonl", name: "Named" }]), admitted],
    ["a zero-length row at the bounds", document([{ ...valid, messageCount: 0, size: 0, eofOffset: 0, name: "n".repeat(1_024), firstMessage: "😀".repeat(256) }]), admitted],
    ["a document over the byte bound", document([valid], { padding: "p".repeat(8 * 1_024 * 1_024) }), ignored],
  ] as const) expect(await loadWritten(content), label).toEqual(verdict);
  for (const [label, bad] of [
    ["a null row", null], ["a list row", []],
    ["a row with an overlong id", { ...valid, id: "i".repeat(257) }],
    ["a row with a relative path", { ...valid, path: "sessions/one.jsonl" }],
    ["a row outside the root", { ...valid, path: join(canonical, "..", "other", "one.jsonl") }],
    ["a row at a sibling of the root", { ...valid, path: `${canonical}-sibling/one.jsonl` }],
    ["a row that is not a transcript", { ...valid, path: join(canonical, "one.json") }],
    ["a row with an overlong working directory", { ...valid, cwd: "c".repeat(4_097) }],
    ["a row with an overlong parent", { ...valid, parentSessionPath: "p".repeat(4_097) }],
    ["a row with a parent and an automation origin", { ...valid, parentSessionPath: "/parent.jsonl", creationOrigin: automation }],
    ["a row with another origin kind", { ...valid, creationOrigin: { ...automation, kind: "user" } }],
    ["a row with a malformed automation id", { ...valid, creationOrigin: { kind: "automation", automationId: "automation-1" } }],
    ["a row with a list origin", { ...valid, creationOrigin: [] }],
    ["a row with an overlong name", { ...valid, name: "n".repeat(10_000) }],
    ["a row with a multibyte name over the byte bound", { ...valid, name: "😀".repeat(300) }],
    ["a row with an overlong first message", { ...valid, firstMessage: "f".repeat(10_000) }],
    ["a row with a multibyte first message over the byte bound", { ...valid, firstMessage: "😀".repeat(300) }],
    ["a row with an unreadable creation time", { ...valid, createdAt: "yesterday" }],
    ["a row with an overlong creation time", { ...valid, createdAt: "t".repeat(129) }],
    ["a row with an unreadable update time", { ...valid, updatedAt: "today" }],
    ["a row with an overlong update time", { ...valid, updatedAt: "t".repeat(129) }],
    ["a row with an overlong file identity", { ...valid, fileIdentity: "f".repeat(129) }],
    ["a row with a negative message count", { ...valid, messageCount: -1 }],
    ["a row with a fractional message count", { ...valid, messageCount: 1.5 }],
    ["a row with a negative size", { ...valid, size: -1, eofOffset: -1 }],
    ["a row with a fractional size", { ...valid, size: 1.5, eofOffset: 1.5 }],
    ["a row with an infinite modification time", { ...valid, mtimeMs: null }],
    ["a row whose offset is not its size", { ...valid, eofOffset: valid.size - 1 }],
    ["a row with an overlong tail hash", { ...valid, tailBoundaryHash: "h".repeat(129) }],
  ] as const) expect(await loadWritten(document([bad])), `ignore ${label}`).toEqual(ignored);
  expect(await persisted(), "every admission check leaves no store behind").toEqual({});
  await writeFile(join(home, "linked.json"), document([valid]));
  await mkdir(index.directory, { recursive: true });
  await symlink(join(home, "linked.json"), shardPath);
  try { expect(await index.load(root), "ignore a shard that is a symbolic link").toBeUndefined(); }
  finally { await rm(index.directory, { recursive: true, force: true }); }

  await expect(index.dispose(), "dispose").resolves.toBeUndefined();
  expect(await index.save(root, [row]), "a disposed index writes nothing").toBe(false);
  expect(await persisted()).toEqual({});
  await new CatalogMetadataIndex(gateway).save(root, [row]);
  expect(await index.reconcile(root, [await candidate("s1", one)], rebuild), "a disposed index proves no candidate").toEqual({ rows: [], unproven: [one] });
  expect(await persisted(), "and leaves another owner's save alone").toEqual({
    "catalog-metadata-v3/manifest.json": { version: 3, root, shards: [{ shard: "13", digest: shard13Digest }], refused: [] },
    "catalog-metadata-v3/shard-13.json": shardDocument("13", [row]) });
});
