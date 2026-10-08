import { mkdir, mkdtemp, readdir, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeOwner, type HomeRecord, type HomeSessionPort } from "./home-owner.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(workspaces.splice(0).map((workspace) => workspace.dispose()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

interface Harness {
  root: string;
  owner: HomeOwner;
  recordPath: string;
  directory: string;
  workspacePath: string;
  created: string[];
  replaced: string[];
  present: Set<string>;
  live: Set<string>;
  holdProfileCommit(): { entered: Promise<void>; release(): void };
}

/** A port that records the calls the owner makes, so the assertions stay about
 * the owner's own decisions (record bytes, generations, session identity) and
 * never about a mocked mechanism. */
async function harness(options: { symlinkHome?: boolean } = {}): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "tron-home-owner-"));
  roots.push(root);
  const agentDir = join(root, "agent");
  const tronHome = join(root, options.symlinkHome ? "tron-link" : "tron");
  const actualTronHome = options.symlinkHome ? join(root, "tron-real") : tronHome;
  await mkdir(agentDir);
  if (options.symlinkHome) {
    await mkdir(actualTronHome);
    await symlink(actualTronHome, tronHome);
  }
  const created: string[] = [];
  const replaced: string[] = [];
  const present = new Set<string>();
  const live = new Set<string>();
  let sequence = 0;
  let replaceGate: Promise<void> | undefined;
  let replaceEntered!: () => void;
  const sessions: HomeSessionPort = {
    createHomeSession: async () => {
      const sessionId = `session-${++sequence}`;
      created.push(sessionId);
      present.add(sessionId);
      live.add(sessionId);
      return sessionId;
    },
    applySessionModel: async () => {},
    sessionFile: async (sessionId) => (present.has(sessionId) ? join(root, "sessions", `${sessionId}.jsonl`) : undefined),
    sessionPresent: async (sessionId) => present.has(sessionId),
    hasLiveRuntime: (sessionId) => live.has(sessionId),
    serializeSessionMutation: async (_id, commit) => commit(),
    replaceRuntimeForProfile: async (sessionId, commit) => {
      replaced.push(sessionId);
      if (replaceGate) {
        replaceEntered();
        await replaceGate;
      }
      await commit();
    },
  };
  const workspace = new TronWorkspace(join(root, "tron-workspace"));
  workspaces.push(workspace);
  const owner = new HomeOwner({
    tronHome,
    trust: new TrustService(agentDir),
    sessions,
    workspace,
    // This deterministic summarizer lets record tests configure memory without
    // reaching an external provider.
    memorySummarizer: () => ({ summarizer: async () => "summary" }),
  });
  await owner.initialize();
  return {
    root,
    owner,
    recordPath: join(tronHome, "gateway", "home", "home.json"),
    directory: join(tronHome, "gateway", "home"),
    workspacePath: join(actualTronHome, "gateway", "home", "workspace"),
    created,
    replaced,
    present,
    live,
    holdProfileCommit: () => {
      let release!: () => void;
      const gate = new Promise<void>(resolve => { release = resolve; });
      let enteredResolve!: () => void;
      const entered = new Promise<void>(resolve => { enteredResolve = resolve; });
      replaceEntered = enteredResolve;
      replaceGate = gate;
      return { entered, release: () => { replaceGate = undefined; release(); } };
    },
  };
}

const MODEL = { provider: "anthropic", id: "claude-sonnet-4-5" };
const defaultModel = () => MODEL;

function chapterRecordBytes(overrides: Record<string, unknown> = {}): string {
  return `${JSON.stringify({
    version: 2, homeId: "home-1", generation: 2, routeGeneration: 1, policyRevision: 1, bindingRevision: 1,
    enabled: true, model: MODEL,
    chapters: [{ sessionId: "session-1", ordinal: 1, state: "active", createdAt: new Date().toISOString() }],
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
    ...overrides,
  })}\n`;
}

