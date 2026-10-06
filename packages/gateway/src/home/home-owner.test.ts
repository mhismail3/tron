import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { HomeOwner, type HomeRecord, type HomeSessionPort } from "./home-owner.js";

const roots: string[] = [];
afterEach(async () => {
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
}

/** A port that records the calls the owner makes, so the assertions stay about
 * the owner's own decisions (record bytes, generations, session identity) and
 * never about a mocked mechanism. */
async function harness(): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "tron-home-owner-"));
  roots.push(root);
  const agentDir = join(root, "agent");
  await mkdir(agentDir);
  const created: string[] = [];
  const replaced: string[] = [];
  const present = new Set<string>();
  const live = new Set<string>();
  let sequence = 0;
  const sessions: HomeSessionPort = {
    createHomeSession: async () => {
      const sessionId = `session-${++sequence}`;
      created.push(sessionId);
      present.add(sessionId);
      live.add(sessionId);
      return sessionId;
    },
    applySessionModel: async () => {},
    sessionPresent: async (sessionId) => present.has(sessionId),
    hasLiveRuntime: (sessionId) => live.has(sessionId),
    replaceRuntimeForProfile: async (sessionId, commit) => {
      replaced.push(sessionId);
      await commit();
    },
  };
  const owner = new HomeOwner({ tronHome: join(root, "tron"), trust: new TrustService(agentDir), sessions });
  await owner.initialize();
  return {
    root,
    owner,
    recordPath: join(root, "tron", "gateway", "home", "home.json"),
    directory: join(root, "tron", "gateway", "home"),
    workspacePath: join(root, "tron", "gateway", "home", "workspace"),
    created,
    replaced,
    present,
    live,
  };
}

const MODEL = { provider: "anthropic", id: "claude-sonnet-4-5" };
const defaultModel = () => MODEL;

function recordBytes(overrides: Partial<HomeRecord> = {}): string {
  return `${JSON.stringify({
    version: 1, homeId: "home-1", sessionId: "session-1", generation: 2,
    policyRevision: 1, enabled: true, model: MODEL,
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
    ...overrides,
  })}\n`;
}

describe("Tron Home record", () => {
  it("preserves a corrupt record and refuses to designate over it", async () => {
    // Failure modes 1 and 3: a corrupt record must not be silently replaced,
    // and a refused designate must not touch the file.
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    const corrupt = "{\"version\": 1, \"homeId\": \"partial\"";
    await writeFile(f.recordPath, corrupt, { mode: 0o600 });
    await f.owner.initialize();

    expect(await f.owner.status()).toMatchObject({ available: false, enabled: false, live: false, sessionPresent: false });
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
    });
    expect(control.owner.profileFor("session-1")).toBe("home");
    expect(control.owner.profileFor("session-2")).toBe("unnamed");
  });

  it("preserves an unknown-version record instead of migrating it", async () => {
    // Failure mode 2: a future record shape is not this build's to rewrite.
    const f = await harness();
    await mkdir(f.directory, { recursive: true });
    const future = recordBytes({ version: 2 as unknown as 1 });
    await writeFile(f.recordPath, future, { mode: 0o600 });
    await f.owner.initialize();

    expect(await f.owner.status()).toMatchObject({ available: false, enabled: false });
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
      version: 1, policyRevision: 1, enabled: true, generation: 1, model: MODEL,
      sessionId: designation.sessionId,
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
    expect(await f.owner.status()).toMatchObject({ enabled: false, generation: 2, sessionId: first.sessionId });

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

    const second = await f.owner.designate({ model: MODEL }, defaultModel);
    expect(second).toEqual({ homeId: first.homeId, sessionId: "session-2", generation: 2 });
    expect(f.created).toEqual([first.sessionId, "session-2"]);
    expect(await f.owner.status()).toMatchObject({ enabled: true, sessionId: "session-2", generation: 2 });

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
    expect(f.replaced).toEqual([]);
    expect(await f.owner.status()).toMatchObject({ enabled: false, sessionPresent: false });
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
    await expect(f.owner.disable()).rejects.toMatchObject({ code: "not_found" });
    await expect(readFile(f.recordPath, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    expect(f.created).toEqual([]);
  });
});
