import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { recoverProviderSaveTime } from "./source-capture.js";

/** Failure modes this reconciliation must catch, written before the code:
 *
 * S1  A source with no provider identity is given a save time anyway.
 * S2  A non-Raindrop provider's payload is read with Raindrop's field names.
 * S3  An existing save time is overwritten by a later recovery.
 * S4  No retained provider evidence is treated as a recoverable save time.
 * S5  Evidence for a different Raindrop item is used for this source.
 * S6  A payload without `created` invents one from `lastUpdate` or capture time.
 * S7  A nonsense `created` (placeholder epoch, malformed, future) is stored.
 * S8  An unreadable or oversized retained object still produces a save time.
 * S9  A stale expected revision is written through.
 * S10 A replayed command applies a second revision.
 * S11 A misfiled publication time is written or relocated.
 * S12 An excluded source is reconciled.
 * S13 The recovered instant is not exactly the provider's value.
 */
const homes: string[] = [];
afterEach(async () => { await Promise.all(homes.splice(0).map(home => rm(home, { recursive: true, force: true }))); });
async function fixture(): Promise<{ store: KnowledgeStore; home: string }> {
  const home = await mkdtemp(join(tmpdir(), "tron-save-time-")); homes.push(home);
  return { home, store: new KnowledgeStore(new TronWorkspace(home)) };
}
/** The content-addressed object directory under a fixture's workspace. */
const objectsDir = (home: string) => join(home, "workspace", "state", "knowledge", "objects");
const ITEM_ID = "846675565";
const CREATED = "2024-09-03T06:22:40.426Z";
const raindropItem = (overrides: Record<string, unknown> = {}) => ({ _id: Number(ITEM_ID), title: "Saved item", link: "https://example.com/post", created: CREATED, lastUpdate: "2026-04-13T18:00:34.580Z", collection: { $id: 111 }, ...overrides });

interface FixtureOptions {
  payload?: unknown;
  itemId?: string;
  provider?: string;
  savedAt?: string;
  publishedAt?: string;
  representation?: boolean;
  excluded?: boolean;
}
async function capture(store: KnowledgeStore, options: FixtureOptions = {}) {
  const itemId = options.itemId ?? ITEM_ID;
  const representation = options.representation === false ? undefined : await store.putObject(new TextEncoder().encode(JSON.stringify(options.payload ?? raindropItem())), "application/json");
  const created = await store.captureSource({ commandId: `save-time-fixture-${randomUUID()}`, record: {
    kind: "source", scope: "research", provenance: { actor: "connector", source: `raindrop:42:${itemId}`, evidence: [] }, relations: [],
    content: { title: "Saved item", uri: "https://example.com/post", text: "body", captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z", origin: "connector",
      identity: { provider: options.provider ?? "raindrop", accountId: "42", itemId },
      ...(options.savedAt === undefined ? {} : { sourceSavedAt: options.savedAt }),
      ...(options.publishedAt === undefined ? {} : { sourcePublishedAt: options.publishedAt }),
      ...(representation === undefined ? {} : { representations: [{ kind: "provider-api" as const, object: representation, mediaType: "application/json" }] }) },
  } });
  if (options.excluded) await store.setExclusion(`save-time-exclude-${randomUUID()}`, created.record.id, true, created.record.revisionId, "fixture exclusion");
  return created.record;
}
const recover = (store: KnowledgeStore, sourceId: string, expectedRevision?: string, commandId = `save-time-${randomUUID()}`) =>
  recoverProviderSaveTime(store, { commandId, sourceId, ...(expectedRevision === undefined ? {} : { expectedRevision }) });
const read = (store: KnowledgeStore, id: string) => store.read(id, undefined, false, true, true);