function recordBytes(overrides: Record<string, unknown> = {}): string {
  const { sessionId = "session-1", ...fields } = overrides;
  return `${JSON.stringify({
    version: 2, homeId: "home-1", chapters: [{ sessionId, ordinal: 1, state: "active", createdAt: new Date().toISOString() }],
    bindingRevision: 1, generation: 2, routeGeneration: 1, policyRevision: 1, enabled: true, model: MODEL,
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
    ...fields,
  })}\n`;
}

function legacyRecordBytes(): string {
  return `${JSON.stringify({
    version: 1, homeId: "home-1", sessionId: "session-1", generation: 2, routeGeneration: 1,
    policyRevision: 1, enabled: true, model: MODEL,
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
  })}\n`;
}

describe("Tron Home record", () => {
  it("admits a strict one-active-chapter record and resolves the physical session", async () => {
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    await writeFile(f.recordPath, chapterRecordBytes(), { mode: 0o600 });
    f.present.add("session-1");
    await f.owner.initialize();

    expect(await f.owner.status()).toMatchObject({
      available: true, enabled: true, homeId: "home-1", sessionId: "session-1", generation: 2,
    });
    expect(f.owner.chapterStateFor("session-1")).toMatchObject({ sessionId: "session-1", sealed: false, ordinal: 1 });
  });

  it("preserves and refuses the pre-chapter v1 record without rewriting it", async () => {
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    const previous = legacyRecordBytes();
    await writeFile(f.recordPath, previous, { mode: 0o600 });
    await f.owner.initialize();

    expect(await f.owner.status()).toMatchObject({ available: false, phase: "unavailable" });
    await expect(f.owner.designate({}, defaultModel)).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(f.recordPath, "utf8")).toBe(previous);
    expect(f.created).toEqual([]);
  });

  it("preserves unknown chapter-record fields instead of partially admitting them", async () => {
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    const persisted = chapterRecordBytes({ futureBinding: { attempt: "unknown" } });
    await writeFile(f.recordPath, persisted, { mode: 0o600 });
    await f.owner.initialize();
    expect(await f.owner.status()).toMatchObject({ available: false, enabled: false });
    await expect(readFile(f.recordPath, "utf8")).resolves.toBe(persisted);
  });

  it.each(["reserved", "materializing"] as const)("does not replace an unresolved %s reservation during designation", async (state) => {
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    const persisted = chapterRecordBytes({ chapters: [
      { sessionId: "session-old", ordinal: 1, state: "sealed", createdAt: new Date().toISOString(), sealedAt: new Date().toISOString() },
      { sessionId: "session-reserved", ordinal: 2, state, createdAt: new Date().toISOString(),
        ...(state === "materializing" ? { attemptId: "attempt-1", expectedPath: "/sessions/reserved.jsonl" } : {}) },
    ] });
    await writeFile(f.recordPath, persisted, { mode: 0o600 });
    await f.owner.initialize();
    await expect(f.owner.designate({ model: MODEL }, defaultModel)).rejects.toMatchObject({ code: "conflict" });
    expect(f.created).toEqual([]);
    expect(await readFile(f.recordPath, "utf8")).toBe(persisted);
    await f.owner.dispose();
  });

  it("durably claims a reserved successor and fences path writes by attempt id", async () => {
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    await writeFile(f.recordPath, chapterRecordBytes({ chapters: [
      { sessionId: "session-reserved", ordinal: 1, state: "reserved", createdAt: new Date().toISOString() },
    ] }), { mode: 0o600 });
    await f.owner.initialize();

    const claim = await f.owner.claimReservedChapter("session-reserved", "attempt-1");
    expect(claim).toMatchObject({ state: "materializing", attemptId: "attempt-1" });
    await f.owner.recordReservedChapterPath("session-reserved", "attempt-1", "/sessions/exact.jsonl");
    const recorded = await readFile(f.recordPath, "utf8");
    expect(JSON.parse(recorded).chapters[0]).toMatchObject({
      state: "materializing", attemptId: "attempt-1", expectedPath: "/sessions/exact.jsonl",
    });
    await expect(f.owner.recordReservedChapterPath("session-reserved", "stale-attempt", "/sessions/other.jsonl"))
      .rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(f.recordPath, "utf8")).toBe(recorded);
  });

  it("preserves malformed chapter topology rather than choosing an active target", async () => {
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    const malformed = chapterRecordBytes({ chapters: [
      { sessionId: "session-1", ordinal: 1, state: "active", createdAt: new Date().toISOString() },
      { sessionId: "session-1", ordinal: 2, state: "active", createdAt: new Date().toISOString() },
    ] });
    await writeFile(f.recordPath, malformed, { mode: 0o600 });
    await f.owner.initialize();

    expect(await f.owner.status()).toMatchObject({ available: false, phase: "unavailable" });
    await expect(f.owner.disable()).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(f.recordPath, "utf8")).toBe(malformed);
  });

  it("preserves a corrupt record and refuses to designate over it", async () => {
    // Failure modes 1 and 3: a corrupt record must not be silently replaced,
    // and a refused designate must not touch the file.
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    const corrupt = "{\"version\": 1, \"homeId\": \"partial\"";
    await writeFile(f.recordPath, corrupt, { mode: 0o600 });
    await f.owner.initialize();

    expect(await f.owner.status()).toMatchObject({
      available: false, enabled: false, live: false, sessionPresent: false,
      phase: "unavailable", readiness: { ready: false, gaps: ["record-unavailable"] },
      recovery: { action: "inspect-record" },
    });
    expect((await f.owner.status()).reason).toBeTypeOf("string");
    await expect(f.owner.designate({}, defaultModel)).rejects.toMatchObject({ code: "conflict", retryable: false });
    expect(await readFile(f.recordPath, "utf8")).toBe(corrupt);
    expect(f.created).toEqual([]);

    // Control: a valid record in the same shape loads as available.
    const control = await harness();
    await mkdir(control.directory, { recursive: true });
    await writeFile(control.recordPath, recordBytes(), { mode: 0o600 });
    control.present.add("session-1");
    await control.owner.initialize();
    expect(await control.owner.status()).toMatchObject({
      available: true, enabled: true, homeId: "home-1", generation: 2, sessionPresent: true, live: false,
      phase: "blocked", readiness: { ready: false, gaps: ["memory-not-configured"] },
      recovery: { action: "configure-memory" },
    });
    expect(control.owner.profileFor("session-1")).toBe("home");
    expect(control.owner.profileFor("session-2")).toBe("unnamed");
  });

  it("refuses runtime admission from Home's workspace when the record is unavailable", async () => {
    const f = await harness();
    await mkdir(f.workspacePath, { recursive: true });
    await mkdir(f.directory, { recursive: true });
    await writeFile(f.recordPath, "{broken", { mode: 0o600 });
    await f.owner.initialize();
    await f.owner.initialize();
    const canonicalWorkspace = await realpath(f.workspacePath);
    expect(() => f.owner.profileFor("session-1", canonicalWorkspace)).toThrow(expect.objectContaining({ code: "conflict" }));
    expect(f.owner.profileFor("ordinary-session", f.root)).toBe("unnamed");
  });

  it("matches unavailable Home workspace identity through a symlinked installation path", async () => {
    const f = await harness({ symlinkHome: true });
    await mkdir(f.workspacePath, { recursive: true });
    await mkdir(f.directory, { recursive: true });
    await writeFile(f.recordPath, "{broken", { mode: 0o600 });
    await f.owner.initialize();
    await f.owner.initialize();
    const canonicalWorkspace = await realpath(f.workspacePath);
    expect(() => f.owner.profileFor("former-home", canonicalWorkspace)).toThrow(expect.objectContaining({ code: "conflict" }));
    expect(f.owner.profileFor("ordinary-session", f.root)).toBe("unnamed");
  });

  it("preserves an unknown-version record instead of migrating it", async () => {
    // Failure mode 2: a future record shape is not this build's to rewrite.
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    const future = recordBytes({ version: 3 });
    await writeFile(f.recordPath, future, { mode: 0o600 });
    await f.owner.initialize();

    expect(await f.owner.status()).toMatchObject({
      available: false, enabled: false, phase: "unavailable",
      readiness: { ready: false, gaps: ["record-unavailable"] }, recovery: { action: "inspect-record" },
    });
    await expect(f.owner.disable()).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(f.recordPath, "utf8")).toBe(future);
  });

  it("admits a record written against a newer policy revision", async () => {
    // P3-1: only the format version gates admission. A newer curated-profile
    // revision is still this build's record to read and preserve.
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    await writeFile(f.recordPath, recordBytes({ policyRevision: 7 }), { mode: 0o600 });
    f.present.add("session-1");
    await f.owner.initialize();

    expect(await f.owner.status()).toMatchObject({
      available: true, enabled: true, sessionId: "session-1", generation: 2, model: MODEL,
    });
    expect(f.owner.profileFor("session-1")).toBe("home");
  });

  it("treats an empty or permissively-readable record as unavailable and preserves it", async () => {
    // P2-3: the record is read with the owner-only boundary, so an empty file
    // and a group/world-readable file are unavailable rather than absent.
    const empty = await harness();
    await mkdir(empty.directory, { recursive: true });
    await writeFile(empty.recordPath, "");
    await empty.owner.initialize();
    expect(await empty.owner.status()).toMatchObject({ available: false, enabled: false, sessionPresent: false });
    await expect(empty.owner.designate({}, defaultModel)).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(empty.recordPath, "utf8")).toBe("");
    expect(empty.created).toEqual([]);

    const permissive = await harness();
    await mkdir(permissive.directory, { recursive: true });
    await writeFile(permissive.recordPath, recordBytes(), { mode: 0o644 });
    await permissive.owner.initialize();
    expect(await permissive.owner.status()).toMatchObject({ available: false, enabled: false });
    expect((await stat(permissive.recordPath)).mode & 0o077).not.toBe(0);

    const symlinked = await harness();
    await mkdir(join(symlinked.root, "elsewhere"), { recursive: true });
    await mkdir(symlinked.directory, { recursive: true });
    await writeFile(join(symlinked.root, "elsewhere", "home.json"), recordBytes(), { mode: 0o600 });
    await import("node:fs/promises").then(({ symlink }) => symlink(join(symlinked.root, "elsewhere", "home.json"), symlinked.recordPath));
    await symlinked.owner.initialize();
    expect(await symlinked.owner.status()).toMatchObject({ available: false, enabled: false });
  });

  it("refuses an oversized outgoing ledger before replacing the readable record", async () => {
    const f = await harness();
    await f.owner.designate({ model: MODEL }, defaultModel);
    const previous = await readFile(f.recordPath, "utf8");
    const now = new Date().toISOString();
    const chapters = Array.from({ length: 100_000 }, (_, index) => ({
      sessionId: `chapter-${index}-${"x".repeat(140)}`,
      ordinal: index + 1,
      state: index === 99_999 ? "active" as const : "sealed" as const,
      createdAt: now,
      ...(index === 99_999 ? {} : { sealedAt: now }),
    }));
    const oversized: HomeRecord = {
      version: 2, homeId: "home-large", chapters, bindingRevision: 1, generation: 1, routeGeneration: 1,
      policyRevision: 1, enabled: true, model: MODEL, createdAt: now, updatedAt: now,
    };
    const writer = f.owner as unknown as { writeLocked(record: HomeRecord): Promise<void> };
    await expect(writer.writeLocked(oversized)).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(f.recordPath, "utf8")).toBe(previous);
  }, 30_000);

  it("writes the record owner-only with no temporary file left, and an owner-only workspace", async () => {
    // Failure modes 4, 5 and 10: one durable replacement, owner-only bytes, and
    // an owner-only neutral working directory.
    const f = await harness();
    const designation = await f.owner.designate({ model: MODEL }, defaultModel);

    expect((await readdir(f.directory)).filter((name) => name.includes(".tmp"))).toEqual([]);
    expect((await stat(f.recordPath)).mode & 0o777).toBe(0o600);
    expect((await stat(f.workspacePath)).mode & 0o777).toBe(0o700);
    const stored = JSON.parse(await readFile(f.recordPath, "utf8")) as HomeRecord;
    expect(stored).toMatchObject({
      version: 2, bindingRevision: 1, policyRevision: 1, enabled: true, generation: 1, model: MODEL,
      chapters: [{ sessionId: designation.sessionId, ordinal: 1, state: "active" }],
    });
    expect(stored.createdAt).toBe(stored.updatedAt);
    expect(stored.homeId).toBe(designation.homeId);
    expect(f.owner.profileFor(designation.sessionId)).toBe("home");
  });

  it("records the neutral working directory as untrusted before the session exists", async () => {
    // Failure mode 11: without an explicit decision `requireResolved` would
    // block the Home cwd.
    const f = await harness();
    await f.owner.designate({ model: MODEL }, defaultModel);
    const trust = new TrustService(join(f.root, "agent"));
    const inspection = await trust.inspect(f.workspacePath);
    expect(inspection.savedDecision).toBe(false);
    expect(inspection.effectiveDecision).toBe(false);
  });

  it("is idempotent while enabled and advances the generation on re-enable", async () => {
    // Failure modes 6 and 7.
    const f = await harness();
    const first = await f.owner.designate({ model: MODEL }, defaultModel);
    expect(await f.owner.designate({ model: MODEL }, defaultModel)).toEqual(first);
    expect(f.created).toEqual([first.sessionId]);

    const disabled = await f.owner.disable();
    expect(disabled).toEqual({ ...first, generation: first.generation + 1 });
    expect(await f.owner.status()).toMatchObject({
      enabled: false, generation: 2, sessionId: first.sessionId, phase: "disabled",
      readiness: { ready: false, gaps: ["disabled", "memory-not-configured"] }, recovery: { action: "designate" },
    });

    const reenabled = await f.owner.designate({ model: MODEL }, defaultModel);
    expect(reenabled).toEqual({ ...first, generation: 3 });
    expect(f.created).toEqual([first.sessionId]);
    // Every profile change on a live session replaces its runtime in place.
    expect(f.replaced).toEqual([first.sessionId, first.sessionId]);
  });

  it("designates a fresh session when the recorded session is gone", async () => {
    // P1: a dangling record must not be re-enabled on a session that no longer
    // exists, and must not be discarded either.
    const f = await harness();
    const first = await f.owner.designate({ model: MODEL }, defaultModel);
    f.present.delete(first.sessionId);
    f.live.delete(first.sessionId);
    expect(await f.owner.status()).toMatchObject({
      phase: "missing-session", readiness: { ready: false, gaps: ["session-missing", "memory-not-configured"] },
      recovery: { action: "designate", reason: "Home session is missing" },
    });

    const second = await f.owner.designate({ model: MODEL }, defaultModel);
    expect(second).toEqual({ homeId: first.homeId, sessionId: "session-2", generation: 2 });
    expect(f.created).toEqual([first.sessionId, "session-2"]);
    expect(await f.owner.status()).toMatchObject({
      enabled: true, sessionId: "session-2", generation: 2, phase: "blocked",
      readiness: { ready: false, gaps: ["memory-not-configured"] }, recovery: { action: "configure-memory" },
    });

    // The disabled case is the same: the record is kept, the session is new.
    const third = await harness();
    const disabled = await third.owner.designate({ model: MODEL }, defaultModel);
    await third.owner.disable();
    third.present.delete(disabled.sessionId);
    third.live.delete(disabled.sessionId);
    expect(await third.owner.designate({ model: MODEL }, defaultModel))
      .toEqual({ homeId: disabled.homeId, sessionId: "session-2", generation: 3 });
    expect(third.created).toEqual([disabled.sessionId, "session-2"]);
  });

  it("marks the record disabled when its session is gone, without touching a runtime", async () => {
    // P1: disable with a missing session is only a record change.
    const f = await harness();
    const first = await f.owner.designate({ model: MODEL }, defaultModel);
    f.present.delete(first.sessionId);
    f.live.delete(first.sessionId);

    const disabled = await f.owner.disable();
    expect(disabled).toEqual({ ...first, generation: 2 });
    expect(await f.owner.status()).toMatchObject({
      enabled: false, sessionPresent: false, phase: "disabled",
      readiness: { ready: false, gaps: ["disabled", "session-missing", "memory-not-configured"] },
      recovery: { action: "designate", reason: "Home session is missing" },
    });
  });

  it("re-enables on the recorded model when the request names none", async () => {
    // P2-2: the record's model is the fallback, and the default resolver is
    // only consulted for a fresh session.
    const f = await harness();
    const first = await f.owner.designate({ model: MODEL }, defaultModel);
    await f.owner.disable();
    const other = { provider: "openai", id: "gpt-6-astra" };
    expect(await f.owner.designate({}, () => other)).toEqual({ ...first, generation: 3 });
    expect(JSON.parse(await readFile(f.recordPath, "utf8"))).toMatchObject({ model: MODEL });

    // A fresh designation does use the resolver.
    f.present.delete(first.sessionId);
    f.live.delete(first.sessionId);
    await f.owner.designate({}, () => other);
    expect(JSON.parse(await readFile(f.recordPath, "utf8"))).toMatchObject({ model: other });
  });

  it("merges a model update completed while disable waits for the slot lane", async () => {
    const f = await harness();
    const designated = await f.owner.designate({ model: MODEL }, defaultModel);
    const chatModel = { provider: "openai", id: "chat-model-during-disable" };
    const gate = f.holdProfileCommit();
    const disabling = f.owner.disable();
    await gate.entered;
    await f.owner.noteModelApplied(designated.sessionId, chatModel);
    gate.release();
    await disabling;
    expect(JSON.parse(await readFile(f.recordPath, "utf8"))).toMatchObject({ enabled: false, model: chatModel });
  });

  it("preserves concurrent memory and chat-model updates", async () => {
    const f = await harness();
    const designated = await f.owner.designate({ model: MODEL }, defaultModel);
    const memoryModel = { provider: "openai", id: "memory-model" };
    const chatModel = { provider: "openai", id: "chat-model" };
    await Promise.all([
      f.owner.configureMemory({ model: memoryModel }),
      f.owner.noteModelApplied(designated.sessionId, chatModel),
    ]);
    expect(JSON.parse(await readFile(f.recordPath, "utf8"))).toMatchObject({ model: chatModel, memory: { model: memoryModel } });
    await f.owner.dispose();
  });

  it("tracks a model applied to the enabled Home session, and ignores other sessions", async () => {
    // P2-2: the record is the single source of truth for Home's model.
    const f = await harness();
    const first = await f.owner.designate({ model: MODEL }, defaultModel);
    const other = { provider: "openai", id: "gpt-6-astra" };

    await f.owner.noteModelApplied("not-home", other);
    expect(JSON.parse(await readFile(f.recordPath, "utf8"))).toMatchObject({ model: MODEL });

    await f.owner.noteModelApplied(first.sessionId, other);
    expect(JSON.parse(await readFile(f.recordPath, "utf8"))).toMatchObject({ model: other });
    expect((await f.owner.status()).model).toEqual(other);

    // A disabled Home is an ordinary session: its model changes are not Home's.
    await f.owner.disable();
    await f.owner.noteModelApplied(first.sessionId, MODEL);
    expect((await f.owner.status()).model).toEqual(other);
  });

  it("refuses disable without a record instead of creating one", async () => {
    // Failure mode 9.
    const f = await harness();
    expect(await f.owner.status()).toMatchObject({
      phase: "undesignated", readiness: { ready: false, gaps: ["not-designated"] },
      activation: { available: false }, recovery: { action: "designate" },
    });
    await expect(f.owner.disable()).rejects.toMatchObject({ code: "not_found" });
    await expect(readFile(f.recordPath, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    expect(f.created).toEqual([]);
  });

  it("admits a record written before Home's memory existed, and leaves it alone", async () => {
    // The record keeps version 1 with an optional `memory`: a record without one
    // is this build's record, and it refuses its activations rather than inventing
    // a model or a budget (decision D4).
    const h = await harness();
    // The record is written first: `initialize` is the only reader that matters.
    const previous = await harness();
    await rm(h.recordPath, { force: true });
    await mkdir(h.directory, { recursive: true });
    const bytes = recordBytes({ sessionId: "session-1" });
    expect(bytes.includes("\"memory\"")).toBe(false);
    await writeFile(h.recordPath, bytes, { mode: 0o600 });
    const owner = new HomeOwner({
      tronHome: join(h.root, "tron"),
      trust: new TrustService(join(h.root, "agent")),
      sessions: {
        createHomeSession: async () => "unused",
        applySessionModel: async () => {},
        sessionFile: async () => undefined,
        sessionPresent: async () => true,
        hasLiveRuntime: () => false,
        serializeSessionMutation: async (_id, commit) => commit(),
        replaceRuntimeForProfile: async (_sessionId, commit) => { await commit(); },
      },
      workspace: new TronWorkspace(join(h.root, "tron")),
      memorySummarizer: () => ({ refusal: "unavailable" }),
    });
    await owner.initialize();
    expect(owner.profileFor("session-1")).toBe("home");
    const status = await owner.status();
    expect(status.memory).toEqual({ configured: false, open: false });
    expect(status).toMatchObject({
      phase: "blocked", activation: { available: false },
      readiness: { ready: false, gaps: ["memory-not-configured"] },
      recovery: { action: "configure-memory" },
    });
    // The preserved record is never rewritten by a read: only the lifecycle
    // mutations do that.
    expect(await readFile(h.recordPath, "utf8")).toBe(bytes);
    await previous.owner.dispose();
    await owner.dispose();
  });

  it("refuses to configure the memory of a disabled Home", async () => {
    const h = await harness();
    await mkdir(h.directory, { recursive: true });
    await writeFile(h.recordPath, recordBytes({ enabled: false }), { mode: 0o600 });
    await h.owner.initialize();
    await expect(h.owner.configureMemory({ model: MODEL })).rejects.toMatchObject({ code: "conflict" });
    expect((JSON.parse(await readFile(h.recordPath, "utf8")) as HomeRecord).memory).toBeUndefined();
    await h.owner.dispose();
  });

  it("keeps the memory configuration when a designation replaces a lost session", async () => {
    // The configuration is the user's decision about how Home remembers; the
    // spend belongs to the session, and the new session's store starts its own.
    const h = await harness();
    await mkdir(h.directory, { recursive: true });
    const memory = { model: { provider: "anthropic", id: "haiku-4-5" } };
    await writeFile(h.recordPath, recordBytes({ sessionId: "session-gone", memory }), { mode: 0o600 });
    await h.owner.initialize();
    expect(h.present.has("session-gone")).toBe(false);
    const designation = await h.owner.designate({}, defaultModel);
    const written = JSON.parse(await readFile(h.recordPath, "utf8")) as HomeRecord;
    expect(designation.sessionId).not.toBe("session-gone");
    expect(written.memory).toEqual(memory);
    expect(written.generation).toBe(3);
    await h.owner.dispose();
  });
});
