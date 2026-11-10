import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished, vi } from "vitest";
import { GatewayError } from "../errors.js";
import { durableAtomicWriteJson } from "../foundation/durable-json.js";
import { CommandReceiptStore } from "./command-receipts.js";

const PHONE_HASH = "OVXw5T5Cj7OwCQ_yA-RxcNbq6swctisJuZ6kxTCdFQI";
const RECEIPT_FILE: Record<string, string> = {
  "rename-0001|session.rename": "ZhZU7hwlkN657kEM4pmQKD8AuCeC8iK7ywbQn3nBHiU",
  "tablet:rename-0001|session.rename": "ErIOVVkFeT11sjXnYgHroEWs8MBxnh2yrU-t5h3hbno",
  "rename-0001|session.archive": "FC51c18J7P0L-8BCJ8z4sdMGrWY4nKGq_6gUh1O4k4M",
  "delete-0001|session.delete": "gwNnMsXkalpGrTskE0ZKGUyr693mlNCxK3JA3VFhTEI",
  "fork-0001|session.fork": "E4VG8KzLFZFE4YVeufKAcSF7lFSEHLyOsWKVHWoflMU",
  "steer-0001|home.steerTask": "fiZl0dXMav1j01ZY7AB4g3i1Xc6A_N1dq01sGtoI_Uc",
  "prompt-0001|session.prompt": "buU3IMhRdft8xqINjbscedLiCLkHW0gG12WtgtxnSug",
  "export-0001|session.export": "DNQlhl9Bw3qgcIniS_W21v6KJI5gMe5vnK6GmCe__FQ",
  "editor-0001|extension.editor.update": "je0FSFERaKJTKu7TJlzhN9WEBUi8lTxKKKeMJIpFutw",
  "fill-0001|session.rename": "_n163GzFvRszO2dm5FAAerVEwzwUPleDYubLByHwIFE",
  "fill-0003|session.rename": "X4I8Ae1_MGb8uAIOhZNimhqbPwKKLcCZ-kEaToSOZKw",
  "bytes-0002|session.rename": "f4KMxAISjfqbRmINkc8QHg65UpEFlTZ-cbTuPjmHX40",
  "bytes-0003|session.rename": "7WSZyHvcSn5MxhroEbJkfYAy-dYys67tLH7Fzp_NMZg",
  "bytes-0004|session.rename": "r-l6dBaHzgHxxD6pWcXRbVa70byqM0Glqgz-nMyXiP8",
  "lane-0001|session.rename": "Krnr4svwkFdQRTuAobmLudH-rwe0oPTVanuVljT4cq8",
  "empty-0001|session.rename": "oAKMw3FL0aKFbROfR9j1ToqsczT3zw6Xinwi7zAGrsg",
  "broken-0001|session.rename": "rKGYFucl3E5HhqIaVsRtbIVBs5GeeihetJy7EVOJVVY",
  "extra-0001|session.rename": "N37X-rBFfEjXWVFIcr-NOSK134LSZXFMNuQX6GAPd-0",
  "other-0001|session.rename": "FzMuXrHOshC72HSNDwPfzZuclpKx1C3TfGSum4jbe-Q",
  "noresult-0001|session.rename": "d_OEhst10eCcitNRCOGXjt_gJ91lksQhqQYGXnvek84",
  "nobind-0001|session.rename": "hipKWazEWGktyOUKyGvipHr7dD7yGI0_TfM38jprlKg",
  "null-0001|session.rename": "yO7HsypqXYErekt1izF4QUL5D60FEdHBnzqvdKoOjio",
  "array-0001|session.rename": "21dPgue96qflS0fj5CY4xfPriaH2y6drccP0M8EB4HE",
  "bound-0001|session.rename": "z_YFbjrlfvNZVkoBGVZI37tjXLnUsuat_uqVUFidLOo",
  "bind-0001|session.rename": "3vnDVqslT-9qTzWbI7iALhwILOxUPhVxs9mh-44cP-E",
  "bind-0002|session.rename": "z2OHXCXjH0-iZdL6BbFatz3VTytgdeiIP7BC-UVpVgg",
  "bind-0003|session.rename": "7OCAqqs33_pORsrY-iJHTowtn58cuh2AbIv6kATjOW4",
  "bind-0004|session.rename": "2pVdpfJNPODWuahosiJyRkkycIYe7LDEcDQ0Y0UbvTU",
  "bind-0005|session.rename": "1nc5LVKwtdmoIRIBGc8uEOKEV8YfltClRlwmq7e23Gg",
  "bind-0006|session.rename": "O5zKRLk22-8wYShBLScuMwdNVIXI28Gj64aSxQhgZnk",
  "bind-0007|session.rename": "2yrBHS49IiDDgD1qhL5MI0VTy-z4_897LIsXV_LhMPo",
  "bind-0008|session.rename": "wkMLJp0OZuABCFaUZ2F-l_0uZhceAn-LHibz_HufzTs",
  "bind-0009|session.rename": "C-YlRaUr8yARZ9eD39wIinved0iFBzEr3MQM9UfV3Tc",
  "bind-0010|session.rename": "KenIxRSdOIEZ0qr5lTt499gZ2uy4AOifP5nsGQkqlNk",
  "bind-0011|session.rename": "7qht5M8f9xrkQBZkSFXu6GW-ZDdiRyADCmAIEz1Q6vM",
  "hash-0001|session.rename": "OZzBxENO_s1n1DxpiPDA9L-gb3K31g06JOslrxeu_AY",
  "status-0001|session.rename": "rtgXsW8bHM4R_cl9nKepEF2iXihZ8H19fW-6FZ1kGxc",
  "result-0001|session.rename": "kQribBRAl3uDk89uXCBjO_Wq32NFDGq4ZigvmPzGjcw",
  "time-0001|session.rename": "nRriCRHOiMWUTdC0TFfNzecdb-5Joe1UmNVcKotqHfY",
};
const fileOf = (key: string) => `${RECEIPT_FILE[key] ?? expect.unreachable(`no literal receipt name for ${key}`)}.json`;
const receiptDocument = (commandId: string, method: string, status: "pending" | "completed", createdAt: string,
  extra: { result?: unknown; binding?: unknown; identityHash?: string } = {}) => ({
  version: extra.binding === undefined ? 1 : 2, identityHash: extra.identityHash ?? PHONE_HASH,
  ...(extra.binding === undefined ? {} : { binding: extra.binding }), commandId, method, status, createdAt,
  ...(extra.result === undefined ? {} : { result: extra.result }) });

