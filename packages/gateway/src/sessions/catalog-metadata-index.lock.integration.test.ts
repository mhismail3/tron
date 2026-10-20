import { appendFile, lstat, mkdir, realpath, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it } from "vitest";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { CatalogMetadataIndex, type CatalogMetadataIndexRow, type CatalogMetadataIndexSummary } from "./catalog-metadata-index.js";

/**
 * `gateway/session-catalog` mutation-path lock for the cold-catalog metadata index
 * `gateway/catalog-metadata-v2.json` (plan §6.5 V4, §6.6; test-support/store-path-lock.ts):
 * rows stamped from a summary, saves and their bounds, appends, reconcile with its
 * stop and unproven candidates, document and row admission, and disposal. File times
 * are set explicitly and device/inode identities are aliased, so the golden is the
 * index's own arithmetic over real files.
 */
it("catalog-metadata-index-paths: stamp, save, load, append, reconcile, admission and dispose", async () => {
  const log = await storePathLock({ module: "gateway/session-catalog", name: "catalog-metadata-index-paths", testFileUrl: import.meta.url,
    owned: "gateway/catalog-metadata-v2.json", aliases: ["fileIdentity"] });
  const failures: string[] = [];
  const gateway = join(log.home, "gateway");
  const root = join(log.home, "sessions");
  await mkdir(root, { recursive: true });
  const index = new CatalogMetadataIndex(gateway, (stage) => { failures.push(stage); });
  const time = "2026-01-01T00:00:00.000Z";
  let tick = 0;
  // Each write gets its own whole-second modification time, so sizes and times are the store's evidence.
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

  await log.step("load before a document exists", () => index.load(root));
  await log.step("reconcile before a document exists", () => index.reconcile(root, [], async () => undefined));
  const one = await session("one", header("s1") + message("user", "hello", 1));
  let row!: CatalogMetadataIndexRow;
  await log.step("stamp a row from a summary", async () => { row = (await index.entryFromSummary(summary("s1", one)))!; return row; }, "result");
  await log.step("a long name and first message are bounded", () => index.entryFromSummary(summary("s1", one, { name: "n".repeat(2_000), firstMessage: "f".repeat(2_000) })));
  const refusedSummaries: Array<[string, () => Promise<CatalogMetadataIndexSummary>]> = [
    ["a missing file", async () => summary("s1", join(root, "missing.jsonl"))],
    ["a directory", async () => { await mkdir(join(root, "folder.jsonl")); return summary("s1", join(root, "folder.jsonl")); }],
    ["a symbolic link", async () => { await symlink(one, join(root, "link.jsonl")); return summary("s1", join(root, "link.jsonl")); }],
    ["another session id", async () => summary("s9", one)],
    ["another working directory", async () => ({ ...summary("s1", one), cwd: "/elsewhere" })],
    ["an empty file", async () => summary("s1", await session("empty", ""))],
    ["a header that is not JSON", async () => summary("s1", await session("garbled", "{not json\n"))],
    ["a header of another type", async () => summary("s1", await session("typed", `${JSON.stringify({ type: "message", id: "s1", cwd: "/work" })}\n`))],
    ["a file without a final newline", async () => summary("s1", await session("open", header("s1") + message("user", "hello", 1).trimEnd()))],
    ["a parse of an earlier size", async () => summary("s1", one, { parsedSize: 10 })],
  ];
  for (const [label, prepare] of refusedSummaries) {
    await log.step(`no row is stamped for ${label}`, async () => { const input = await prepare(); return reported(() => index.entryFromSummary(input)); });
  }
  await log.step("a parse of the current size is stamped", async () => reported(async () => index.entryFromSummary(summary("s1", one, { parsedSize: (await lstat(one)).size }))));

  await log.step("save one row", () => index.save(root, [row]), "result");
  await log.step("load the saved rows", () => index.load(root), "result");
  await log.step("load for another catalog root", () => index.load(join(log.home, "elsewhere")));
  await log.step("a save over the entry bound is not written", () => reported(() => index.save(root, Array.from({ length: 25_001 }, () => row))));
  await log.step("a save over the byte bound is not written", () => reported(() => index.save(root,
    Array.from({ length: 2_100 }, () => ({ ...row, cwd: "c".repeat(4_096) })))));
  await log.step("a save into a state directory that is a file is refused", async () => {
    await writeFile(join(log.home, "blocked"), "");
    return new CatalogMetadataIndex(join(log.home, "blocked", "gateway")).save(root, [row]);
  }, "refused");
  await log.step("an unchanged row appends nothing", () => index.append(row));

  await appendFile(one, message("assistant", "hi there", 2) + `${JSON.stringify({ type: "session_info", name: "Named" })}\n` + message("user", "again", 3));
  await stamp(one);
  let grown!: CatalogMetadataIndexRow;
  await log.step("append counts the new lines", async () => { grown = (await index.append(row))!; return grown; }, "result");
  const appends: Array<[string, () => Promise<CatalogMetadataIndexRow>]> = [
    ["a row whose offset is not its size", async () => ({ ...grown, eofOffset: grown.size - 1 })],
    ["a row of another file", async () => ({ ...grown, fileIdentity: "0:0" })],
    ["a row longer than the file", async () => ({ ...grown, size: grown.size + 10, eofOffset: grown.size + 10 })],
    ["a row whose tail no longer matches", async () => ({ ...grown, tailBoundaryHash: "changed" })],
    ["a row with another session id", async () => ({ ...grown, id: "s9" })],
    ["an unchanged size at another time", async () => ({ ...grown, mtimeMs: grown.mtimeMs - 1 })],
    ["an append without a final newline", async () => { await appendFile(one, "{\"type\":\"message\""); await stamp(one); return grown; }],
  ];
  for (const [label, prepare] of appends) await log.step(`no append for ${label}`, async () => { const input = await prepare(); return reported(() => index.append(input)); });
  const lines = async (name: string, appended: string) => {
    const path = await session(name, header(name) + message("user", "start", 1));
    const base = (await index.entryFromSummary(summary(name, path)))!;
    await appendFile(path, appended);
    await stamp(path);
    return base;
  };
  await log.step("no append past a line that is not JSON", async () => { const base = await lines("bad-line", "{oops\n"); return reported(() => index.append(base)); });
  await log.step("no append past a line that is not an object", async () => { const base = await lines("list-line", "[1]\n"); return reported(() => index.append(base)); });
  await log.step("an append skips blank lines and system messages", async () => {
    const base = await lines("system-line", `\n${JSON.stringify({ type: "message", message: { role: "system", content: "context" } })}\n`);
    return reported(() => index.append(base));
  });
  await log.step("an append of a missing file reports its failure", () => reported(() => index.append({ ...grown, path: join(root, "missing.jsonl") })));

  const two = await session("two", header("s2") + message("user", "second", 1));
  const three = await session("three", header("s3") + message("user", "third", 1));
  const five = await session("five", header("s5") + message("user", "fifth", 1));
  await writeFile(one, header("s1") + message("user", "hello", 1));
  await stamp(one);
  row = (await index.entryFromSummary(summary("s1", one)))!;
  await index.save(root, [row, { ...(await index.entryFromSummary(summary("s2", two)))!, messageCount: 7 }]);
  // Candidates of one batch are proven in parallel, so the rebuilds are recorded as a set.
  const rebuilt: string[] = [];
  const rebuild = async (input: { id: string; path: string }) => { rebuilt.push(input.id); return input.id === "s3" ? undefined : summary(input.id, input.path); };
  await log.step("reconcile keeps unchanged rows, rebuilds a new one and reports those it cannot prove", async () => {
    rebuilt.length = 0;
    const result = await index.reconcile(root, [await candidate("s1", one), await candidate("s2", two, "/moved"), await candidate("s3", three),
      await candidate("s4", two), await candidate("s5", five)], rebuild);
    return { result, rebuilt: [...rebuilt].sort() };
  }, "result");
  await appendFile(two, message("assistant", "reply", 2));
  await stamp(two);
  await log.step("reconcile appends a grown row", async () => {
    rebuilt.length = 0;
    return { result: await index.reconcile(root, [await candidate("s2", two)], rebuild), rebuilt: [...rebuilt].sort() };
  });
  await log.step("reconcile rebuilds a row whose file was replaced", async () => {
    await writeFile(two, header("s2") + message("user", "replaced", 1));
    await stamp(two);
    rebuilt.length = 0;
    return { result: await index.reconcile(root, [await candidate("s2", two)], rebuild), rebuilt: [...rebuilt].sort() };
  });
  await log.step("a stopped reconcile reports every candidate unproven", async () => {
    const progress: unknown[] = [];
    const result = await index.reconcile(root, [await candidate("s1", one)], rebuild, (state) => { progress.push(state); return true; });
    return { result, progress };
  });
  await log.step("a reconcile stopped before a rebuild reports it unproven", async () => {
    let asked = 0;
    const result = await index.reconcile(root, [await candidate("s3", three)], rebuild, () => { asked += 1; return asked > 1; });
    return { result, asked };
  });
  await log.step("reconcile proves seventeen candidates in two batches", async () => {
    const progress: unknown[] = [];
    const many = await Promise.all(Array.from({ length: 17 }, () => candidate("s1", one)));
    const result = await index.reconcile(root, many, rebuild, (state) => { progress.push(state); return false; });
    return { rows: result?.rows.length, unproven: result?.unproven, progress };
  });

  // The index binds a document to the catalog root's canonical path (the temporary root may be a symbolic link).
  const canonical = await realpath(root);
  const document = (rows: unknown[], extra: Record<string, unknown> = {}) => JSON.stringify({ version: 3, root: canonical, rows, ...extra });
  // A hand-written document is removed again after its load, so the golden pins each verdict, not the input bytes.
  const loadWritten = async (content: string) => {
    await writeFile(join(gateway, "catalog-metadata-v2.json"), content);
    try { const rows = await index.load(root); return { loaded: rows === undefined ? "ignored" : rows.length }; }
    finally { await rm(join(gateway, "catalog-metadata-v2.json")); }
  };
  const forged = async (label: string, content: string, expected: "admitted" | "ignored") =>
    log.step(`${expected === "admitted" ? "admit" : "ignore"} ${label}`, () => loadWritten(content));
  const valid = { ...row };
  await forged("a hand-written document", document([valid]), "admitted");
  await forged("a document of another version", document([valid], { version: 2 }), "ignored");
  await forged("a document for another root", document([valid], { root: "/elsewhere" }), "ignored");
  await forged("a document with an overlong root", document([valid], { root: "r".repeat(4_097) }), "ignored");
  await forged("a document whose rows are not a list", document([], { rows: { length: 0 } }), "ignored");
  await forged("a document that is a list", "[]", "ignored");
  await forged("a document that is null", "null", "ignored");
  await forged("a document that is not JSON", "{", "ignored");
  await forged("a row automation origin", document([{ ...valid, creationOrigin: { kind: "automation", automationId: "01234567-89ab-4def-8123-456789abcdef" } }]), "admitted");
  await forged("a row with a parent and a name", document([{ ...valid, parentSessionPath: "/parent.jsonl", name: "Named" }]), "admitted");
  for (const [label, bad] of [
    ["a null row", null], ["a list row", []],
    ["a row with an overlong id", { ...valid, id: "i".repeat(257) }],
    ["a row with a relative path", { ...valid, path: "sessions/one.jsonl" }],
    ["a row outside the root", { ...valid, path: join(canonical, "..", "other", "one.jsonl") }],
    ["a row at a sibling of the root", { ...valid, path: `${canonical}-sibling/one.jsonl` }],
    ["a row that is not a transcript", { ...valid, path: join(canonical, "one.json") }],
    ["a row with an overlong working directory", { ...valid, cwd: "c".repeat(4_097) }],
    ["a row with an overlong parent", { ...valid, parentSessionPath: "p".repeat(4_097) }],
    ["a row with a parent and an automation origin", { ...valid, parentSessionPath: "/parent.jsonl", creationOrigin: { kind: "automation", automationId: "01234567-89ab-4def-8123-456789abcdef" } }],
    ["a row with another origin kind", { ...valid, creationOrigin: { kind: "user", automationId: "01234567-89ab-4def-8123-456789abcdef" } }],
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
  ] as const) await forged(label, document([bad]), "ignored");
  await forged("a zero-length row at the bounds", document([{ ...valid, messageCount: 0, size: 0, eofOffset: 0, name: "n".repeat(1_024), firstMessage: "😀".repeat(256) }]), "admitted");
  await forged("a document over the byte bound", document([valid], { padding: "p".repeat(8 * 1_024 * 1_024) }), "ignored");
  await log.step("ignore a document that is a symbolic link", async () => {
    await writeFile(join(log.home, "linked.json"), document([valid]));
    await symlink(join(log.home, "linked.json"), join(gateway, "catalog-metadata-v2.json"));
    try { return { loaded: (await index.load(root)) === undefined ? "ignored" : "loaded" }; }
    finally { await rm(join(gateway, "catalog-metadata-v2.json")); }
  });

  await log.step("dispose", () => index.dispose(), "result");
  await log.step("a disposed index writes nothing", () => index.save(root, [row]));
  await log.step("a disposed index proves no candidate", async () => {
    await new CatalogMetadataIndex(gateway).save(root, [row]);
    return index.reconcile(root, [await candidate("s1", one)], rebuild);
  });
  await log.finish();
});
