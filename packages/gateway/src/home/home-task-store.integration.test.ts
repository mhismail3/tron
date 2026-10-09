import { createHash } from "node:crypto";
import { chmod, cp, lstat, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile, open, rename } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeTaskAuthorization } from "./home-task-authorization.js";
import { WakeInboxOwner } from "./home-wake-inbox.js";
import { HomeTaskStore, type HomeTaskRecord, type HomeTaskWrite, type HomeTaskStoreDiagnostic } from "./home-task-store.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(workspaces.splice(0).map(workspace => workspace.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-task-store-"));
  roots.push(root);
  const workspace = new TronWorkspace(root);
  workspaces.push(workspace);
  await workspace.initialize();
  const diagnostics: HomeTaskStoreDiagnostic[] = [];
  const store = new HomeTaskStore(root, workspace, { diagnostic: record => diagnostics.push(record) });
  const directory = join(root, "gateway", "home", "tasks");
  const marker = join(root, "gateway", "workspace-state", "home-tasks-initialized.json");
  return { root, workspace, store, diagnostics, directory, marker, taskPath: async () => join(directory, (await readdir(directory)).find(name => name.endsWith("-task-1.json"))!), authPath: join(directory, "authorization.json") };
}

function task(): HomeTaskWrite {
  const intent = { revision: 1, text: "Investigate a trusted project" };
  return {
    version: 1, taskId: "task-1", revision: 1, homeId: "home-1", generation: 1, routeGeneration: 1,
    intent, intentDigest: createHash("sha256").update(JSON.stringify(intent)).digest("hex"),
    target: "/trusted/project", workerProfile: "home-task-v1", policyRevision: 1,
    grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null,
    controllerGeneration: null, stopIntent: null, spend: null, reportRefs: null, terminalEvidence: null, wake: null,
  };
}

function authorization(store: HomeTaskStore) {
  return new HomeTaskAuthorization({
    store: store.authorization, now: () => 1_000,
    resolveTrustedTarget: async target => target === "/trusted/project" ? target : undefined,
  });
}
const request = {
  intentRevision: 1, intentDigest: "digest", target: "/trusted/project", authorizationScope: "project-work",
  workerProfile: "home-task-v1", policyRevision: 1, restoreEpoch: "epoch-1",
};

async function bytes(directory: string): Promise<Record<string, string>> {
  const result: Record<string, string> = {};
  for (const name of (await readdir(directory)).sort()) result[name] = await readFile(join(directory, name), "utf8");
  return result;
}

async function listed(store: HomeTaskStore): Promise<HomeTaskRecord[]> {
  const records: HomeTaskRecord[] = [];
  await store.list(record => { records.push(record); });
  return records;
}

async function issueGrant(owner: import("./home-task-authorization.js").HomeTaskAuthorization,
  request: import("./home-task-authorization.js").HomeTaskAuthorizationRequest,
  input: { decisionId: string; approved?: boolean; expiresAt: number }) {
  const { authorizationRequestId, HomeTaskAuthorizationError } = await import("./home-task-authorization.js");
  let requestId = authorizationRequestId(request);
  await owner.authorize(request).catch(error => { if (error instanceof HomeTaskAuthorizationError && error.requestId) requestId = error.requestId; });
  const result = await owner.recordDecisionAndGrant(requestId, { ...input, approved: input.approved ?? true, restoreEpoch: request.restoreEpoch });
  return result.grant!;
}

