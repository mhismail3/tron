import { afterEach, describe, expect, it, vi } from "vitest";
import { chmod, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { DEFAULT_KNOWLEDGE_CONFIG, type KnowledgeRecordDraft } from "./knowledge-contract.js";
import { KnowledgeStore } from "./knowledge-store.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(workspaces.splice(0).map(workspace => workspace.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture(): Promise<{ store: KnowledgeStore; home: string; workspace: TronWorkspace }> {
  const root = await mkdtemp(join(tmpdir(), "tron-knowledge-"));
  roots.push(root);
  const home = join(root, "home");
  const workspace = new TronWorkspace(home);
  workspaces.push(workspace);
  return { store: new KnowledgeStore(workspace), home, workspace };
}

const source = (title: string): KnowledgeRecordDraft & { kind: "source" } => ({
  kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
  content: { title, text: `${title} retained evidence`, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" },
});
const observation = (sessionId: string, fromEntryId: string): KnowledgeRecordDraft & { kind: "observation" } => ({
  kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId, evidence: [] }, relations: [],
  content: { range: { sessionId, fromEntryId, toEntryId: fromEntryId, entryIds: [fromEntryId], entryDigest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, items: [{ text: "The user corrected the plan", attribution: "user", observedAt: "2026-01-01T00:00:00Z", certainty: "certain" }] },
});

function command(suffix: string): string { return `knowledge-test-${suffix}`; }

describe("KnowledgeStore", () => {
  it("is lazy, durable across reopen, and returns lexical canonical results", async () => {
    const { store, home, workspace } = await fixture();
    expect((await store.status()).state).toBe("uninitialized");
    const result = await store.captureSource({ commandId: command("capture"), record: source("Durable source") });
    expect((await store.status()).state).toBe("ready");
    expect((await store.search({ query: "durable" })).hits[0]?.record.revisionId).toBe(result.record.revisionId);
    expect((await store.captureSource({ commandId: command("capture"), record: source("Durable source") })).record.revisionId).toBe(result.record.revisionId);

    await workspace.dispose();
    const reopenedWorkspace = new TronWorkspace(home);
    workspaces.push(reopenedWorkspace);
    const reopened = new KnowledgeStore(reopenedWorkspace);
    expect((await reopened.read(result.record.id))?.revisionId).toBe(result.record.revisionId);
    expect((await reopened.list()).records).toHaveLength(1);
  });

  it("survives a rejected first mutation and permits the next valid mutation", async () => {
    const { store } = await fixture();
    await expect(store.captureSource({ commandId: command("invalid-first"), record: { ...source("invalid"), content: { ...source("invalid").content, object: { hash: "a".repeat(64), mediaType: "text/plain", bytes: 1 } } } })).rejects.toThrow(/durably captured/);
    await expect(store.captureSource({ commandId: command("valid-after-invalid"), record: source("valid after invalid") })).resolves.toBeDefined();
  });

  it("publishes forget tombstones before cleanup if state save fails", async () => {
    const { store, home, workspace } = await fixture();
    const created = await store.captureSource({ commandId: command("forget-save-failure-source"), record: source("must remain until commit") });
    vi.spyOn(store as unknown as { save: () => Promise<void> }, "save").mockRejectedValueOnce(new Error("injected save failure"));
    await expect(store.forget(command("forget-save-failure"), created.record.id, "privacy request", created.record.revisionId)).rejects.toThrow("injected save failure");
    await workspace.dispose();
    const reopenedWorkspace = new TronWorkspace(home); workspaces.push(reopenedWorkspace);
    const reopened = new KnowledgeStore(reopenedWorkspace);
    expect((await reopened.read(created.record.id, created.record.revisionId, true))?.content).toMatchObject({ title: "must remain until commit" });
  });

  it("never reads an orphan revision after a failed update publication", async () => {
    const { store, home } = await fixture();
    const created = await store.createNote({ commandId: command("orphan-note-create"), record: { kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "old", role: "fact", confirmed: true } } });
    const save = vi.spyOn(store as unknown as { save: () => Promise<void> }, "save").mockRejectedValueOnce(new Error("injected save failure"));
    await expect(store.updateNote({ commandId: command("orphan-note-update"), recordId: created.record.id, expectedRevision: created.record.revisionId, record: { kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "orphan", role: "fact", confirmed: true } } })).rejects.toThrow("injected save failure");
    save.mockRestore();
    const revisions = await readdir(join(home, "workspace/state/knowledge/records", created.record.id));
    const orphan = revisions.find(name => !name.startsWith(created.record.revisionId));
    expect(orphan).toBeDefined();
    await expect(store.read(created.record.id, orphan!.replace(/\.json$/, ""), true)).rejects.toThrow(/committed/);
  });

  it("rejects stale writers and keeps immutable record revisions", async () => {
    const { store } = await fixture();
    const created = await store.createNote({ commandId: command("note-create"), record: {
      kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Preference", body: "old", role: "preference", confirmed: true },
    }});
    const updated = await store.updateNote({ commandId: command("note-update"), recordId: created.record.id, expectedRevision: created.record.revisionId, record: {
      kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Preference", body: "new", role: "preference", confirmed: true },
    }});
    await expect(store.updateNote({ commandId: command("note-stale"), recordId: created.record.id, expectedRevision: created.record.revisionId, record: {
      kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Preference", body: "bad", role: "preference", confirmed: true },
    }})).rejects.toThrow("stale");
    expect((await store.read(created.record.id, created.record.revisionId))?.content).toMatchObject({ body: "old" });
    expect((await store.read(created.record.id))?.revisionId).toBe(updated.record.revisionId);
  });

  it("publishes observation coverage with its group and recovers failed coverage", async () => {
    const { store } = await fixture();
    const config = await store.config().catch(() => ({ ...DEFAULT_KNOWLEDGE_CONFIG }));
    const configured = await store.configure(command("coverage-config"), { ...config, eligibility: { ...config.eligibility, sessionIds: ["session-1"] } });
    const failed = await store.setCoverage({ commandId: command("coverage-failed"), expectedConfigRevision: configured.revision, coverage: {
      id: "coverage-1", range: { sessionId: "session-1", fromEntryId: "entry-1", toEntryId: "entry-1", entryIds: ["entry-1"], entryDigest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, disposition: "failed", groupRevisionIds: [],
    }});
    expect((await store.coverage("coverage-1"))?.disposition).toBe("failed");
    const published = await store.publishObservationGroup({ commandId: command("coverage-recover"), expectedConfigRevision: configured.revision, expectedCoverageRevision: failed.coverage.revisionId, coverage: {
      id: "coverage-1", range: failed.coverage.range, disposition: "observed",
    }, records: [observation("session-1", "entry-1")] });
    expect(published.coverage.groupRevisionIds).toEqual([published.records[0]!.revisionId]);
    expect((await store.coverage("coverage-1"))?.disposition).toBe("observed");
    expect((await store.recall({ sessionId: "session-1", entryId: "entry-1" })).records).toHaveLength(1);
  });

  it("durably suppresses and forgets, then cleans referenced objects", async () => {
    const { store } = await fixture();
    const object = await store.putObject(new TextEncoder().encode("private evidence"), "text/plain");
    const created = await store.captureSource({ commandId: command("object-source"), record: { ...source("Object source"), content: { ...source("Object source").content, text: undefined, object } } });
    await store.setExclusion(command("exclude"), created.record.id, true, created.record.revisionId, "not for recall");
    expect((await store.list()).records).toHaveLength(0);
    expect((await store.list({ includeSuppressed: true })).records).toHaveLength(1);
    await store.forget(command("forget"), created.record.id, "user requested deletion", created.record.revisionId);
    expect(await store.read(created.record.id)).toBeNull();
    await expect(store.captureSource({ commandId: command("resurrection"), record: { ...source("resurrection"), id: created.record.id } })).rejects.toThrow("forgotten");
    expect((await store.status()).pendingCleanupCount).toBe(1);
    expect((await store.reconcile()).removedObjects).toEqual([object.hash]);
    expect((await store.status()).pendingCleanupCount).toBe(0);
  });

  it("preserves unsafe and newer state instead of resetting it", async () => {
    const { store, home } = await fixture();
    await store.captureSource({ commandId: command("unsafe-seed"), record: source("Seed") });
    const statePath = join(home, "workspace/state/knowledge/state.json");
    await writeFile(statePath, "{\"schemaVersion\":2}");
    await chmod(statePath, 0o600);
    expect((await store.status()).state).toBe("newer");
    await expect(store.createNote({ commandId: command("blocked"), record: {
      kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "blocked", role: "fact", confirmed: false },
    }})).rejects.toThrow();
    expect(JSON.parse(await readFile(statePath, "utf8"))).toEqual({ schemaVersion: 2 });
  });

  it("searches beyond the presentation page before applying its result limit", async () => {
    const { store } = await fixture();
    for (let index = 0; index < 55; index += 1) await store.captureSource({ commandId: command(`page-${index}`), record: source(index === 54 ? "needle beyond page" : `ordinary source ${index}`) });
    const result = await store.search({ query: "needle", limit: 1 });
    expect(result.hits).toHaveLength(1);
    expect(result.hits[0]?.record.content).toMatchObject({ title: "needle beyond page" });
  });

  it("invalidates forgotten mutation receipts and leaves no forgotten body bytes", async () => {
    const { store, home } = await fixture();
    const created = await store.captureSource({ commandId: command("forget-receipt"), record: { ...source("private receipt body"), id: "forgotten-record" } });
    await store.forget(command("forget-receipt-action"), created.record.id, "privacy request", created.record.revisionId);
    const state = await readFile(join(home, "workspace/state/knowledge/state.json"), "utf8");
    expect(state).not.toContain("private receipt body");
    await expect(store.captureSource({ commandId: command("forget-receipt"), record: { ...source("private receipt body"), id: "forgotten-record" } })).rejects.toThrow("forgotten");
  });

  it("invalidates dependent creation receipts and reports established namespace loss", async () => {
    const { store, home, workspace } = await fixture();
    const captured = await store.captureSource({ commandId: command("dependent-source"), record: source("synthetic withheld fact") });
    const note = { commandId: command("dependent-note"), record: { kind: "note" as const, scope: "personal" as const, provenance: { actor: "agent" as const, evidence: [{ recordId: captured.record.id, revisionId: captured.record.revisionId }] }, relations: [], content: { title: "Derived", body: "synthetic withheld fact", role: "fact" as const, confirmed: false } } };
    await store.createNote(note);
    await store.forget(command("dependent-forget"), captured.record.id, "synthetic erasure", captured.record.revisionId);
    await expect(store.createNote(note)).rejects.toThrow(/forgotten|suppressed|excluded/i);
    await workspace.dispose();
    await rm(join(home, "workspace/state/knowledge"), { recursive: true, force: true });
    const reopened = new KnowledgeStore(new TronWorkspace(home));
    expect((await reopened.status()).state).toBe("invalid");
    await reopened.workspace.dispose();
  });

  it("verifies object bytes on reuse, reads, and record reference", async () => {
    const { store, home } = await fixture();
    const object = await store.putObject(new TextEncoder().encode("original bytes"), "text/plain");
    const objectPath = join(home, "workspace/state/knowledge/objects", object.hash);
    await writeFile(objectPath, "tampered bytes", { mode: 0o600 });
    await expect(store.readObject(object)).rejects.toThrow(/hash|identity/i);
    await expect(store.putObject(new TextEncoder().encode("original bytes"), "text/html")).rejects.toThrow(/hash|identity/i);
    await expect(store.captureSource({ commandId: command("corrupt-reference"), record: { ...source("corrupt"), content: { ...source("corrupt").content, object, text: undefined } } })).rejects.toThrow(/durably captured|bytes/i);
  });

  it("rejects missing established state and fences late scope publication", async () => {
    const { store, home } = await fixture();
    await store.captureSource({ commandId: command("state-seed"), record: source("state seed") });
    await rm(join(home, "workspace/state/knowledge/state.json"));
    expect((await store.status()).state).toBe("invalid");

    const fresh = await fixture();
    await fresh.store.setScopeExclusion(command("scope-exclude"), { sessionId: "excluded-session" }, true, "user excluded session");
    const range = { sessionId: "excluded-session", fromEntryId: "entry-1", toEntryId: "entry-1", entryIds: ["entry-1"], entryDigest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    await expect(fresh.store.publishObservationGroup({ commandId: command("late-publication"), expectedConfigRevision: 0, coverage: { id: "late", range, disposition: "observed" }, records: [observation("excluded-session", "entry-1")] })).rejects.toThrow("excluded");
    await fresh.workspace.dispose();
  });

  it("reflects exact successive source revisions into one session-local derivative", async () => {
    const { store } = await fixture();
    const config = await store.config().catch(() => ({ ...DEFAULT_KNOWLEDGE_CONFIG }));
    const configured = await store.configure(command("reflect-config"), { ...config, eligibility: { ...config.eligibility, sessionIds: ["reflect-session"] } });
    const first = await store.publishObservationGroup({ commandId: command("reflect-source-1"), expectedConfigRevision: configured.revision, coverage: { id: "reflect-coverage-1", range: observation("reflect-session", "entry-1").content.range, disposition: "observed" }, records: [observation("reflect-session", "entry-1")] });
    const secondDraft = observation("reflect-session", "entry-2");
    secondDraft.content.range.entryDigest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const second = await store.publishObservationGroup({ commandId: command("reflect-source-2"), expectedConfigRevision: configured.revision, coverage: { id: "reflect-coverage-2", range: secondDraft.content.range, disposition: "observed" }, records: [secondDraft] });
    const reflected = await store.reflect(command("reflect-command-1"), "reflect-session", [first.records[0]!.revisionId], "bounded handoff");
    const replaced = await store.reflect(command("reflect-command-2"), "reflect-session", [first.records[0]!.revisionId, second.records[0]!.revisionId], "new bounded handoff");
    expect(replaced.record.id).toBe(reflected.record.id);
    expect(replaced.record.revisionId).not.toBe(reflected.record.revisionId);
    expect(replaced.record.provenance.evidence).toEqual([
      { recordId: first.records[0]!.id, revisionId: first.records[0]!.revisionId },
      { recordId: second.records[0]!.id, revisionId: second.records[0]!.revisionId },
    ]);
    await store.setExclusion(command("reflect-exclude"), first.records[0]!.id, true, first.records[0]!.revisionId, "excluded evidence");
    await expect(store.reflect(command("reflect-command-3"), "reflect-session", [first.records[0]!.revisionId], "must fail")).rejects.toThrow("excluded");
  });

  it("does not replace terminal coverage with a fake disposition", async () => {
    const { store } = await fixture();
    const config = await store.config().catch(() => ({ ...DEFAULT_KNOWLEDGE_CONFIG }));
    const configured = await store.configure(command("terminal-config"), { ...config, eligibility: { ...config.eligibility, sessionIds: ["session-1"] } });
    const published = await store.publishObservationGroup({ commandId: command("terminal-publish"), expectedConfigRevision: configured.revision, coverage: { id: "terminal", range: observation("session-1", "terminal-entry").content.range, disposition: "observed" }, records: [observation("session-1", "terminal-entry")] });
    await expect(store.setCoverage({ commandId: command("terminal-fake"), expectedConfigRevision: configured.revision, expectedRevision: published.coverage.revisionId, coverage: { id: "terminal", range: published.coverage.range, disposition: "empty", groupRevisionIds: [] } })).rejects.toThrow("Terminal");
  });

  it("keeps observation disabled until an explicit model is configured", async () => {
    const { store } = await fixture();
    expect((await store.status()).config).toEqual(DEFAULT_KNOWLEDGE_CONFIG);
    await store.configure(command("config"), { ...DEFAULT_KNOWLEDGE_CONFIG, observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true } });
    expect((await store.status()).observationConfigured).toBe(false);
  });
});
