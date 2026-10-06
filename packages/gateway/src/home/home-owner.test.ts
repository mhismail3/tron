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
  workspacePath: string;
  created: string[];
  retired: string[];
  busy: Set<string>;
  live: Set<string>;
}

async function harness(): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "tron-home-owner-"));
  roots.push(root);
  const agentDir = join(root, "agent");
  await mkdir(agentDir);
  const created: string[] = [];
  const retired: string[] = [];
  const busy = new Set<string>();
  const live = new Set<string>();
  let sequence = 0;
  const sessions: HomeSessionPort = {
    createHomeSession: async () => {
      const sessionId = `session-${++sequence}`;
      created.push(sessionId);
      live.add(sessionId);
      return sessionId;
    },
    applySessionModel: async () => {},
    hasLiveRuntime: (sessionId) => live.has(sessionId),
    isBusy: (sessionId) => busy.has(sessionId),
    retireIdleRuntime: async (sessionId) => {
      if (!live.has(sessionId) || busy.has(sessionId)) return false;
      retired.push(sessionId);
      live.delete(sessionId);
      return true;
    },
  };
  const owner = new HomeOwner({ tronHome: join(root, "tron"), trust: new TrustService(agentDir), sessions });
  await owner.initialize();
  return {
    root,
    owner,
    recordPath: join(root, "tron", "gateway", "home", "home.json"),
    workspacePath: join(root, "tron", "gateway", "home", "workspace"),
    created,
    retired,
    busy,
    live,
  };
}

const MODEL = { provider: "anthropic", id: "claude-sonnet-4-5" };

describe("Tron Home record", () => {
  it("preserves a corrupt record and refuses to designate over it", async () => {
    // Failure modes 1 and 3: a corrupt record must not be silently replaced,
    // and a refused designate must not touch the file.
    const f = await harness();
    await mkdir(join(f.root, "tron", "gateway", "home"), { recursive: true });
    const corrupt = "{\"version\": 1, \"homeId\": \"partial\"";
    await writeFile(f.recordPath, corrupt);
    await f.owner.initialize();

    expect(f.owner.status()).toMatchObject({ available: false, enabled: false, live: false });
    expect(f.owner.status().reason).toBeTypeOf("string");
    await expect(f.owner.designate(MODEL)).rejects.toMatchObject({ code: "conflict", retryable: false });
    expect(await readFile(f.recordPath, "utf8")).toBe(corrupt);
    expect(f.created).toEqual([]);

    // Control: a valid record in the same shape loads as available.
    const control = await harness();
    await mkdir(join(control.root, "tron", "gateway", "home"), { recursive: true });
    await writeFile(control.recordPath, `${JSON.stringify({
      version: 1, homeId: "home-1", sessionId: "session-1", generation: 2,
      policyRevision: 1, enabled: true, model: MODEL,
      createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
    })}\n`);
    await control.owner.initialize();
    expect(control.owner.status()).toMatchObject({ available: true, enabled: true, homeId: "home-1", generation: 2 });
    expect(control.owner.isEnabledHome("session-1")).toBe(true);
  });

  it("preserves an unknown-version record instead of migrating it", async () => {
    // Failure mode 2: a future record shape is not this build's to rewrite.
    const f = await harness();
    await mkdir(join(f.root, "tron", "gateway", "home"), { recursive: true });
    const future = `${JSON.stringify({
      version: 2, homeId: "home-1", sessionId: "session-1", generation: 1,
      policyRevision: 7, enabled: true, model: MODEL,
      createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
    })}\n`;
    await writeFile(f.recordPath, future);
    await f.owner.initialize();

    expect(f.owner.status()).toMatchObject({ available: false, enabled: false });
    await expect(f.owner.disable()).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(f.recordPath, "utf8")).toBe(future);
  });

  it("writes the record atomically and owner-only, with no temporary file left", async () => {
    // Failure modes 4, 5 and 10: one durable replacement, owner-only bytes, and
    // an owner-only neutral working directory.
    const f = await harness();
    const designation = await f.owner.designate(MODEL);

    const directory = join(f.root, "tron", "gateway", "home");
    expect((await readdir(directory)).filter((name) => name.includes(".tmp"))).toEqual([]);
    expect((await stat(f.recordPath)).mode & 0o777).toBe(0o600);
    expect((await stat(f.workspacePath)).mode & 0o777).toBe(0o700);
    const stored = JSON.parse(await readFile(f.recordPath, "utf8")) as HomeRecord;
    expect(stored).toMatchObject({
      version: 1, policyRevision: 1, enabled: true, generation: 1, model: MODEL,
      sessionId: designation.sessionId,
    });
    expect(stored.createdAt).toBe(stored.updatedAt);
    expect(stored.homeId).toBe(designation.homeId);
  });

  it("records the neutral working directory as untrusted before the session exists", async () => {
    // Failure mode 11: without an explicit decision `requireResolved` would
    // block the Home cwd.
    const f = await harness();
    await f.owner.designate(MODEL);
    const trust = new TrustService(join(f.root, "agent"));
    const inspection = await trust.inspect(f.workspacePath);
    expect(inspection.savedDecision).toBe(false);
    expect(inspection.effectiveDecision).toBe(false);
  });

  it("is idempotent while enabled and advances the generation on re-enable", async () => {
    // Failure modes 6 and 7.
    const f = await harness();
    const first = await f.owner.designate(MODEL);
    expect(await f.owner.designate(MODEL)).toEqual(first);
    expect(f.created).toEqual([first.sessionId]);

    const disabled = await f.owner.disable();
    expect(disabled).toEqual({ ...first, generation: first.generation + 1 });
    expect(f.owner.status()).toMatchObject({ enabled: false, generation: 2, sessionId: first.sessionId });

    const reenabled = await f.owner.designate(MODEL);
    expect(reenabled).toEqual({ ...first, generation: 3 });
    expect(f.created).toEqual([first.sessionId]);
  });

  it("refuses a profile change while the session is running, and changes nothing", async () => {
    // Failure mode 8: a busy session must be refused retryably, leaving the
    // record and its generation untouched.
    const f = await harness();
    const first = await f.owner.designate(MODEL);
    f.busy.add(first.sessionId);

    await expect(f.owner.disable()).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(f.owner.status()).toMatchObject({ enabled: true, generation: 1 });
    expect(f.retired).toEqual([]);
  });

  it("retires an idle live runtime so the next runtime reads the new profile", async () => {
    // Failure mode 20: a live runtime must not keep the previous profile.
    const f = await harness();
    const first = await f.owner.designate(MODEL);
    expect(f.live.has(first.sessionId)).toBe(true);
    await f.owner.disable();
    expect(f.retired).toEqual([first.sessionId]);
    expect(f.owner.status()).toMatchObject({ enabled: false, live: false });

    await f.owner.designate(MODEL);
    // Re-enabling reuses the same session, so the next runtime is built on the
    // next acquisition rather than by designation.
    expect(f.created).toEqual([first.sessionId]);
    f.live.add(first.sessionId);
    await f.owner.disable();
    expect(f.retired).toEqual([first.sessionId, first.sessionId]);
  });

  it("refuses disable without a record instead of creating one", async () => {
    // Failure mode 9.
    const f = await harness();
    await expect(f.owner.disable()).rejects.toMatchObject({ code: "not_found" });
    await expect(readFile(f.recordPath, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    expect(f.created).toEqual([]);
  });
});