describe("provider save-time recovery", () => {
  it("recovers Raindrop's created time from retained provider evidence and leaves publication time alone (S13, S11)", async () => {
    const { store } = await fixture();
    const source = await capture(store, { publishedAt: CREATED });
    const result = await recover(store, source.id);
    expect(result.status).toBe("recovered");
    expect(result.saveTime).toBe(CREATED);
    const updated = await read(store, source.id);
    expect(updated?.content.sourceSavedAt).toBe(CREATED);
    // The legacy misfiling is never repeated or relocated.
    expect(updated?.content.sourcePublishedAt).toBe(CREATED);
    expect(updated?.content.captureReason).toContain("retained Raindrop item payload");
    // The provider payload that produced the value is still retained on the
    // record, and the reason names it.
    expect(updated?.content.representations?.[0]?.object.hash).toBe(source.content.representations![0]!.object.hash);
    expect(updated?.provenance).toEqual(source.provenance);
    expect(updated?.content.text).toBe("body");
    expect(updated?.relations).toEqual(source.relations);
  });

  it("keeps an existing save time untouched (S3, S10)", async () => {
    const { store } = await fixture();
    const source = await capture(store, { savedAt: "2025-05-05T00:00:00.000Z" });
    const first = await recover(store, source.id, source.revisionId, "save-time-replay");
    expect(first.status).toBe("present");
    expect((await read(store, source.id))?.content.sourceSavedAt).toBe("2025-05-05T00:00:00.000Z");
    const replay = await recover(store, source.id, undefined, "save-time-replay");
    expect(replay.status).toBe("present");
    expect((await store.list({ kind: "source", includeArchived: true, includePending: true })).records).toHaveLength(1);
  });

  it("applies a replay of a completed recovery as one revision (S10)", async () => {
    const { store } = await fixture();
    const source = await capture(store);
    const first = await recover(store, source.id, source.revisionId, "save-time-single-revision");
    expect(first.status).toBe("recovered");
    // A replayed command may answer from the committed receipt or from the
    // recorded value; either way it applies no second revision and reports the
    // same instant.
    const second = await recover(store, source.id, undefined, "save-time-single-revision");
    expect(["recovered", "present"]).toContain(second.status);
    expect(second.saveTime ?? (await read(store, source.id))?.content.sourceSavedAt).toBe(CREATED);
    expect((await read(store, source.id))?.revisionId).toBe(first.revisionId);
  });

  it("refuses providers and records without a retained payload (S1, S2, S4)", async () => {
    const { store } = await fixture();
    const manual = await capture(store, { provider: "manual", representation: false });
    expect((await recover(store, manual.id)).status).toBe("unsupported");
    const x = await capture(store, { provider: "x", payload: { id: "1234", text: "post", created_at: "2026-01-01T00:00:00.000Z" } });
    expect((await recover(store, x.id)).status).toBe("unsupported");
    const noEvidence = await capture(store, { representation: false });
    const result = await recover(store, noEvidence.id);
    expect(result.status).toBe("absent");
    expect(await read(store, noEvidence.id)).toMatchObject({ revisionId: noEvidence.revisionId });
  });

  it("refuses evidence belonging to another item (S5)", async () => {
    const { store } = await fixture();
    const source = await capture(store, { payload: raindropItem({ _id: 999999999 }) });
    expect((await recover(store, source.id)).status).toBe("absent");
    expect((await read(store, source.id))?.content.sourceSavedAt).toBeUndefined();
  });

  it("never substitutes lastUpdate or capture time, and rejects nonsense instants (S6, S7)", async () => {
    const { store } = await fixture();
    const noCreated = await capture(store, { payload: raindropItem({ created: undefined }) });
    expect((await recover(store, noCreated.id)).status).toBe("absent");
    expect((await read(store, noCreated.id))?.content.sourceSavedAt).toBeUndefined();
    for (const created of ["1970-01-01T00:00:00.000Z", "not-a-date", "2999-01-01T00:00:00.000Z", 42]) {
      const source = await capture(store, { payload: raindropItem({ created }) });
      const result = await recover(store, source.id);
      expect(result.status, `created=${String(created)}`).toBe("absent");
      expect((await read(store, source.id))?.content.sourceSavedAt).toBeUndefined();
    }
  });

  it("resolves the current item identity when several representations are retained", async () => {
    const { store } = await fixture();
    const source = await capture(store);
    const foreign = await store.putObject(new TextEncoder().encode(JSON.stringify(raindropItem({ _id: 111111111 }))), "application/json");
    const current = await read(store, source.id);
    await store.captureSource({ commandId: `save-time-foreign-${randomUUID()}`, expectedRevision: current!.revisionId, record: { ...current!, content: { ...current!.content, representations: [{ kind: "provider-api", object: foreign, mediaType: "application/json" }, ...current!.content.representations!] } } });
    const result = await recover(store, source.id);
    expect(result.status).toBe("recovered");
    expect(result.saveTime).toBe(CREATED);
  });

  it("treats an unreadable or oversized retained object as absent (S8)", async () => {
    const { store, home } = await fixture();
    const unreadable = await capture(store, { payload: raindropItem() });
    const hash = unreadable.content.representations![0]!.object.hash;
    // A retained hash whose bytes are gone must not produce a save time. The
    // object store is content addressed, so removing it is exactly that state.
    await rm(join(objectsDir(home), hash));
    expect((await recover(store, unreadable.id)).status).toBe("absent");
    const oversized = await capture(store, { payload: { ...raindropItem(), padding: "x".repeat(300_000) } });
    const outcome = await recover(store, oversized.id);
    expect(outcome.status).toBe("absent");
    expect(outcome.reason).toContain("bound");
  });

  it("fences a stale expected revision and an excluded source (S9, S12)", async () => {
    const { store } = await fixture();
    const source = await capture(store);
    const staleRevision = source.revisionId;
    const touched = await store.captureSource({ commandId: `save-time-touch-${randomUUID()}`, expectedRevision: staleRevision, record: { kind: "source", id: source.id, createdAt: source.createdAt, scope: source.scope, provenance: source.provenance, relations: source.relations, content: { ...source.content, text: "body after a later capture" } } });
    expect(touched.record.revisionId).not.toBe(staleRevision);
    const stale = await recover(store, source.id, staleRevision);
    expect(stale.status).toBe("conflict");
    expect(stale.currentRevision).toBeDefined();
    expect((await read(store, source.id))?.content.sourceSavedAt).toBeUndefined();
    const excluded = await capture(store, { excluded: true });
    expect((await recover(store, excluded.id)).status).toBe("absent");
  });

  it("uses caller-supplied bytes only for a pending source, bound to the listed hash (S4)", async () => {
    const { store } = await fixture();
    const payload = new TextEncoder().encode(JSON.stringify(raindropItem()));
    const object = await store.putObject(payload, "application/json");
    const pending = await store.captureSource({ commandId: `save-time-pending-${randomUUID()}`, record: {
      kind: "source", scope: "research", provenance: { actor: "connector", source: `raindrop:42:${ITEM_ID}`, evidence: [] }, relations: [],
      content: { title: "Saved item", uri: "https://example.com/post", text: "body", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "connector", identity: { provider: "raindrop", accountId: "42", itemId: ITEM_ID }, admission: { status: "pending", reason: "fixture", decidedAt: "2026-01-01T00:00:00Z" }, representations: [{ kind: "provider-api", object, mediaType: "application/json" }] },
    } });
    // A pending source is fenced from reading its own objects.
    expect((await recover(store, pending.record.id)).status).toBe("absent");
    // Bytes the caller has just retained on this exact revision are accepted…
    const recovered = await recoverProviderSaveTime(store, { commandId: `save-time-pending-evidence-${randomUUID()}`, sourceId: pending.record.id, expectedRevision: pending.record.revisionId, evidence: { objectHash: object.hash, bytes: payload } });
    expect(recovered.status).toBe("recovered");
    expect(recovered.saveTime).toBe(CREATED);
    // …but only for the hash and length this revision lists. Evidence for
    // another hash is ignored, and the record is read normally instead.
    const mismatchSource = await capture(store, { payload: raindropItem() });
    const mismatch = await recoverProviderSaveTime(store, { commandId: `save-time-mismatch-${randomUUID()}`, sourceId: mismatchSource.id, expectedRevision: mismatchSource.revisionId, evidence: { objectHash: "b".repeat(64), bytes: payload } });
    expect(mismatch.status).toBe("recovered");
    expect(mismatch.saveTime).toBe(CREATED);
    // Bytes of the wrong length for the listed hash are refused as well.
    const rewrittenSource = await capture(store, { payload: raindropItem() });
    const foreignBytes = new TextEncoder().encode(JSON.stringify(raindropItem({ created: "2005-01-01T00:00:00.000Z" })));
    const rewritten = await recoverProviderSaveTime(store, { commandId: `save-time-rewritten-${randomUUID()}`, sourceId: rewrittenSource.id, expectedRevision: rewrittenSource.revisionId, evidence: { objectHash: rewrittenSource.content.representations![0]!.object.hash, bytes: foreignBytes } });
    expect(rewritten.status).toBe("recovered");
    expect(rewritten.saveTime).toBe(CREATED);
  });

  it("reports an unknown source as absent without a write", async () => {
    const { store } = await fixture();
    const result = await recover(store, "00000000-0000-4000-8000-000000000000");
    expect(result.status).toBe("absent");
  });
});