describe("HomeTaskStore durable namespace", () => {
  it("refuses a namespace symlink introduced between streamed record yields", async () => {
    const f = await fixture(); await f.store.initialize();
    await f.store.put(task(), null); await f.store.put({ ...task(), taskId: "task-2" }, null);
    const stream = f.store.records();
    try {
      expect((await stream.next()).done).toBe(false);
      const copy = join(f.root, "copy");
      await cp(f.directory, copy, { recursive: true, preserveTimestamps: true });
      await rename(f.directory, join(f.root, "original"));
      await symlink(copy, f.directory);
      await expect(stream.next()).rejects.toMatchObject({ code: "unsafe-state" });
    } finally { await stream.return(undefined); }
  });

  it("keeps physical authority through restart and atomic writes but refuses restored spent-grant snapshots", async () => {
    const f = await fixture();
    await f.store.initialize();
    const epoch = await f.store.restoreEpoch();
    const current = { ...request, restoreEpoch: epoch };
    const owner = authorization(f.store);
    const scope = await owner.enableInitialScope(epoch);
    const restarted = new HomeTaskStore(f.root, f.workspace);
    expect(await restarted.restoreEpoch()).toBe(epoch);
    await expect(authorization(restarted).authorize(current)).resolves.toMatchObject({ kind: "standing-scope" });
    await f.store.put(task(), null);
    await f.store.put({ ...task(), revision: 2, controllerGeneration: 1 }, 1);
    expect(await f.store.restoreEpoch()).toBe(epoch);
    await owner.revokeScope(scope.id);
    await issueGrant(owner, current, { decisionId: "physical-grant", expiresAt: 2_000 });
    const snapshot = join(f.root, "snapshot");
    await cp(f.directory, snapshot, { recursive: true, preserveTimestamps: true });
    await expect(owner.authorize(current)).resolves.toMatchObject({ kind: "one-use-grant" });
    await rm(f.directory, { recursive: true }); await rename(snapshot, f.directory);
    const restoredEpoch = await f.store.restoreEpoch();
    expect(restoredEpoch).not.toBe(epoch);
    await expect(authorization(f.store).authorize({ ...current, restoreEpoch: restoredEpoch })).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
    expect((await f.store.authorization.load()).grants[0].state).toBe("available");
    await chmod(f.directory, 0o000);
    try { await expect(f.store.restoreEpoch()).rejects.toMatchObject({ code: "unsafe-state" }); }
    finally { await chmod(f.directory, 0o700); }
  });

  it("never replaces an already terminal immutable result", async () => {
    const f = await fixture(); await f.store.initialize();
    const terminal: HomeTaskWrite = { ...task(), wake: new WakeInboxOwner(f.store, {} as never).event(task() as HomeTaskRecord), lifecycle: "terminal", terminalEvidence: { outcome: "unknown", sessionId: null, entryIds: [], reason: "no-report" } };
    await f.store.put(terminal, null);
    await expect(f.store.put({ ...terminal, revision: 2, terminalEvidence: { ...terminal.terminalEvidence!, reason: "edited" } }, 1)).rejects.toMatchObject({ code: "invalid-record" });
    expect(await f.store.read(terminal.taskId)).toMatchObject(terminal);
  });
  it("requires explicit initialization before any write and publishes owner-only files", async () => {
    const f = await fixture();
    await expect(f.store.put(task(), null)).rejects.toMatchObject({ code: "not-initialized" });
    await expect(authorization(f.store).enableInitialScope("epoch-1")).rejects.toMatchObject({ code: "not-initialized" });
    await expect(lstat(f.directory)).rejects.toMatchObject({ code: "ENOENT" });
    await f.store.initialize();
    await f.store.put(task(), null);
    expect((await lstat(f.directory)).mode & 0o777).toBe(0o700);
    for (const path of [f.marker, f.authPath, await f.taskPath()]) expect((await lstat(path)).mode & 0o777).toBe(0o600);
    expect(await listed(f.store)).toMatchObject([task()]);
    const before = await bytes(f.directory);
    await f.store.initialize();
    expect(await bytes(f.directory)).toEqual(before);
  });

  it("serializes expected-revision replacements and preserves immutable identity/intent across restart", async () => {
    const f = await fixture();
    await f.store.initialize();
    await f.store.put(task(), null);
    const next = { ...task(), revision: 2, controllerGeneration: 1 };
    const results = await Promise.allSettled([f.store.put(next, 1), f.store.put({ ...next, controllerGeneration: 2 }, 1)]);
    expect(results.filter(result => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter(result => result.status === "rejected")).toHaveLength(1);
    const restarted = new HomeTaskStore(f.root, f.workspace);
    expect(await listed(restarted)).toMatchObject([next]);
    const before = await readFile(await f.taskPath(), "utf8");
    const changedIntent = { revision: 2, text: "Changed intent" };
    await expect(restarted.put({ ...next, revision: 3, intent: changedIntent,
      intentDigest: createHash("sha256").update(JSON.stringify(changedIntent)).digest("hex") }, 2)).rejects.toMatchObject({ code: "invalid-record" });
    await expect(restarted.put({ ...next, revision: 2 }, 2)).rejects.toMatchObject({ code: "revision-conflict" });
    expect(await readFile(await f.taskPath(), "utf8")).toBe(before);
  });

  it("persists scopes, unused and consumed grants and revision fencing on restart; restore epoch is not startup", async () => {
    const f = await fixture();
    await f.store.initialize();
    const owner = authorization(f.store);
    const scope = await owner.enableInitialScope("epoch-1");
    const restarted = new HomeTaskStore(f.root, f.workspace);
    await expect(authorization(restarted).authorize(request)).resolves.toEqual({ kind: "standing-scope", scopeId: scope.id });
    await expect(authorization(restarted).authorize({ ...request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
    await authorization(restarted).revokeScope(scope.id);
    const grant = await issueGrant(authorization(restarted), request, { decisionId: "decision-1", expiresAt: 2_000 });
    const afterGrant = new HomeTaskStore(f.root, f.workspace);
    const before = await afterGrant.authorization.load();
    expect(before.grants[0]).toMatchObject({ id: grant.id, state: "available", restoreEpoch: "epoch-1" });
    await expect(authorization(afterGrant).authorize({ ...request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
    await authorization(afterGrant).authorize(request);
    await expect(afterGrant.authorization.save(before)).rejects.toMatchObject({ code: "revision-conflict" });
    const afterConsumption = new HomeTaskStore(f.root, f.workspace);
    expect((await afterConsumption.authorization.load()).grants[0].state).toBe("consumed");
    await expect(authorization(afterConsumption).authorize(request)).rejects.toMatchObject({ code: "grant-required" });
    await expect(authorization(afterConsumption).authorize({ ...request, restoreEpoch: "epoch-2" })).rejects.toMatchObject({ code: "grant-required" });
  });

  it("snapshots queued authorization writes and rejects dangling task authority references", async () => {
    const f = await fixture();
    await f.store.initialize();
    const state = await f.store.authorization.load();
    state.scopes.push({ id: "scope-1", kind: "all-trusted-projects", active: true, restoreEpoch: "epoch-1", createdAt: 1_000 });
    const saving = f.store.authorization.save(state);
    state.scopes[0].restoreEpoch = "changed-after-command";
    await saving;
    expect((await f.store.authorization.load()).scopes[0].restoreEpoch).toBe("epoch-1");
    await expect(f.store.put({ ...task(), scopeRef: "missing-scope" }, null)).rejects.toMatchObject({ code: "invalid-record" });
    await expect(f.store.put({ ...task(), grantRef: "missing-grant" }, null)).rejects.toMatchObject({ code: "invalid-record" });
    await f.store.put({ ...task(), scopeRef: "scope-1" }, null);
    expect((await listed(f.store))[0].scopeRef).toBe("scope-1");
  });

  it("fills initially null task authority once without allowing a later reference swap", async () => {
    const f = await fixture();
    await f.store.initialize();
    const grant = await issueGrant(authorization(f.store), request, { decisionId: "decision-1", expiresAt: 2_000 });
    const scope = await authorization(f.store).enableInitialScope("epoch-1");
    await f.store.put(task(), null);
    const bound = { ...task(), revision: 2, scopeRef: scope.id };
    await f.store.put(bound, 1);
    const before = await readFile(await f.taskPath(), "utf8");
    await expect(f.store.put({ ...bound, revision: 3, scopeRef: null, grantRef: grant.id }, 2)).rejects.toMatchObject({ code: "invalid-record" });
    expect(await readFile(await f.taskPath(), "utf8")).toBe(before);
  });

  it("refuses invalid active, terminal, report and spend state before publication", async () => {
    const f = await fixture();
    await f.store.initialize();
    const before = await bytes(f.directory);
    const invalid = [
      { ...task(), lifecycle: "active" },
      { ...task(), lifecycle: "terminal" },
      { ...task(), lifecycle: "terminal", terminalEvidence: { outcome: "final", sessionId: "session-1", entryIds: [], reason: "report" } },
      { ...task(), reportRefs: [{ resultId: "result-1", sessionId: "session-1", entryId: "entry-1", surprise: true }] },
      { ...task(), spend: { sourceDigest: "a".repeat(64), inputTokens: -1, outputTokens: 0, knownCostUSD: null, pricingProvenance: null, unpriced: true } },
      { ...task(), spend: { sourceDigest: "a".repeat(64), inputTokens: 1, outputTokens: 0, knownCostUSD: 1, pricingProvenance: null, unpriced: false } },
    ];
    for (const record of invalid) await expect(f.store.put(record as HomeTaskRecord, null)).rejects.toMatchObject({ code: "invalid-record" });
    expect(await bytes(f.directory)).toEqual(before);
  });

  const corruptions = [
    ["unknown-version", (value: Record<string, unknown>) => ({ ...value, version: 99 })],
    ["unknown-key", (value: Record<string, unknown>) => ({ ...value, surprise: true })],
    ["malformed", () => "{torn"],
    ["unsafe-mode", null],
    ["oversized", (value: Record<string, unknown>) => `${" ".repeat(5 * 1_024 * 1_024)}${JSON.stringify(value)}`],
  ] as const;
  for (const kind of ["task", "authorization", "marker"] as const) {
    for (const [name, corrupt] of corruptions) {
      it(`preserves and refuses ${kind} ${name}`, async () => {
        const f = await fixture();
        await f.store.initialize();
        await f.store.put(task(), null);
        const path = kind === "task" ? await f.taskPath() : kind === "authorization" ? f.authPath : f.marker;
        if (corrupt) {
          const value = corrupt(JSON.parse(await readFile(path, "utf8")));
          await writeFile(path, typeof value === "string" ? value : JSON.stringify(value), { mode: 0o600 });
        } else await chmod(path, 0o644);
        const before = await readFile(path, "utf8");
        await expect(listed(f.store)).rejects.toBeDefined();
        await expect(f.store.initialize()).rejects.toBeDefined();
        await expect(f.store.put({ ...task(), revision: 2 }, 1)).rejects.toBeDefined();
        expect(await readFile(path, "utf8")).toBe(before);
        expect(f.diagnostics.at(-1)).toMatchObject({ event: "home.task.store-refused" });
        expect(JSON.stringify(f.diagnostics)).not.toContain(f.root);
        expect(JSON.stringify(f.diagnostics)).not.toContain(task().intent.text);
      });
    }
  }

  for (const missing of ["namespace", "authorization", "marker"] as const) {
    it(`refuses ${missing} missing after initialization without recreating bytes`, async () => {
      const f = await fixture();
      await f.store.initialize();
      const path = missing === "namespace" ? f.directory : missing === "authorization" ? f.authPath : f.marker;
      await rm(path, { recursive: true });
      await expect(f.store.initialize()).rejects.toMatchObject({ code: "missing-state" });
      await expect(lstat(path)).rejects.toMatchObject({ code: "ENOENT" });
    });
  }

  it("refuses symlinked parents/files and unknown directory entries, preserving their targets", async () => {
    const f = await fixture();
    await f.store.initialize();
    await f.store.put(task(), null);
    const taskPath = await f.taskPath();
    const target = join(f.root, "saved-task.json");
    await rename(taskPath, target);
    await symlink(target, taskPath);
    const before = await readFile(target, "utf8");
    await expect(listed(f.store)).rejects.toMatchObject({ code: "unsafe-state" });
    expect(await readFile(target, "utf8")).toBe(before);
    await rm(taskPath);
    await rename(target, taskPath);
    const unknown = join(f.directory, "unexpected.json");
    await writeFile(unknown, "{}", { mode: 0o600 });
    await expect(listed(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await rm(unknown);
    const saved = join(f.root, "saved-tasks");
    await rename(f.directory, saved);
    await symlink(saved, f.directory);
    await expect(listed(f.store)).rejects.toMatchObject({ code: "unsafe-state" });
    expect(await readFile(join(saved, basename(taskPath)), "utf8")).toBe(before);
  });

  it("rejects invalid task identity/digest and duplicate authorization identities/references", async () => {
    const f = await fixture();
    await f.store.initialize();
    await f.store.put(task(), null);
    const before = await readFile(await f.taskPath(), "utf8");
    await writeFile(await f.taskPath(), JSON.stringify({ ...task(), taskId: "different-id" }));
    await expect(listed(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await writeFile(await f.taskPath(), JSON.stringify({ ...task(), intentDigest: "0".repeat(64) }));
    await expect(listed(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await writeFile(await f.taskPath(), before);
    await issueGrant(authorization(f.store), request, { decisionId: "decision-1", expiresAt: 2_000 });
    const valid = JSON.parse(await readFile(f.authPath, "utf8"));
    for (const broken of [
      { ...valid, grants: [...valid.grants, valid.grants[0]] },
      { ...valid, grants: [{ ...valid.grants[0], decisionId: "absent" }] },
      { ...valid, decisions: [{ ...valid.decisions[0], approved: false }] },
    ]) {
      const raw = JSON.stringify(broken);
      await writeFile(f.authPath, raw);
      await expect(listed(f.store)).rejects.toMatchObject({ code: "invalid-record" });
      expect(await readFile(f.authPath, "utf8")).toBe(raw);
    }
  });

  it("streams and validates every entry without a task-count cap", async () => {
    const f = await fixture();
    await f.store.initialize();
    for (let index = 1; index <= 3; index++) await f.store.put({ ...task(), taskId: `task-${index}` }, null);
    expect((await listed(f.store)).map(record => record.taskId).sort()).toEqual(["task-1", "task-2", "task-3"]);
    await writeFile(join(f.directory, (await readdir(f.directory)).find(name => name.endsWith("-task-3.json"))!), "{}", { mode: 0o600 });
    await expect(listed(f.store)).rejects.toMatchObject({ code: "invalid-record" });
  });

  it("fences uncertainty from the setup marker at the same publication owner", async () => {
    const f = await fixture();
    const mark = f.workspace.markFeatureInitialized.bind(f.workspace);
    f.workspace.markFeatureInitialized = async feature => {
      await mark(feature);
      throw Object.assign(new Error("setup marker publication error"), { publicationVisible: true });
    };
    await expect(f.store.initialize()).rejects.toMatchObject({ code: "publication-uncertain" });
    await expect(f.store.put(task(), null)).rejects.toMatchObject({ code: "publication-uncertain" });
    await new HomeTaskStore(f.root, f.workspace).put(task(), null);
  });

  it("preserves pre-rename failures, fences visible uncertain publication, and reloads with a new owner", async () => {
    const f = await fixture();
    await f.store.initialize();
    await f.store.put(task(), null);
    const before = await readFile(await f.taskPath(), "utf8");
    const pre = new HomeTaskStore(f.root, f.workspace, { fileSystem: { mkdir, open, rm, rename: async () => { throw new Error("pre-rename"); } } });
    await expect(pre.put({ ...task(), revision: 2 }, 1)).rejects.toMatchObject({ code: "write-failed" });
    expect(await readFile(await f.taskPath(), "utf8")).toBe(before);
    expect(await readdir(f.directory)).toEqual(expect.arrayContaining(["authorization.json", basename(await f.taskPath())]));
    expect((await readdir(f.directory)).some(name => name.endsWith(".tmp"))).toBe(false);
    const uncertain = new HomeTaskStore(f.root, f.workspace, { fileSystem: {
      mkdir, rename, rm, open: async (...args: Parameters<typeof open>) => {
        if (args[0] === f.directory) throw new Error("directory fsync unavailable");
        return open(...args);
      },
    } });
    await expect(uncertain.put({ ...task(), revision: 2 }, 1)).rejects.toMatchObject({ code: "publication-uncertain" });
    await expect(uncertain.put({ ...task(), revision: 3 }, 2)).rejects.toMatchObject({ code: "publication-uncertain" });
    expect((await listed(new HomeTaskStore(f.root, f.workspace)))[0].revision).toBe(2);
  });
});

describe("Home task recency pages", () => {
  it("owns immutable creation time, updates in place and pages without newer arrivals", async () => {
    const f = await fixture(); await f.store.initialize();
    for (let i = 0; i < 6; i++) {
      await f.store.put({ ...task(), taskId: `page-${i}` }, null);
      await new Promise(resolve => setTimeout(resolve, 2));
    }
    const first = await f.store.page({ limit: 2 });
    expect(first.items.map(row => row.taskId)).toEqual(["page-5", "page-4"]);
    const original = (await f.store.read("page-5"))!;
    expect(original.createdAt).toBeGreaterThan(0);
    const name = (await readdir(f.directory)).find(name => name.endsWith("-page-5.json"))!;
    expect(name).toBe(`${String(original.createdAt).padStart(13, "0")}-page-5.json`);
    await f.store.put({ ...original, revision: 2, controllerGeneration: 1 }, 1);
    expect((await readdir(f.directory)).filter(name => name.endsWith("-page-5.json"))).toEqual([name]);
    expect(await f.store.read("page-5")).toMatchObject({ createdAt: original.createdAt, updatedAt: expect.any(Number), revision: 2 });
    const reopened = new HomeTaskStore(f.root, f.workspace);
    expect((await reopened.page({ limit: 2 })).items.map(row => row.taskId)).toEqual(["page-5", "page-4"]);
    await f.store.put({ ...task(), taskId: "newest" }, null);
    const second = await reopened.page({ limit: 2, cursor: first.nextCursor });
    const third = await reopened.page({ limit: 2, cursor: second.nextCursor });
    expect([...second.items, ...third.items].map(row => row.taskId)).toEqual(["page-3", "page-2", "page-1", "page-0"]);
    expect(third.nextCursor).toBeUndefined();
    expect((await reopened.page({ limit: 1 })).items[0].taskId).toBe("newest");
    expect(await reopened.read("page-0")).toMatchObject({ taskId: "page-0" });
    const snapshot = join(f.root, "copy"); await cp(f.directory, snapshot, { recursive: true });
    await rm(f.directory, { recursive: true }); await rename(snapshot, f.directory);
    await expect(reopened.page({ cursor: first.nextCursor })).rejects.toMatchObject({ code: "invalid-record" });
  });

  it("refuses duplicate suffixes and old layouts without changing evidence", async () => {
    const f = await fixture(); await f.store.initialize(); await f.store.put(task(), null);
    const record = (await f.store.read("task-1"))!;
    expect(record.createdAt).toBeGreaterThan(0);
    const name = (await readdir(f.directory)).find(name => name.endsWith("-task-1.json"))!;
    const original = await readFile(join(f.directory, name));
    const duplicate = join(f.directory, `${String(record.createdAt + 1).padStart(13, "0")}-task-1.json`);
    await writeFile(duplicate, original, { mode: 0o600 });
    await expect(f.store.read("task-1")).rejects.toMatchObject({ code: "invalid-record" });
    await expect(f.store.page({})).rejects.toMatchObject({ code: "invalid-record" });
    await rm(duplicate); const oldPath = join(f.directory, "task-1.json"); await rename(join(f.directory, name), oldPath);
    await expect(f.store.page({})).rejects.toMatchObject({ code: "invalid-record" });
    expect(await readFile(oldPath)).toEqual(original);
  });
});
