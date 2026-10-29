import { mkdir, readdir, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it, onTestFinished } from "vitest";
import { countRandomUUID } from "../../test-support/fixed-recording.js";
import { storePathLock } from "../../test-support/store-path-lock.js";
import type { GatewayError } from "../errors.js";
import { BlobStore } from "./blob-store.js";
import type { ByteRange } from "../util/byte-stream.js";

/**
 * `gateway/session-catalog` mutation-path lock for the blob store behind
 * `gateway/blobs/` and `gateway/exports/` (plan §6.5 V4, §6.6;
 * test-support/store-path-lock.ts): limits, initialization, memory and file
 * registration, byte-range leases, reader and production bounds, capacity, expiry,
 * retirement under a held lease, and disposal, with the files each step leaves.
 */
it("blob-store-paths: limits, register, lease ranges, bounds, prune and dispose", async () => {
  const log = await storePathLock({ module: "gateway/session-catalog", name: "blob-store-paths", testFileUrl: import.meta.url, owned: "gateway/blobs" });
  onTestFinished(countRandomUUID());
  const directory = join(log.home, "gateway", "blobs");
  const sources = join(log.home, "sources");
  await mkdir(sources, { recursive: true });
  const source = async (name: string, content: string) => { const path = join(sources, name); await writeFile(path, content); return path; };
  const limits = { maximumItemBytes: 64, maximumItems: 4, maximumTotalBytes: 160, maximumReaders: 2, maximumFileProductions: 1 };

  for (const [label, candidate, expected] of [
    ["a negative item bound is refused", { ...limits, maximumItemBytes: -1 }, "refused"],
    ["a zero item count is refused", { ...limits, maximumItems: 0 }, "refused"],
    ["a single item is accepted", { ...limits, maximumItems: 1 }, "result"],
    ["a total below one item is refused", { ...limits, maximumTotalBytes: 63 }, "refused"],
    ["a total of exactly one item is accepted", { ...limits, maximumTotalBytes: 64 }, "result"],
    ["zero readers are refused", { ...limits, maximumReaders: 0 }, "refused"],
    ["fractional readers are refused", { ...limits, maximumReaders: 1.5 }, "refused"],
    ["zero file productions are refused", { ...limits, maximumFileProductions: 0 }, "refused"],
    ["fractional file productions are refused", { ...limits, maximumFileProductions: 1.5 }, "refused"],
    ["a negative free-space floor is refused", { ...limits, minimumFreeBytes: -1 }, "refused"],
    ["a fractional free-space floor is refused", { ...limits, minimumFreeBytes: 0.5 }, "refused"],
  ] as const) await log.step(label, () => { new BlobStore(candidate, Date.now, directory); return candidate; }, expected);
  await log.step("derived bounds: readers and productions from the item limits", async () => {
    const derived = new BlobStore({ maximumItemBytes: 10, maximumItems: 40, maximumTotalBytes: 100 });
    const id = derived.registerData(Buffer.from("x"), "text/plain");
    const leases = [];
    let readers = 0;
    try { for (; readers < 64; readers += 1) leases.push(await derived.acquire(id)); } catch { /* the bound */ }
    let open!: () => void;
    const gate = new Promise<void>((resolve) => { open = resolve; });
    const productions = Array.from({ length: 8 }, () => derived.withFileProductionAdmission(() => gate));
    open();
    const admitted = (await Promise.allSettled(productions)).filter((production) => production.status === "fulfilled").length;
    for (const lease of leases) await lease.release();
    await derived.dispose();
    return { readers, productions: admitted };
  });

  const store = new BlobStore(limits, Date.now, directory);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "blob-left-by-a-crash"), "stale");
  await log.step("file registration before initialization is refused", async () => store.registerFile(await source("early.txt", "early"), "text/plain"), "refused");
  await log.step("initialization replaces a leftover directory", () => store.initialize(), "result");
  await log.step("initialization again is unchanged", () => store.initialize(), "result");
  const read = async (id: string, range?: ByteRange) => {
    const lease = await store.acquire(id, range);
    const chunks: Buffer[] = [];
    for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk as Buffer));
    await lease.release();
    await lease.release();
    const { stream: _stream, release: _release, ...shape } = lease;
    return { ...shape, body: Buffer.concat(chunks).toString("utf8") };
  };

  let text = "";
  await log.step("register memory data", () => (text = store.registerData(Buffer.from("hello blob store"), "text/plain")), "result");
  await log.step("the same content and type is the same blob", () => store.registerData(Buffer.from("hello blob store"), "text/plain"));
  await log.step("the same content as another type is another blob", () => store.registerData(Buffer.from("hello blob store"), "text/markdown"));
  await log.step("register base64", () => store.register(Buffer.from("base64 body").toString("base64"), "application/octet-stream"));
  await log.step("base64 longer than one item is refused", () => store.register("A".repeat(Math.ceil(64 / 3) * 4 + 4), "text/plain"), "refused");
  await log.step("base64 at the item bound decodes", () => store.register(Buffer.alloc(64, 0x61).toString("base64"), "text/plain"), "result");
  await log.step("data over the item bound is refused", () => store.registerData(Buffer.alloc(65), "text/plain"), "refused");
  await log.step("a type with a control character is refused", () => store.registerData(Buffer.from("x"), "text/plain\u0007"), "refused");
  await log.step("a type with a delete character is refused", () => store.registerData(Buffer.from("x"), "text/\u007f"), "refused");
  await log.step("a type over the metadata bound is refused", () => store.registerData(Buffer.from("x"), "t".repeat(1_025)), "refused");
  await log.step("a type at the metadata bound fits but the store is full", () => store.registerData(Buffer.from("x"), "t".repeat(1_024)), "refused");

  await log.step("read a whole blob", () => read(text), "result");
  await log.step("read a middle range", () => read(text, { start: 6, end: 9 }), "result");
  await log.step("read from an offset to the end", () => read(text, { start: 10 }), "result");
  await log.step("read the last byte", () => read(text, { start: 15, end: 15 }), "result");
  for (const [label, range] of [
    ["an end before the start is refused", { start: 5, end: 4 }],
    ["an end past the blob is refused", { start: 0, end: 16 }],
    ["a negative start is refused", { start: -1, end: 2 }],
    ["a fractional start is refused", { start: 0.5 }],
    ["a fractional end is refused", { start: 0, end: 1.5 }],
  ] as const) await log.step(label, () => read(text, range), "refused");
  await log.step("an unknown blob is refused", () => read("unknown"), "refused");

  await log.step("two held leases fill the readers; a third is refused", async () => {
    const first = await store.acquire(text);
    const second = await store.acquire(text);
    try { return await store.acquire(text); } finally { await first.release(); await second.release(); }
  }, "refused");
  await log.step("a reader is admitted again once a lease is released", () => read(text, { start: 0, end: 4 }), "result");
  await log.step("a lease released twice frees only its own reader", async () => {
    const first = await store.acquire(text);
    const second = await store.acquire(text);
    await first.release();
    await first.release();
    const third = await store.acquire(text);
    try { return await store.acquire(text); } finally { await second.release(); await third.release(); }
  }, "refused");

  await log.step("a production while another runs is refused", async () => {
    let open!: () => void;
    const running = store.withFileProductionAdmission(() => new Promise<string>((resolve) => { open = () => resolve("first"); }));
    try { return await store.withFileProductionAdmission(async () => "second"); } finally { open(); await running; }
  }, "refused");
  await log.step("a production that throws at once releases its admission", async () => {
    const thrown = await store.withFileProductionAdmission(() => { throw new Error("synchronous failure"); }).catch((error: Error) => error.message);
    return { thrown, next: await store.withFileProductionAdmission(async () => "admitted") };
  });
  await log.step("a production that rejects releases its admission", async () => {
    const rejected = await store.withFileProductionAdmission(async () => { throw new Error("asynchronous failure"); }).catch((error: Error) => error.message);
    return { rejected, next: await store.withFileProductionAdmission(async () => "admitted") };
  });

  // Free the memory blobs for the file paths: thirty-one idle minutes expire every one.
  log.advance(31 * 60_000);
  await log.step("prune expires every idle blob", () => { store.prune(); return "<void>"; });
  await log.step("an expired blob is refused", () => read(text), "refused");
  const exported = await source("export.txt", "exported text");
  let file = "";
  await log.step("register a file", async () => { file = await store.registerFile(exported, "text/plain"); return file; }, "result");
  await log.step("the same file content is the same blob and leaves no staging file", () => store.registerFile(exported, "text/plain"), "result");
  await log.step("read a file blob", () => read(file), "result");
  await log.step("read a file blob range", () => read(file, { start: 9, end: 12 }), "result");
  // A file blob whose file is gone, or no longer a file, is retired as missing.
  const replaced = async (name: string, replace: (path: string) => Promise<void>) => {
    const before = new Set(await readdir(directory));
    const id = await store.registerFile(await source(name, `${name} body`), "text/plain");
    const path = join(directory, (await readdir(directory)).find((entry) => !before.has(entry))!);
    await replace(path);
    return { first: await read(id).catch((error: Error) => error.message), again: await read(id).catch((error: Error) => error.message) };
  };
  await log.step("a file blob whose file was removed is retired as missing", () => replaced("removed.txt", (path) => rm(path)));
  await log.step("a file blob whose file became a link loop is retired as missing", () =>
    replaced("looped.txt", async (path) => { await rm(path); await symlink(path, path); }));
  await log.step("a file over the item bound is refused", async () => store.registerFile(await source("large.txt", "x".repeat(65)), "text/plain"), "refused");
  await log.step("a directory is refused", () => store.registerFile(sources, "text/plain"), "refused");
  await log.step("a missing file is refused", () => store.registerFile(join(sources, "missing.txt"), "text/plain"), "refused");
  await log.step("a file with a control-character type is refused", () => store.registerFile(exported, "text/\u0001"), "refused");
  let empty = "";
  await log.step("an empty file", async () => (empty = await store.registerFile(await source("empty.txt", ""), "text/plain")), "result");
  await log.step("read an empty blob", () => read(empty), "result");
  await log.step("a range on an empty blob is refused", () => read(empty, { start: 0 }), "refused");
  await log.step("fill the item count with memory blobs", () => [store.registerData(Buffer.from("one"), "text/plain"),
    store.registerData(Buffer.from("two"), "text/plain")]);
  await log.step("a fifth item is refused", () => store.registerData(Buffer.from("three"), "text/plain"), "refused");
  await log.step("a fifth file is refused before it is copied", async () => store.registerFile(await source("fifth.txt", "fifth"), "text/plain"), "refused");

  await log.step("file storage reports a full disk floor", async () => {
    const floor = new BlobStore({ ...limits, minimumFreeBytes: Number.MAX_SAFE_INTEGER - 64 }, Date.now, join(log.home, "gateway", "blobs-floor"));
    await floor.initialize();
    try { return await floor.registerFile(exported, "text/plain"); } finally { await floor.dispose(); }
  }, "refused");
  await log.step("a store with no directory refuses files", async () => {
    const memory = new BlobStore(limits);
    await memory.initialize();
    try { return await memory.registerFile(exported, "text/plain"); } finally { await memory.dispose(); }
  }, "refused");

  // Prune removes an idle file blob's file in a detached cleanup, so every step that
  // prunes one joins that removal through the public API before its files are recorded:
  // the last lease's release, or disposal.
  const held = await store.acquire(file);
  const emptyLease = await store.acquire(empty);
  log.advance(31 * 60_000);
  await log.step("prune retires every idle blob; a held one keeps its file until its last lease releases", async () => {
    store.prune();
    const refused = await read(empty).catch((error: Error) => error.message);
    await emptyLease.release();
    return { refused };
  });
  await log.step("a held retired blob is refused to new readers", () => read(file), "refused");
  await log.step("registering its content again revives it", () => store.registerFile(exported, "text/plain"), "result");
  await log.step("the revived blob reads", () => read(file, { start: 0, end: 7 }), "result");
  await log.step("releasing the lease keeps the revived blob", async () => { await held.release(); return read(file, { start: 0, end: 7 }); }, "result");
  log.advance(31 * 60_000);
  await log.step("prune with a custom age keeps a blob idle for less", () => { store.prune(60 * 60_000); return read(file, { start: 0, end: 7 }); }, "result");
  await log.step("a file blob whose directory became a file is retired as missing", () => replaced("detached.txt", async () => {
    await rename(directory, `${directory}-moved`);
    await writeFile(directory, "");
  }).finally(async () => { await rm(directory, { force: true }); await rename(`${directory}-moved`, directory); }));
  const lingering = store.registerData(Buffer.from("lingering"), "text/plain");
  const lease = await store.acquire(lingering);
  log.advance(31 * 60_000);
  const present = () => stat(directory).then(() => true, () => false);
  await log.step("prune retires an idle file blob; its content cannot register while the removal runs; disposal joins it", async () => {
    store.prune();
    const retiring = await Promise.resolve().then(() => store.registerData(Buffer.from("exported text"), "text/plain"))
      .catch((error: GatewayError) => ({ message: error.message, code: error.code, retryable: error.retryable }));
    const refused = await read(file).catch((error: Error) => error.message);
    await store.dispose();
    return { retiring, refused, directory: await present() };
  }, "result");
  await log.step("dispose again is the same disposal", () => store.dispose(), "result");
  await log.step("a disposed store refuses data", () => store.registerData(Buffer.from("late"), "text/plain"), "refused");
  await log.step("a disposed store refuses files", () => store.registerFile(exported, "text/plain"), "refused");
  await log.step("a disposed store refuses productions", () => store.withFileProductionAdmission(async () => "late"), "refused");
  await log.step("a disposed store refuses readers", () => read(lingering), "refused");
  await log.step("a disposed store refuses initialization", () => store.initialize(), "refused");
  await log.step("the last lease's release removes the directory", async () => { await lease.release(); return { directory: await present() }; }, "result");
  await log.finish();
});