it("command-receipt-paths: execute, replay, fence, bound, prune and dispose", async () => {
  const h = await receiptHome();
  const phone = PHONE;
  const other = "device:lock-tablet";
  const T = (minutes: number) => new Date(EPOCH + minutes * 60_000).toISOString();
  const files = async (): Promise<Record<string, unknown>> => {
    const names = await readdir(h.directory).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return []; throw error; });
    const found: Record<string, unknown> = {};
    for (const name of names.sort()) {
      const bytes = await readFile(join(h.directory, name));
      try { found[name] = JSON.parse(bytes.toString("utf8")); } catch { found[name] = `<${bytes.length} bytes>`; }
    }
    return found;
  };
  let expected: Record<string, unknown> = {};
  const holds = async (label: string) => { expect(await files(), `${label}: receipt files`).toEqual(expected); };
  const uncertain = () => new GatewayError("conflict", "effect may have applied", false, { outcomeUnknown: true });
  const fenced = (message: string) => ({ refused: message, code: "conflict", retryable: false, details: { outcomeUnknown: true } });
  const plain = (message: string) => ({ refused: message, code: null, retryable: null, details: null });
  let store = new CommandReceiptStore(h.home);

  expect(await outcome(() => store.execute(phone, "session.rename", "short", h.run({ ok: true }))), "refuse an unstable command id")
    .toEqual({ refused: "Mutating requests require a stable commandId", code: "invalid_request", retryable: false, details: null });
  expect(await store.status(phone, "session.rename", "rename-0001"), "status of a missing receipt").toEqual({ status: "missing" });
  await holds("before any execution");
  expect(await h.counted(() => store.execute(phone, "session.rename", "rename-0001", h.run({ updated: true }))), "execute fresh").toEqual({ result: { updated: true }, ran: 1 });
  expected[fileOf("rename-0001|session.rename")] = receiptDocument("rename-0001", "session.rename", "completed", T(0), { result: { updated: true } });
  await holds("execute fresh");
  expect(await h.counted(() => store.execute(phone, "session.rename", "rename-0001", h.run({ updated: false }))), "replay returns the stored result without running")
    .toEqual({ result: { updated: true }, ran: 0 });
  expect(await store.status(phone, "session.rename", "rename-0001"), "status of a completed receipt").toEqual({ status: "completed", result: { updated: true } });
  await holds("replay");
  expect(await h.counted(() => store.execute(other, "session.rename", "rename-0001", h.run({ updated: "other" }))), "the same command id from another identity runs")
    .toEqual({ result: { updated: "other" }, ran: 1 });
  expected[fileOf("tablet:rename-0001|session.rename")] = receiptDocument("rename-0001", "session.rename", "completed", T(0),
    { result: { updated: "other" }, identityHash: "MmRdLPlhoFLLxRQbjiuhPhWADoz7XgyeqronOzfxb7A" });
  await holds("another identity");
  expect(await h.counted(() => store.execute(phone, "session.archive", "rename-0001", h.run(null))), "the same command id for another method runs").toEqual({ result: null, ran: 1 });
  expected[fileOf("rename-0001|session.archive")] = receiptDocument("rename-0001", "session.archive", "completed", T(0), { result: null });
  await holds("another method");
  expect(await outcome(() => store.execute(phone, "session.delete", "delete-0001", h.fail(new GatewayError("not_found", "no such session")))),
    "a definitive rejection").toEqual({ refused: "no such session", code: "not_found", retryable: false, details: null });
  await holds("a definitive rejection leaves no receipt");
  expect(await h.counted(() => store.execute(phone, "session.delete", "delete-0001", h.run({ deleted: true }))), "the rejected command may run again")
    .toEqual({ result: { deleted: true }, ran: 1 });
  expected[fileOf("delete-0001|session.delete")] = receiptDocument("delete-0001", "session.delete", "completed", T(0), { result: { deleted: true } });
  await holds("the rejected command ran again");
  expect(await outcome(() => store.execute(phone, "session.fork", "fork-0001", h.fail(uncertain()))), "an uncertain failure").toEqual(fenced("effect may have applied"));
  expected[fileOf("fork-0001|session.fork")] = receiptDocument("fork-0001", "session.fork", "pending", T(0));
  await holds("an uncertain failure keeps a pending fence");
  expect(await store.status(phone, "session.fork", "fork-0001"), "status of the pending fence").toEqual({ status: "pending" });
  expect(await outcome(() => h.counted(() => store.execute(phone, "session.fork", "fork-0001", h.run({ forked: true })))), "the fenced command is refused")
    .toEqual(fenced("Previous command outcome is uncertain; refresh authoritative state instead of replaying"));
  expect(h.calls(), "without running: operations run so far").toBe(6);
  await holds("the fence");
  const routes: string[] = [];
  const bound = { onRouteBound: (category: string) => { routes.push(category); }, resolveBinding: () => ({ homeId: "home-1", bindingRevision: 2, physicalSessionId: "chapter-1" }) };
  expect(await store.execute(phone, "home.steerTask", "steer-0001", h.run({ steered: true }), bound), "a bound command").toEqual({ steered: true });
  expect(routes, "records its route").toEqual(["fresh"]);
  expected[fileOf("steer-0001|home.steerTask")] = receiptDocument("steer-0001", "home.steerTask", "completed", T(0),
    { result: { steered: true }, binding: { homeId: "home-1", bindingRevision: 2, physicalSessionId: "chapter-1" } });
  await holds("a bound command writes a version 2 receipt with its binding");
  expect(await store.execute(phone, "home.steerTask", "steer-0001", h.run({ steered: false }), bound), "its replay").toEqual({ steered: true });
  expect(routes, "reports a replayed route").toEqual(["fresh", "replay"]);
  expect(await outcome(() => store.execute(phone, "session.rename", "early-0001", h.run({}), { respondBeforeCompletion: true })),
    "an early response is refused for a non-prompt method").toEqual(plain("Early receipt responses are restricted to prompt methods"));
  await holds("the bound replay and the early refusal");
  const completions: Promise<void>[] = [];
  expect(await store.execute(phone, "session.prompt", "prompt-0001", h.run({ accepted: true }), { respondBeforeCompletion: true,
    onCompletion: (completion) => { completions.push(completion); } }), "a prompt answers before its completion is durable").toEqual({ accepted: true });
  await Promise.all(completions);
  expect(completions.length, "and hands its completion to the caller").toBe(1);
  expected[fileOf("prompt-0001|session.prompt")] = receiptDocument("prompt-0001", "session.prompt", "completed", T(0), { result: { accepted: true } });
  await holds("the prompt's completed receipt");
  expect(await outcome(() => store.execute(phone, "session.export", "export-0001", h.run({ text: "x".repeat(1_100_000) }))), "an oversized result is refused")
    .toEqual(fenced("Successful command receipt exceeds its bounded capacity; refresh authoritative state instead of replaying"));
  expected[fileOf("export-0001|session.export")] = receiptDocument("export-0001", "session.export", "pending", T(0));
  await holds("and stays fenced");
  expect(await store.status(phone, "session.export", "export-0001"), "status of the oversized command").toEqual({ status: "pending" });
  expect(await store.execute(phone, "extension.editor.update", "editor-0001", h.run({ saved: true })), "an editor update").toEqual({ saved: true });
  const editor = fileOf("editor-0001|extension.editor.update");
  expected[editor] = receiptDocument("editor-0001", "extension.editor.update", "completed", T(0), { result: { saved: true } });
  await holds("an editor update");
  await mkdir(h.directory, { recursive: true });
  const crashTemporary = `${"A".repeat(43)}.json.123.0123456789ab.tmp`;
  await writeFile(join(h.directory, crashTemporary), "{");
  expected[crashTemporary] = "<1 bytes>";
  await holds("a crash temporary");
  h.advance(11 * 60_000);
  await store.prune();
  delete expected[editor];
  delete expected[crashTemporary];
  await holds("prune after eleven minutes drops the editor update and the crash temporary");
  h.advance(24 * 60 * 60_000);
  await store.prune();
  expected = { [fileOf("fork-0001|session.fork")]: expected[fileOf("fork-0001|session.fork")], [fileOf("export-0001|session.export")]: expected[fileOf("export-0001|session.export")] };
  await holds("prune after a day drops completed receipts and keeps pending fences");
  expect(await h.counted(() => store.execute(phone, "session.rename", "rename-0001", h.run({ updated: "again" }))), "a pruned command runs again")
    .toEqual({ result: { updated: "again" }, ran: 1 });
  expected[fileOf("rename-0001|session.rename")] = receiptDocument("rename-0001", "session.rename", "completed", T(24 * 60 + 11), { result: { updated: "again" } });
  await holds("the pruned command's new receipt");
  await store.dispose();

  store = new CommandReceiptStore(h.home, undefined, { maximumEntries: 4, maximumAgeMs: 60_000 });
  expect(await store.execute(phone, "session.rename", "fill-0001", h.run({})), "fill one entry").toEqual({});
  expected[fileOf("fill-0001|session.rename")] = receiptDocument("fill-0001", "session.rename", "completed", T(24 * 60 + 11), { result: {} });
  expect(await outcome(() => store.execute(phone, "session.rename", "fill-0002", h.run({}))), "a full store refuses new commands while fences remain").toEqual(CAPACITY_FULL);
  await holds("the full store");
  h.advance(2 * 60_000);
  expect(await h.counted(() => store.execute(phone, "session.rename", "fill-0003", h.run({ admitted: true }))),
    "an expired receipt is pruned at the capacity boundary to admit a command").toEqual({ result: { admitted: true }, ran: 1 });
  delete expected[fileOf("rename-0001|session.rename")];
  delete expected[fileOf("fill-0001|session.rename")];
  expected[fileOf("fill-0003|session.rename")] = receiptDocument("fill-0003", "session.rename", "completed", T(24 * 60 + 13), { result: { admitted: true } });
  await holds("the capacity-boundary prune");
  expect(() => new CommandReceiptStore(h.home, undefined, { maximumEntries: 0 }), "an invalid capacity is refused").toThrow(expect.objectContaining({ message: "Invalid command receipt capacity" }));

  const forged = async (label: string, method: string, commandId: string, content: string, expectedOutcome: unknown) => {
    const name = fileOf(`${commandId}|${method}`);
    const written = content.replaceAll("<identity>", PHONE_HASH);
    await writeFile(join(h.directory, name), written);
    let stored: unknown;
    try { stored = JSON.parse(written); } catch { stored = `<${Buffer.byteLength(written)} bytes>`; }
    expected[name] = stored;
    expect(await outcome(() => store.status(phone, method, commandId)), label).toEqual(expectedOutcome);
    await holds(`${label} leaves the forged receipt in place`);
  };
  const malformed = fenced("Idempotency receipt is malformed; refresh authoritative state instead of replaying");
  await forged("refuse an empty receipt", "session.rename", "empty-0001", "", fenced("Idempotency receipt is empty; refresh authoritative state instead of replaying"));
  await forged("refuse a malformed receipt", "session.rename", "broken-0001", "{", fenced("Idempotency receipt is malformed or oversized; refresh authoritative state instead of replaying"));
  await forged("refuse a receipt with an unknown key", "session.rename", "extra-0001",
    JSON.stringify({ version: 1, identityHash: "<identity>", commandId: "extra-0001", method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z", note: 1 }), malformed);
  await forged("refuse a receipt for another command", "session.rename", "other-0001",
    JSON.stringify({ version: 1, identityHash: "<identity>", commandId: "other-0002", method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z" }), IDENTITY_MISMATCH);
  await forged("refuse a completed receipt without a result", "session.rename", "noresult-0001",
    JSON.stringify({ version: 1, identityHash: "<identity>", commandId: "noresult-0001", method: "session.rename", status: "completed", createdAt: "2026-01-01T00:00:00.000Z" }), malformed);
  await forged("refuse a version 2 receipt without a binding", "session.rename", "nobind-0001",
    JSON.stringify({ version: 2, identityHash: "<identity>", commandId: "nobind-0001", method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z" }), malformed);
  const receipt = (commandId: string, extra: Record<string, unknown>) => JSON.stringify({ version: 2, identityHash: "<identity>", commandId,
    method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z", ...extra });
  const binding = { homeId: "home-1", bindingRevision: 1, physicalSessionId: "chapter-1" };
  await forged("refuse a null receipt", "session.rename", "null-0001", "null", malformed);
  await forged("refuse an array receipt", "session.rename", "array-0001", "[]", malformed);
  await forged("admit a version 2 receipt with a binding", "session.rename", "bound-0001", receipt("bound-0001", { binding }), { result: { status: "pending" } });
  for (const [label, commandId, extra] of [
    ["refuse a null binding", "bind-0001", { binding: null }],
    ["refuse an array binding", "bind-0002", { binding: [] }],
    ["refuse an empty home id", "bind-0003", { binding: { ...binding, homeId: "" } }],
    ["refuse a long home id", "bind-0004", { binding: { ...binding, homeId: "h".repeat(201) } }],
    ["refuse a zero binding revision", "bind-0005", { binding: { ...binding, bindingRevision: 0 } }],
    ["refuse a fractional binding revision", "bind-0006", { binding: { ...binding, bindingRevision: 1.5 } }],
    ["refuse an empty physical session", "bind-0007", { binding: { ...binding, physicalSessionId: "" } }],
    ["refuse a long physical session", "bind-0008", { binding: { ...binding, physicalSessionId: "p".repeat(201) } }],
    ["refuse a binding with an extra key", "bind-0009", { binding: { ...binding, chapter: 1 } }],
    ["refuse a version 1 receipt with a binding", "bind-0010", { version: 1, binding }],
    ["refuse an unknown version", "bind-0011", { version: 3 }],
    ["refuse a bad identity hash", "hash-0001", { version: 1, identityHash: "short" }],
    ["refuse an unknown status", "status-0001", { version: 1, status: "running" }],
    ["refuse a pending receipt with a result", "result-0001", { version: 1, result: 1 }],
    ["refuse a bad creation time", "time-0001", { version: 1, createdAt: "yesterday" }],
  ] as const) await forged(label, "session.rename", commandId, receipt(commandId, extra), malformed);
  expect(await outcome(() => h.counted(() => store.execute(phone, "session.rename", "broken-0001", h.run({})))), "execute over a malformed receipt is refused")
    .toEqual(fenced("Idempotency receipt is malformed or oversized; refresh authoritative state instead of replaying"));
  await holds("without writing");
  expect(h.calls(), "without running: operations run so far").toBe(13);
  await store.dispose();
  expect(await outcome(() => store.execute(phone, "session.rename", "late-0001", h.run({}))), "a disposed store refuses work")
    .toEqual({ refused: "Command receipt store is shutting down", code: "conflict", retryable: true, details: null });
  await holds("a disposed store writes nothing");
  h.advance(60 * 60_000);

  let failWrite: "pending" | "completed" | undefined;
  let afterCompleted: (() => Promise<void>) | undefined;
  const writer = async (path: string, value: unknown, mode?: number) => {
    if (failWrite !== undefined && (value as { status?: unknown }).status === failWrite) {
      failWrite = undefined;
      throw new Error(`injected ${(value as { status: string }).status} receipt write failure`);
    }
    await durableAtomicWriteJson(path, value, mode);
    const hook = afterCompleted;
    if (hook && (value as { status?: unknown }).status === "completed") { afterCompleted = undefined; await hook(); }
  };
  await rm(h.directory, { recursive: true, force: true });
  expected = {};
  store = new CommandReceiptStore(h.home, writer, { maximumAggregateBytes: RECEIPT_BYTES, maximumAgeMs: 60_000 });
  failWrite = "pending";
  expect(await outcome(() => store.execute(phone, "session.rename", "bytes-0001", h.run({}))), "a failed pending write").toEqual(plain("injected pending receipt write failure"));
  await holds("a failed pending write leaves no receipt");
  const bytesAt = T(24 * 60 + 13 + 60);
  expect(await h.counted(() => store.execute(phone, "session.rename", "bytes-0002", h.run({ first: true }))), "and no reservation: one receipt fits the aggregate bytes")
    .toEqual({ result: { first: true }, ran: 1 });
  expected[fileOf("bytes-0002|session.rename")] = receiptDocument("bytes-0002", "session.rename", "completed", bytesAt, { result: { first: true } });
  await holds("one receipt");
  expect(await outcome(() => store.execute(phone, "session.rename", "bytes-0003", h.run({}))), "a second receipt exceeds them").toEqual(CAPACITY_FULL);
  await holds("the refused second receipt");
  h.advance(2 * 60_000);
  await store.prune();
  expected = {};
  await holds("an explicit prune frees the bytes");
  expect(await h.counted(() => store.execute(phone, "session.rename", "bytes-0003", h.run({ second: true }))), "the second receipt then fits")
    .toEqual({ result: { second: true }, ran: 1 });
  expected[fileOf("bytes-0003|session.rename")] = receiptDocument("bytes-0003", "session.rename", "completed", T(24 * 60 + 13 + 62), { result: { second: true } });
  await holds("the second receipt");
  h.advance(2 * 60_000);
  await store.prune();
  failWrite = "completed";
  expect(await outcome(() => store.execute(phone, "session.rename", "bytes-0004", h.run({}))), "a failed completed write").toEqual(plain("injected completed receipt write failure"));
  expected = { [fileOf("bytes-0004|session.rename")]: receiptDocument("bytes-0004", "session.rename", "pending", T(24 * 60 + 13 + 64)) };
  await holds("a failed completed write keeps the pending fence");
  expect(await store.status(phone, "session.rename", "bytes-0004"), "status after the failed completed write").toEqual({ status: "pending" });
  await holds("status after the failed completed write");
  await store.dispose();
  await rm(h.directory, { recursive: true, force: true });
  store = new CommandReceiptStore(h.home, writer);
  afterCompleted = async () => { h.advance(1_000); await store.prune(0); };
  expect(await h.counted(() => store.execute(phone, "session.rename", "lane-0001", h.run({ once: true }))), "a prune during the command's own completion")
    .toEqual({ result: { once: true }, ran: 1 });
  expected = { [fileOf("lane-0001|session.rename")]: receiptDocument("lane-0001", "session.rename", "completed", T(24 * 60 + 13 + 64), { result: { once: true } }) };
  await holds("keeps its receipt");
  expect(await h.counted(() => store.execute(phone, "session.rename", "lane-0001", h.run({ twice: true }))), "so its duplicate replays instead of running")
    .toEqual({ result: { once: true }, ran: 0 });
  await holds("the replay");
  await store.dispose();
});

const EPOCH = Date.parse("2026-01-01T00:00:00.000Z");
const PHONE = "device:lock-phone";
const RECEIPT_BYTES = 1_048_576 + 4 * 1_024;

async function receiptHome() {
  const home = await mkdtemp(join(tmpdir(), "tron-command-receipts-"));
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(EPOCH);
  onTestFinished(async () => { vi.useRealTimers(); await rm(home, { recursive: true, force: true }); });
  const directory = join(home, "gateway", "command-receipts");
  let calls = 0;
  return {
    home, directory,
    advance: (ms: number) => { vi.setSystemTime(Date.now() + ms); },
    calls: () => calls,
    run: (result: unknown) => async () => { calls += 1; return result as never; },
    fail: (error: Error) => async () => { calls += 1; throw error; },
    async counted(work: () => Promise<unknown>) { const before = calls; const result = await work(); return { result, ran: calls - before }; },
    async receipts(): Promise<Record<string, { method: string; status: string; createdAt: string; result?: unknown }>> {
      const names = await readdir(directory).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return []; throw error; });
      const receipts: Record<string, { method: string; status: string; createdAt: string; result?: unknown }> = {};
      for (const name of names) {
        expect(name, "only receipt files remain").toMatch(/^[A-Za-z0-9_-]{43}\.json$/u);
        const { commandId, method, status, createdAt, result } = JSON.parse(await readFile(join(directory, name), "utf8"));
        receipts[commandId] = { method, status, createdAt, ...(result === undefined ? {} : { result }) };
      }
      return receipts;
    },
  };
}

async function outcome(work: () => Promise<unknown>) {
  try { return { result: await work() }; } catch (error) {
    const { code, retryable, details } = error as GatewayError;
    return { refused: (error as Error).message, code: code ?? null, retryable: retryable ?? null, details: details ?? null };
  }
}

const CAPACITY_FULL = { refused: "Command receipt capacity is full; completed receipts expire, but unresolved outcomes retain replay protection and require operator reconciliation",
  code: "busy", retryable: true, details: null };
const IDENTITY_MISMATCH = { refused: "Idempotency receipt identity mismatch; refresh authoritative state instead of replaying",
  code: "conflict", retryable: false, details: { outcomeUnknown: true } };
const rename = (createdAt: string, result?: unknown) => ({ method: "session.rename", status: "completed", createdAt, ...(result === undefined ? {} : { result }) });

it("command-receipt-concurrency: bounds, rebuild windows and lane lifetimes", async () => {
  const h = await receiptHome();

  for (const capacity of [{ maximumAggregateBytes: RECEIPT_BYTES - 1 }, { maximumAggregateBytes: RECEIPT_BYTES + 0.5 },
    { maximumAgeMs: -1 }, { maximumAgeMs: 0.5 }, { maximumEntries: 1.5 }]) {
    expect(() => new CommandReceiptStore(h.home, undefined, capacity), JSON.stringify(capacity)).toThrow(expect.objectContaining({ message: "Invalid command receipt capacity" }));
  }
  for (const capacity of [{ maximumAggregateBytes: RECEIPT_BYTES }, { maximumAgeMs: 0 }]) {
    expect(() => new CommandReceiptStore(h.home, undefined, capacity), JSON.stringify(capacity)).not.toThrow();
  }
  await expect(new CommandReceiptStore(h.home).prune(), "prune before any receipt exists").resolves.toBeUndefined();
  expect(await h.receipts()).toEqual({});

  let during: { status: string; run: () => Promise<void> } | undefined;
  const writer = async (path: string, value: unknown, mode?: number) => {
    await durableAtomicWriteJson(path, value, mode);
    const hook = during;
    if (hook && (value as { status?: unknown }).status === hook.status) { during = undefined; await hook.run(); }
  };

  let store = new CommandReceiptStore(h.home, writer, { maximumAggregateBytes: 2 * RECEIPT_BYTES + 100, maximumAgeMs: 60_000 });
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "window-0001", h.run({ first: true })))).toEqual({ result: { first: true }, ran: 1 });
  h.advance(2 * 60_000);
  let inside: unknown;
  during = { status: "pending", run: async () => { inside = await outcome(() => h.counted(() => store.execute(PHONE, "session.rename", "window-0003", h.run({ inside: true })))); } };
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "window-0002", h.run({ outer: true }))), "the outer command").toEqual({ result: { outer: true }, ran: 2 });
  expect(inside, "a rebuild inside another command's pending write admits the next command").toEqual({ result: { result: { inside: true }, ran: 1 } });
  expect(await h.receipts(), "the expired receipt is pruned").toEqual({
    "window-0002": rename("2026-01-01T00:02:00.000Z", { outer: true }), "window-0003": rename("2026-01-01T00:02:00.000Z", { inside: true }) });
  await store.dispose();

  await rm(h.directory, { recursive: true, force: true });
  store = new CommandReceiptStore(h.home, writer, { maximumEntries: 2, maximumAggregateBytes: 2 * RECEIPT_BYTES + 600, maximumAgeMs: 60_000 });
  const large = { text: "x".repeat(600) };
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "window-0101", h.run(large)))).toEqual({ result: large, ran: 1 });
  h.advance(2 * 60_000);
  during = { status: "completed", run: async () => { inside = await outcome(() => h.counted(() => store.execute(PHONE, "session.rename", "window-0103", h.run({ inside: true })))); } };
  const larger = { text: "y".repeat(1_000) };
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "window-0102", h.run(larger))), "the outer command").toEqual({ result: larger, ran: 2 });
  expect(inside, "a rebuild inside another command's completed write admits the next command").toEqual({ result: { result: { inside: true }, ran: 1 } });
  expect(await outcome(() => store.execute(PHONE, "session.rename", "window-0104", h.run({}))), "both receipts are counted, so a third command waits").toEqual(CAPACITY_FULL);
  expect(await h.receipts()).toEqual({
    "window-0102": rename("2026-01-01T00:04:00.000Z", larger), "window-0103": rename("2026-01-01T00:04:00.000Z", { inside: true }) });
  await store.dispose();

  await rm(h.directory, { recursive: true, force: true });
  let open!: () => void;
  const gate = new Promise<void>((resolve) => { open = resolve; });
  store = new CommandReceiptStore(h.home, async (path, value, mode) => {
    if ((value as { status?: unknown }).status === "completed") await gate;
    await durableAtomicWriteJson(path, value, mode);
  });
  const prompt = await h.counted(async () => {
    const first = await store.execute(PHONE, "session.prompt", "prompt-0101", h.run({ accepted: 1 }), { respondBeforeCompletion: true });
    const duplicate = outcome(() => store.execute(PHONE, "session.prompt", "prompt-0101", h.run({ accepted: 2 }), { respondBeforeCompletion: true }));
    open();
    return { first, duplicate: await duplicate };
  });
  expect(prompt, "a duplicate prompt sent before the first one's completion is durable replays it")
    .toEqual({ result: { first: { accepted: 1 }, duplicate: { result: { accepted: 1 } } }, ran: 1 });
  const prompted = { "prompt-0101": { method: "session.prompt", status: "completed", createdAt: "2026-01-01T00:04:00.000Z", result: { accepted: 1 } } };
  expect(await h.receipts()).toEqual(prompted);

  const identityHash = createHash("sha256").update(PHONE).digest("base64url");
  const forge = async (commandId: string, receipt: Record<string, unknown>) => {
    const key = createHash("sha256").update(identityHash).update("\0").update("session.rename").update("\0").update(commandId).digest("base64url");
    await writeFile(join(h.directory, `${key}.json`), JSON.stringify({ version: 1, identityHash, commandId,
      method: "session.rename", createdAt: "2026-01-01T00:00:00.000Z", ...receipt }));
  };
  await forge("mismatch-0001", { commandId: "mismatch-0002", status: "pending" });
  expect(await outcome(() => h.counted(() => store.execute(PHONE, "session.rename", "mismatch-0001", h.run({})))), "another command id").toEqual(IDENTITY_MISMATCH);
  for (const [commandId, forged] of [["mismatch-0003", { method: "session.archive" }], ["mismatch-0004", { identityHash: "B".repeat(43) }]] as const) {
    await forge(commandId, { status: "completed", result: { replayed: true }, ...forged });
    expect(await outcome(() => store.status(PHONE, "session.rename", commandId)), `status of a receipt naming another ${Object.keys(forged)[0]}`).toEqual(IDENTITY_MISMATCH);
    expect(await outcome(() => h.counted(() => store.execute(PHONE, "session.rename", commandId, h.run({})))), `execute over a receipt naming another ${Object.keys(forged)[0]}`).toEqual(IDENTITY_MISMATCH);
  }
  expect(await h.receipts(), "forged receipts are left untouched").toEqual({ ...prompted,
    "mismatch-0002": { method: "session.rename", status: "pending", createdAt: "2026-01-01T00:00:00.000Z" },
    "mismatch-0003": { method: "session.archive", status: "completed", createdAt: "2026-01-01T00:00:00.000Z", result: { replayed: true } },
    "mismatch-0004": rename("2026-01-01T00:00:00.000Z", { replayed: true }) });
  await store.dispose();
});

