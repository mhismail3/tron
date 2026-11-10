import { mkdir, mkdtemp, readdir, realpath, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished, vi } from "vitest";
import type { GatewayError } from "../errors.js";
import { BlobStore, type BlobByteRange } from "./blob-store.js";

it("blob-store-paths: limits, register, lease ranges, bounds, prune and dispose", async () => {
  const home = join(await realpath(await mkdtemp(join(tmpdir(), "tron-blob-store-"))), "home");
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(Date.parse("2026-01-01T00:00:00.000Z"));
  onTestFinished(async () => { vi.useRealTimers(); await rm(join(home, ".."), { recursive: true, force: true }); });
  const advance = (ms: number) => { vi.setSystemTime(Date.now() + ms); };
  const directory = join(home, "gateway", "blobs");
  const sources = join(home, "sources");
  await mkdir(sources, { recursive: true });
  const source = async (name: string, content: string) => { const path = join(sources, name); await writeFile(path, content); return path; };
  const limits = { maximumItemBytes: 64, maximumItems: 4, maximumTotalBytes: 160, maximumReaders: 2, maximumFileProductions: 1 };
  const files = async (): Promise<Record<string, number> | undefined> => {
    const names = await readdir(directory).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
    if (names === undefined) return undefined;
    return Object.fromEntries(await Promise.all(names.sort().map(async (name) => [name, (await stat(join(directory, name))).size])));
  };
  const outcome = async (work: () => unknown) => {
    try { return { result: await work() }; } catch (error) {
      const gateway = error as GatewayError;
      return gateway?.name === "GatewayError"
        ? { refused: gateway.message, code: gateway.code, retryable: gateway.retryable, details: gateway.details ?? null }
        : { refused: (error as Error).message };
    }
  };
  const refusal = (refused: string, code: string, retryable = false) => ({ refused, code, retryable, details: null });
  const notAvailable = refusal("Blob is not available; refresh the session snapshot", "not_found");
  const unsatisfiable = refusal("Requested blob byte range is not satisfiable", "invalid_request");
  const tooLarge = refusal("Blob exceeds the 25 MiB item limit", "conflict");
  const badType = refusal("Blob MIME type exceeds the metadata limit or contains control characters", "conflict");
  const full = refusal("Blob storage is temporarily full", "busy", true);
  const readersFull = refusal("Concurrent blob downloads reached their bounded capacity", "busy", true);
  const fileStorageUnavailable = refusal("Blob file storage is not available", "internal");
  const storageUnavailable = refusal("Blob storage is not available", "internal");
  const range = (body: string, rangeStart: number, totalSize: number) =>
    ({ result: { mimeType: "text/plain", size: body.length, totalSize, rangeStart, rangeEnd: rangeStart + body.length - 1, body } });

  for (const candidate of [{ ...limits, maximumItemBytes: -1 }, { ...limits, maximumItems: 0 }, { ...limits, maximumTotalBytes: 63 },
    { ...limits, maximumReaders: 0 }, { ...limits, maximumReaders: 1.5 }, { ...limits, maximumFileProductions: 0 },
    { ...limits, maximumFileProductions: 1.5 }, { ...limits, minimumFreeBytes: -1 }, { ...limits, minimumFreeBytes: 0.5 }]) {
    expect(() => new BlobStore(candidate, Date.now, directory), JSON.stringify(candidate)).toThrow(expect.objectContaining({ message: "Invalid blob store limits" }));
  }
  for (const candidate of [{ ...limits, maximumItems: 1 }, { ...limits, maximumTotalBytes: 64 }]) {
    expect(() => new BlobStore(candidate, Date.now, directory), JSON.stringify(candidate)).not.toThrow();
  }
  const derived = new BlobStore({ maximumItemBytes: 10, maximumItems: 40, maximumTotalBytes: 100 });
  {
    const id = derived.registerData(Buffer.from("x"), "text/plain");
    const leases = [];
    let readers = 0;
    try { for (; readers < 64; readers += 1) leases.push(await derived.acquire(id)); } catch { }
    let open!: () => void;
    const gate = new Promise<void>((resolve) => { open = resolve; });
    const productions = Array.from({ length: 8 }, () => derived.withFileProductionAdmission(() => gate));
    open();
    const admitted = (await Promise.allSettled(productions)).filter((production) => production.status === "fulfilled").length;
    for (const lease of leases) await lease.release();
    await derived.dispose();
    expect({ readers, productions: admitted }, "derived bounds: readers and productions from the item limits").toEqual({ readers: 10, productions: 5 });
  }

  const store = new BlobStore(limits, Date.now, directory);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "blob-left-by-a-crash"), "stale");
  expect(await outcome(async () => store.registerFile(await source("early.txt", "early"), "text/plain")), "file registration before initialization").toEqual(fileStorageUnavailable);
  expect(await files(), "a refused registration leaves the leftover alone").toEqual({ "blob-left-by-a-crash": 5 });
  await store.initialize();
  expect(await files(), "initialization replaces a leftover directory").toEqual({});
  await store.initialize();
  expect(await files(), "initialization again is unchanged").toEqual({});
  const read = async (id: string, byteRange?: BlobByteRange) => {
    const lease = await store.acquire(id, byteRange);
    const chunks: Buffer[] = [];
    for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk as Buffer));
    await lease.release();
    await lease.release();
    const { stream: _stream, release: _release, ...shape } = lease;
    return { ...shape, body: Buffer.concat(chunks).toString("utf8") };
  };

  const text = store.registerData(Buffer.from("hello blob store"), "text/plain");
  expect(text, "register memory data").toBe("0JrOadWbu7XyXTIyhzIuzeMJwv8acNt6dU2KJOzRZwE");
  expect(store.registerData(Buffer.from("hello blob store"), "text/plain"), "the same content and type is the same blob").toBe(text);
  expect(store.registerData(Buffer.from("hello blob store"), "text/markdown"), "the same content as another type is another blob")
    .toBe("EE0fQ6Xt16z0qUHSIUHXWP3mCWPsiQgHbDu0IqF0OiM");
  expect(store.register(Buffer.from("base64 body").toString("base64"), "application/octet-stream"), "register base64")
    .toBe("n9vWsBrkr3-b1L_7DJ6Nv9tRZTm6IDnJCeK3ModQfQI");
  expect(await outcome(() => store.register("A".repeat(Math.ceil(64 / 3) * 4 + 4), "text/plain")), "base64 longer than one item").toEqual(tooLarge);
  expect(store.register(Buffer.alloc(64, 0x61).toString("base64"), "text/plain"), "base64 at the item bound decodes")
    .toBe("JUw5XLxEXQM7sadBCk6Xmbv56p5tJ9RnvwC6dzZ2lac");
  expect(await outcome(() => store.registerData(Buffer.alloc(65), "text/plain")), "data over the item bound").toEqual(tooLarge);
  for (const type of ["text/plain\u0007", "text/\u007f", "t".repeat(1_025)]) {
    expect(await outcome(() => store.registerData(Buffer.from("x"), type)), JSON.stringify(type)).toEqual(badType);
  }
  expect(await outcome(() => store.registerData(Buffer.from("x"), "t".repeat(1_024))), "a type at the metadata bound fits but the store is full").toEqual(full);

  expect(await outcome(() => read(text)), "read a whole blob").toEqual(range("hello blob store", 0, 16));
  expect(await outcome(() => read(text, { start: 6, end: 9 })), "read a middle range").toEqual(range("blob", 6, 16));
  expect(await outcome(() => read(text, { start: 10 })), "read from an offset to the end").toEqual(range(" store", 10, 16));
  expect(await outcome(() => read(text, { start: 15, end: 15 })), "read the last byte").toEqual(range("e", 15, 16));
  for (const refused of [{ start: 5, end: 4 }, { start: 0, end: 16 }, { start: -1, end: 2 }, { start: 0.5 }, { start: 0, end: 1.5 }]) {
    expect(await outcome(() => read(text, refused)), JSON.stringify(refused)).toEqual(unsatisfiable);
  }
  expect(await outcome(() => read("unknown")), "an unknown blob").toEqual(notAvailable);

  expect(await outcome(async () => {
    const first = await store.acquire(text);
    const second = await store.acquire(text);
    try { return await store.acquire(text); } finally { await first.release(); await second.release(); }
  }), "two held leases fill the readers; a third is refused").toEqual(readersFull);
  expect(await outcome(() => read(text, { start: 0, end: 4 })), "a reader is admitted again once a lease is released").toEqual(range("hello", 0, 16));
  expect(await outcome(async () => {
    const first = await store.acquire(text);
    const second = await store.acquire(text);
    await first.release();
    await first.release();
    const third = await store.acquire(text);
    try { return await store.acquire(text); } finally { await second.release(); await third.release(); }
  }), "a lease released twice frees only its own reader").toEqual(readersFull);

  expect(await outcome(async () => {
    let open!: () => void;
    const running = store.withFileProductionAdmission(() => new Promise<string>((resolve) => { open = () => resolve("first"); }));
    try { return await store.withFileProductionAdmission(async () => "second"); } finally { open(); await running; }
  }), "a production while another runs is refused").toEqual(refusal("Concurrent export generation reached its bounded capacity", "busy", true));
  expect(await store.withFileProductionAdmission(() => { throw new Error("synchronous failure"); }).catch((error: Error) => error.message)).toBe("synchronous failure");
  expect(await store.withFileProductionAdmission(async () => "admitted"), "a production that throws at once releases its admission").toBe("admitted");
  expect(await store.withFileProductionAdmission(async () => { throw new Error("asynchronous failure"); }).catch((error: Error) => error.message)).toBe("asynchronous failure");
  expect(await store.withFileProductionAdmission(async () => "admitted"), "a production that rejects releases its admission").toBe("admitted");

  advance(31 * 60_000);
  store.prune();
  expect(await outcome(() => read(text)), "prune expires every idle blob").toEqual(notAvailable);
  const exported = await source("export.txt", "exported text");
  const file = await store.registerFile(exported, "text/plain");
  expect(file, "register a file").toBe("pw2RAFyZOf6llbhU8HPZQmRMeP6dq7ZQ1qvu_B62jAE");
  const stored = await files();
  expect(Object.values(stored ?? {}), "a file blob is one copy of its bytes").toEqual([13]);
  const [fileName] = Object.keys(stored ?? {});
  expect(fileName).toMatch(/^blob-[0-9a-f-]{36}$/u);
  expect(await store.registerFile(exported, "text/plain"), "the same file content is the same blob").toBe(file);
  expect(await files(), "and leaves no staging file").toEqual({ [fileName!]: 13 });
  expect(await outcome(() => read(file)), "read a file blob").toEqual(range("exported text", 0, 13));
  expect(await outcome(() => read(file, { start: 9, end: 12 })), "read a file blob range").toEqual(range("text", 9, 13));
  const replaced = async (name: string, replace: (path: string) => Promise<void>) => {
    const before = new Set(await readdir(directory));
    const id = await store.registerFile(await source(name, `${name} body`), "text/plain");
    const path = join(directory, (await readdir(directory)).find((entry) => !before.has(entry))!);
    await replace(path);
    return { first: await read(id).catch((error: Error) => error.message), again: await read(id).catch((error: Error) => error.message) };
  };
  const retired = { first: notAvailable.refused, again: notAvailable.refused };
  expect(await replaced("removed.txt", (path) => rm(path)), "a file blob whose file was removed is retired as missing").toEqual(retired);
  expect(await replaced("looped.txt", async (path) => { await rm(path); await symlink(path, path); }), "a file blob whose file became a link loop").toEqual(retired);
  expect(await files(), "retired files are removed").toEqual({ [fileName!]: 13 });
  expect(await outcome(async () => store.registerFile(await source("large.txt", "x".repeat(65)), "text/plain")), "a file over the item bound").toEqual(tooLarge);
  expect(await outcome(() => store.registerFile(sources, "text/plain")), "a directory").toEqual(tooLarge);
  expect(await outcome(() => store.registerFile(join(sources, "missing.txt"), "text/plain")), "a missing file")
    .toEqual({ refused: `ENOENT: no such file or directory, stat '${join(sources, "missing.txt")}'` });
  expect(await outcome(() => store.registerFile(exported, "text/\u0001")), "a file with a control-character type").toEqual(badType);
  expect(await files(), "refused files leave nothing behind").toEqual({ [fileName!]: 13 });
  const empty = await store.registerFile(await source("empty.txt", ""), "text/plain");
  expect(empty, "an empty file").toBe("qVLot834Zp-977q1nNulmE2GgReUNIImrbU4fxYVXCI");
  const withEmpty = await files();
  expect(Object.values(withEmpty ?? {}).sort()).toEqual([0, 13]);
  expect(await outcome(() => read(empty)), "read an empty blob")
    .toEqual({ result: { mimeType: "text/plain", size: 0, totalSize: 0, rangeStart: 0, rangeEnd: -1, body: "" } });
  expect(await outcome(() => read(empty, { start: 0 })), "a range on an empty blob").toEqual(unsatisfiable);
  expect([store.registerData(Buffer.from("one"), "text/plain"), store.registerData(Buffer.from("two"), "text/plain")], "fill the item count with memory blobs")
    .toEqual(["vrL5Npxtm2y52Rd7o245mlr2XY2tUvVKzXk66llgcLU", "9oHWRqtYAV8jaM03HCqFSsjllYE40wgKcjaRYKfajpM"]);
  expect(await outcome(() => store.registerData(Buffer.from("three"), "text/plain")), "a fifth item").toEqual(full);
  expect(await outcome(async () => store.registerFile(await source("fifth.txt", "fifth"), "text/plain")), "a fifth file is refused").toEqual(full);
  expect(await files(), "before it is copied").toEqual(withEmpty);

  expect(await outcome(async () => {
    const floor = new BlobStore({ ...limits, minimumFreeBytes: Number.MAX_SAFE_INTEGER - 64 }, Date.now, join(home, "gateway", "blobs-floor"));
    await floor.initialize();
    try { return await floor.registerFile(exported, "text/plain"); } finally { await floor.dispose(); }
  }), "file storage reports a full disk floor").toEqual(refusal("Blob file storage does not have enough free space", "busy", true));
  expect(await outcome(async () => {
    const memory = new BlobStore(limits);
    await memory.initialize();
    try { return await memory.registerFile(exported, "text/plain"); } finally { await memory.dispose(); }
  }), "a store with no directory refuses files").toEqual(fileStorageUnavailable);

  {
    const shared = join(home, "gateway", "blobs-shared");
    const twice = new BlobStore(limits, Date.now, shared);
    await twice.initialize();
    const id = await twice.registerFile(exported, "text/plain");
    const leases = [await twice.acquire(id), await twice.acquire(id)];
    advance(31 * 60_000);
    twice.prune();
    await leases[0]!.release();
    expect((await readdir(shared)).length, "releasing one of two leases on a retired blob keeps its file").toBe(1);
    await leases[1]!.release();
    expect(await readdir(shared), "the last release removes it").toEqual([]);
    await twice.dispose();
  }

  const held = await store.acquire(file);
  const emptyLease = await store.acquire(empty);
  advance(31 * 60_000);
  store.prune();
  expect(await read(empty).catch((error: Error) => error.message), "prune retires every idle blob").toBe(notAvailable.refused);
  await emptyLease.release();
  expect(await files(), "a held one keeps its file until its last lease releases").toEqual({ [fileName!]: 13 });
  expect(await outcome(() => read(file)), "a held retired blob is refused to new readers").toEqual(notAvailable);
  expect(await store.registerFile(exported, "text/plain"), "registering its content again revives it").toBe(file);
  expect(await outcome(() => read(file, { start: 0, end: 7 })), "the revived blob reads").toEqual(range("exported", 0, 13));
  await held.release();
  expect(await outcome(() => read(file, { start: 0, end: 7 })), "releasing the lease keeps the revived blob").toEqual(range("exported", 0, 13));
  expect(await files(), "in its original file").toEqual({ [fileName!]: 13 });
  advance(31 * 60_000);
  store.prune(60 * 60_000);
  expect(await outcome(() => read(file, { start: 0, end: 7 })), "prune with a custom age keeps a blob idle for less").toEqual(range("exported", 0, 13));
  expect(await replaced("detached.txt", async () => {
    await rename(directory, `${directory}-moved`);
    await writeFile(directory, "");
  }).finally(async () => { await rm(directory, { force: true }); await rename(`${directory}-moved`, directory); }), "a file blob whose directory became a file").toEqual(retired);
  const afterDetach = await files();
  expect(Object.keys(afterDetach ?? {}).length, "the detached blob's restored file stays until disposal").toBe(2);
  expect(afterDetach).toMatchObject({ [fileName!]: 13 });
  expect(Object.values(afterDetach ?? {}).sort()).toEqual([13, 17]);
  const lingering = store.registerData(Buffer.from("lingering"), "text/plain");
  const lease = await store.acquire(lingering);
  advance(31 * 60_000);
  store.prune();
  const retiring = await Promise.resolve().then(() => store.registerData(Buffer.from("exported text"), "text/plain"))
    .catch((error: GatewayError) => ({ message: error.message, code: error.code, retryable: error.retryable }));
  expect(retiring, "an idle file blob's content cannot register while its removal runs")
    .toEqual({ message: "Blob storage is retiring matching content", code: "busy", retryable: true });
  expect(await read(file).catch((error: Error) => error.message), "prune retires an idle file blob").toBe(notAvailable.refused);
  await store.dispose();
  expect(await files(), "disposal joins the removal; a held lease keeps the directory").toEqual({});
  await expect(store.dispose(), "dispose again is the same disposal").resolves.toBeUndefined();
  expect(await outcome(() => store.registerData(Buffer.from("late"), "text/plain")), "a disposed store refuses data").toEqual(storageUnavailable);
  expect(await outcome(() => store.registerFile(exported, "text/plain")), "a disposed store refuses files").toEqual(fileStorageUnavailable);
  expect(await outcome(() => store.withFileProductionAdmission(async () => "late")), "a disposed store refuses productions").toEqual(storageUnavailable);
  expect(await outcome(() => read(lingering)), "a disposed store refuses readers").toEqual(notAvailable);
  expect(await outcome(() => store.initialize()), "a disposed store refuses initialization").toEqual(storageUnavailable);
  await lease.release();
  expect(await files(), "the last lease's release removes the directory").toBeUndefined();
});