it("command-receipt-races: lane lifetime, prune and rebuild inside a duplicate's lane", async () => {
  const h = await receiptHome();

  let store = new CommandReceiptStore(h.home);
  let third: Promise<unknown> | undefined;
  let thirdSettledDuringOperation: boolean | undefined;
  const first = outcome(() => store.execute(PHONE, "session.rename", "race-0001", h.fail(new GatewayError("not_found", "no such session"))));
  const second = h.counted(() => store.execute(PHONE, "session.rename", "race-0001", async () => {
    await h.run(undefined)();
    third = outcome(() => h.counted(() => store.execute(PHONE, "session.rename", "race-0001", h.run({ third: true }))));
    thirdSettledDuringOperation = await Promise.race([third.then(() => true),
      new Promise<boolean>((resolve) => { setTimeout(() => resolve(false), 300); })]);
    return { second: true };
  }));
  expect(await first).toEqual({ refused: "no such session", code: "not_found", retryable: false, details: null });
  expect(await second, "the duplicate runs once the definitive failure frees the lane").toEqual({ result: { second: true }, ran: 2 });
  expect(thirdSettledDuringOperation, "a copy sent while the lane's second holder runs waits for it").toBe(false);
  expect(await third, "and replays it").toEqual({ result: { result: { second: true }, ran: 0 } });
  expect(await h.receipts()).toEqual({ "race-0001": rename("2026-01-01T00:00:00.000Z", { second: true }) });
  await store.dispose();

  await rm(h.directory, { recursive: true, force: true });
  store = new CommandReceiptStore(h.home);
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "race-0101", h.run({ first: true })))).toEqual({ result: { first: true }, ran: 1 });
  h.advance(1_000);
  const prune = store.prune(0);
  const duplicate = h.counted(() => store.execute(PHONE, "session.rename", "race-0101", h.run({ again: true })));
  await prune;
  expect(await duplicate, "a prune holding the inventory when a duplicate arrives expires its receipt").toEqual({ result: { again: true }, ran: 1 });
  expect(await h.receipts()).toEqual({ "race-0101": rename("2026-01-01T00:00:01.000Z", { again: true }) });
  await store.dispose();

  await rm(h.directory, { recursive: true, force: true });
  store = new CommandReceiptStore(h.home);
  expect(await h.counted(() => store.execute(PHONE, "session.rename", "race-0201", h.run({ kept: true })))).toEqual({ result: { kept: true }, ran: 1 });
  await store.dispose();
  store = new CommandReceiptStore(h.home, undefined, { maximumEntries: 1 });
  let replay: Promise<unknown> | undefined;
  expect(await outcome(() => store.execute(PHONE, "session.rename", "race-0202", h.run({ admitted: true }), {
    resolveBinding: () => {
      replay = (async () => {
        for (let hop = 0; hop < 20; hop += 1) await Promise.resolve();
        return h.counted(() => store.execute(PHONE, "session.rename", "race-0201", h.run({ replayed: false })));
      })();
      return { homeId: "home-1", bindingRevision: 1, physicalSessionId: "chapter-1" };
    },
  })), "a rebuild while a replaying duplicate holds its lane counts its receipt, so the store is full").toEqual(CAPACITY_FULL);
  expect(await replay, "the duplicate replays the kept receipt").toEqual({ result: { kept: true }, ran: 0 });
  expect(await h.receipts()).toEqual({ "race-0201": rename("2026-01-01T00:00:01.000Z", { kept: true }) });
  await store.dispose();
});
