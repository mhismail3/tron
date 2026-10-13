import { createHash } from "node:crypto";
import { chmod, cp, lstat, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile, open, rename } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeTaskAuthorization, HomeTaskAuthorizationError } from "./home-task-authorization.js";
import { WakeInboxOwner } from "./home-wake-inbox.js";
import { HomeTaskStore, taskIntentDigest, type HomeTaskRecord, type HomeTaskWrite, type HomeTaskStoreDiagnostic } from "./home-task-store.js";
import { issueGrant } from "../../test-support/home-task-grant.js";

// Counts the task-directory files the store reads. The wrapper is transparent;
// only the cost cases below switch the counter on.
const fileReads = vi.hoisted(() => ({ active: false, tasks: 0, authority: 0 }));
vi.mock("../util/secure-json.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../util/secure-json.js")>();
  return {
    ...actual,
    readSecureJson: (async (path: string, maximumBytes: number) => {
      if (fileReads.active && path.includes("/gateway/home/tasks/")) {
        if (path.endsWith("/authorization.json")) fileReads.authority += 1;
        else fileReads.tasks += 1;
      }
      return actual.readSecureJson(path, maximumBytes);
    }) as typeof actual.readSecureJson,
  };
});

/** Seams over the directory scan and birth-time identity; the real filesystem
 * answers everything else. */
const fsSeam = vi.hoisted(() => ({ entriesVisited: 0, zeroBirthtimePaths: new Set<string>() }));
vi.mock("node:fs/promises", async importOriginal => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    opendir: async (...args: Parameters<typeof actual.opendir>) => {
      const directory = await actual.opendir(...args);
      return {
        async *[Symbol.asyncIterator]() {
          for await (const entry of directory) {
            fsSeam.entriesVisited++;
            yield entry;
          }
        },
      };
    },
    lstat: (async (path: string, options?: object) => {
      const info = await actual.lstat(path, options as never);
      if (!fsSeam.zeroBirthtimePaths.has(path)) return info;
      return Object.assign(Object.create(Object.getPrototypeOf(info)), info, { birthtimeNs: 0n });
    }) as typeof actual.lstat,
  };
});

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
  const intent = { text: "Investigate a trusted project" };
  return {
    version: 1, taskId: "task-1", revision: 1, homeId: "home-1", generation: 1, routeGeneration: 1,
    intent, intentDigest: taskIntentDigest(intent.text),
    target: "/trusted/project",
    grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null,
    stopIntent: null, spend: null, reportRef: null, terminalEvidence: null, wake: null,
  };
}

function authorization(store: HomeTaskStore) {
  return new HomeTaskAuthorization({
    store: store.authorization, now: () => 1_000,
    resolveTrustedTarget: async target => target === "/trusted/project" ? target : undefined,
  });
}
const request = { intentDigest: "digest", target: "/trusted/project", authorizationScope: "project-work", restoreEpoch: "epoch-1" };

async function bytes(directory: string): Promise<Record<string, string>> {
  const result: Record<string, string> = {};
  for (const name of (await readdir(directory)).sort()) result[name] = await readFile(join(directory, name), "utf8");
  return result;
}

async function collectRecords(store: HomeTaskStore): Promise<HomeTaskRecord[]> {
  const records: HomeTaskRecord[] = [];
  for await (const record of store.records()) records.push(record);
  return records;
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
    await f.store.put({ ...task(), revision: 2 }, 1);
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
    expect(await collectRecords(f.store)).toMatchObject([task()]);
    const before = await bytes(f.directory);
    await f.store.initialize();
    expect(await bytes(f.directory)).toEqual(before);
  });

  it("serializes expected-revision replacements and preserves immutable identity/intent across restart", async () => {
    const f = await fixture();
    await f.store.initialize();
    await f.store.put(task(), null);
    const next = { ...task(), revision: 2 };
    const results = await Promise.allSettled([f.store.put(next, 1), f.store.put(structuredClone(next), 1)]);
    expect(results.filter(result => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter(result => result.status === "rejected")).toHaveLength(1);
    const restarted = new HomeTaskStore(f.root, f.workspace);
    expect(await collectRecords(restarted)).toMatchObject([next]);
    const before = await readFile(await f.taskPath(), "utf8");
    const changedIntent = { text: "Changed intent" };
    await expect(restarted.put({ ...next, revision: 3, intent: changedIntent,
      intentDigest: taskIntentDigest(changedIntent.text) }, 2)).rejects.toMatchObject({ code: "invalid-record" });
    await expect(restarted.put({ ...next, revision: 2 }, 2)).rejects.toMatchObject({ code: "revision-conflict" });
    expect(await readFile(await f.taskPath(), "utf8")).toBe(before);
  });

  it("persists scopes, unused and consumed grants and revision fencing on restart; restore epoch is not startup", async () => {
    const f = await fixture();
    await f.store.initialize();
    const owner = authorization(f.store);
    const scope = await owner.enableInitialScope("epoch-1");
    // Only reconfirmation renews a standing scope: a second initial scope is refused by the store, never swapped in.
    await expect(owner.enableInitialScope("epoch-2")).rejects.toMatchObject({ code: "invalid-record" });
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
    expect((await collectRecords(f.store))[0].scopeRef).toBe("scope-1");
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
      { ...task(), reportRef: { resultId: "result-1", sessionId: "session-1", entryId: "entry-1", digest: "a".repeat(64), surprise: true } },
      { ...task(), reportRef: [{ resultId: "result-1", sessionId: "session-1", entryId: "entry-1", digest: "a".repeat(64) }] },
      { ...task(), spend: { sourceDigest: "a".repeat(64), inputTokens: -1, outputTokens: 0 } },
      { ...task(), spend: { sourceDigest: "a".repeat(64), inputTokens: 1, outputTokens: 0, unpriced: true } },
    ];
    for (const record of invalid) await expect(f.store.put(record as HomeTaskRecord, null)).rejects.toMatchObject({ code: "invalid-record" });
    expect(await bytes(f.directory)).toEqual(before);
  });

  // FM7: a final result is only a result with its one report reference; the rest of
  // the record is valid, so the reference is the only thing refused.
  it("refuses a final terminal result without its single report reference", async () => {
    const f = await fixture(); await f.store.initialize();
    const final = { ...terminalTask("task-final"), terminalEvidence: { outcome: "final" as const, sessionId: "session-1", entryIds: ["entry-1"], reason: "explicit-report" } };
    await expect(f.store.put(final, null)).rejects.toMatchObject({ code: "invalid-record" });
    const reportRef = { resultId: "result-1", sessionId: "session-1", entryId: "entry-1", digest: "a".repeat(64) };
    await expect(f.store.put({ ...final, reportRef }, null)).resolves.toMatchObject({ lifecycle: "terminal", reportRef });
  });

  it("refuses a wake state the inbox no longer writes, so no record can carry it", async () => {
    const f = await fixture(); await f.store.initialize();
    const terminal = terminalTask("task-terminal");
    await expect(f.store.put({ ...terminal, wake: { ...terminal.wake!, state: "cancelled-before-admission" as never } }, null))
      .rejects.toMatchObject({ code: "invalid-record" });
    expect(await f.store.read("task-terminal")).toBeUndefined();
  });

  // FM1/FM2/FM6: a deleted field is refused on both paths, never read as current.
  it("refuses a task record that carries a deleted field, on write and on read", async () => {
    const f = await fixture(); await f.store.initialize();
    await f.store.put(task(), null);
    const path = await f.taskPath();
    const valid = await readFile(path, "utf8");
    const current = JSON.parse(valid) as Record<string, unknown>;
    const deleted = {
      workerProfile: { workerProfile: "home-task-v1" },
      policyRevision: { policyRevision: 1 },
      controllerGeneration: { controllerGeneration: null },
      "intent.revision": { intent: { revision: 1, text: task().intent.text } },
    } as const;
    for (const [name, extra] of Object.entries(deleted)) {
      await expect(f.store.put({ ...task(), revision: 2, ...extra } as HomeTaskWrite, 1), `put ${name}`).rejects.toMatchObject({ code: "invalid-record" });
      await writeFile(path, JSON.stringify({ ...current, ...extra }), { mode: 0o600 });
      await expect(collectRecords(f.store), `read ${name}`).rejects.toMatchObject({ code: "invalid-record" });
    }
    // The positive control: the unmodified current-shape record still reads.
    await writeFile(path, valid, { mode: 0o600 });
    expect(await collectRecords(f.store)).toHaveLength(1);
  });

  it("refuses an authorization request or grant that carries a deleted binding field", async () => {
    const f = await fixture(); await f.store.initialize();
    const epoch = await f.store.restoreEpoch();
    await issueGrant(authorization(f.store), { ...request, restoreEpoch: epoch }, { decisionId: "decision-1", expiresAt: 2_000 });
    const valid = await readFile(f.authPath, "utf8");
    const current = JSON.parse(valid) as { requests: Array<{ request: Record<string, unknown> }>; grants: Array<Record<string, unknown>> };
    const deleted = ["workerProfile", "policyRevision", "intentRevision"] as const;
    for (const field of deleted) {
      const badRequest = { ...current, requests: current.requests.map(pending => ({ ...pending, request: { ...pending.request, [field]: 1 } })) };
      await writeFile(f.authPath, JSON.stringify(badRequest), { mode: 0o600 });
      await expect(f.store.authorization.load(), `request ${field}`).rejects.toMatchObject({ code: "invalid-record" });
      const badGrant = { ...current, grants: current.grants.map(candidate => ({ ...candidate, [field]: 1 })) };
      await writeFile(f.authPath, JSON.stringify(badGrant), { mode: 0o600 });
      await expect(f.store.authorization.load(), `grant ${field}`).rejects.toMatchObject({ code: "invalid-record" });
    }
    await writeFile(f.authPath, valid, { mode: 0o600 });
    expect(await f.store.authorization.load()).toMatchObject({ grants: [{ decisionId: "decision-1" }] });
  });

  it("lists pendingGrant only for the undecided request matching the task's intent digest and target", async () => {
    const f = await fixture(); await f.store.initialize();
    const epoch = await f.store.restoreEpoch();
    const owner = authorization(f.store);
    await f.store.put(task(), null);
    const other = { ...task(), taskId: "task-2", intent: { text: "A different intent" }, intentDigest: taskIntentDigest("A different intent") };
    await f.store.put(other, null);
    // Same intent digest as the requested task, different target: the target dimension alone must exclude it.
    await f.store.put({ ...task(), taskId: "task-3", target: "/trusted/other" }, null);
    const binding = { intentDigest: task().intentDigest, target: "/trusted/project", authorizationScope: "full-work", restoreEpoch: epoch };
    const refused = await owner.authorize(binding).then(() => { throw new Error("authorized without a grant"); },
      error => error as HomeTaskAuthorizationError);
    expect(refused).toMatchObject({ code: "grant-required" });
    const rows = async () => Object.fromEntries((await f.store.page({})).items.map(row => [row.taskId, row.pendingGrant]));
    expect(await rows()).toEqual({ "task-1": true, "task-2": false, "task-3": false });
    await owner.recordDecisionAndGrant(refused.requestId!, { decisionId: "decision-1", approved: false, expiresAt: 2_000, restoreEpoch: epoch });
    expect(await rows()).toEqual({ "task-1": false, "task-2": false, "task-3": false });
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
        await expect(collectRecords(f.store)).rejects.toBeDefined();
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
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "unsafe-state" });
    expect(await readFile(target, "utf8")).toBe(before);
    await rm(taskPath);
    await rename(target, taskPath);
    const unknown = join(f.directory, "unexpected.json");
    await writeFile(unknown, "{}", { mode: 0o600 });
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await rm(unknown);
    const saved = join(f.root, "saved-tasks");
    await rename(f.directory, saved);
    await symlink(saved, f.directory);
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "unsafe-state" });
    expect(await readFile(join(saved, basename(taskPath)), "utf8")).toBe(before);
  });

  it("rejects invalid task identity/digest and duplicate authorization identities/references", async () => {
    const f = await fixture();
    await f.store.initialize();
    await f.store.put(task(), null);
    const before = await readFile(await f.taskPath(), "utf8");
    await writeFile(await f.taskPath(), JSON.stringify({ ...task(), taskId: "different-id" }));
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await writeFile(await f.taskPath(), JSON.stringify({ ...task(), intentDigest: "0".repeat(64) }));
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
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
      await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
      expect(await readFile(f.authPath, "utf8")).toBe(raw);
    }
  });

  it("streams and validates every entry without a task-count cap", async () => {
    const f = await fixture();
    await f.store.initialize();
    for (let index = 1; index <= 3; index++) await f.store.put({ ...task(), taskId: `task-${index}` }, null);
    expect((await collectRecords(f.store)).map(record => record.taskId).sort()).toEqual(["task-1", "task-2", "task-3"]);
    await writeFile(join(f.directory, (await readdir(f.directory)).find(name => name.endsWith("-task-3.json"))!), "{}", { mode: 0o600 });
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
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
    expect((await collectRecords(new HomeTaskStore(f.root, f.workspace)))[0].revision).toBe(2);
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
    await f.store.put({ ...original, revision: 2 }, 1);
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

  it("reads each directory entry once per operation, not one directory scan per task", async () => {
    const f = await fixture(); await f.store.initialize(); await f.store.put(task(), null);
    const template = (await f.store.read("task-1"))!;
    for (let index = 0; index < 300; index++) {
      const createdAt = template.createdAt + 1 + index;
      const record = { ...template, taskId: `bulk-${index}`, createdAt, updatedAt: createdAt };
      await writeFile(join(f.directory, `${String(createdAt).padStart(13, "0")}-bulk-${index}.json`), `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
    }
    const entries = (await readdir(f.directory)).length;
    const visitsOf = async (operation: () => Promise<unknown>): Promise<number> => {
      fsSeam.entriesVisited = 0;
      await operation();
      return fsSeam.entriesVisited;
    };
    // A single pass visits every entry; two passes (validation plus enumeration) is the ceiling.
    for (const [name, operation] of [
      ["records", () => collectRecords(f.store)],
      ["page", () => f.store.page({ limit: 50 })],
      ["read", () => f.store.read("bulk-150")],
    ] as const) {
      const visits = await visitsOf(operation);
      expect(visits, name).toBeGreaterThanOrEqual(entries);
      expect(visits, name).toBeLessThanOrEqual(2 * entries);
    }
  });

  it("refuses a task directory without birth time in page, as restoreEpoch does", async () => {
    const f = await fixture(); await f.store.initialize(); await f.store.put(task(), null);
    fsSeam.zeroBirthtimePaths.add(f.directory);
    try {
      await expect(f.store.restoreEpoch()).rejects.toMatchObject({ code: "unsafe-state" });
      await expect(f.store.page({})).rejects.toMatchObject({ code: "unsafe-state" });
    } finally { fsSeam.zeroBirthtimePaths.delete(f.directory); }
    expect((await f.store.page({})).items.map(row => row.taskId)).toEqual(["task-1"]);
  });

  it("refuses two individually valid files for one task identity in every enumeration", async () => {
    const f = await fixture(); await f.store.initialize(); await f.store.put(task(), null);
    const record = (await f.store.read("task-1"))!;
    const createdAt = record.createdAt + 1;
    const second = { ...record, createdAt, updatedAt: createdAt };
    await writeFile(join(f.directory, `${String(createdAt).padStart(13, "0")}-task-1.json`), JSON.stringify(second, null, 2), { mode: 0o600 });
    await expect(f.store.read("task-1")).rejects.toMatchObject({ code: "invalid-record" });
    await expect(f.store.page({})).rejects.toMatchObject({ code: "invalid-record" });
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await expect(f.store.put({ ...record, revision: 2 }, 1)).rejects.toMatchObject({ code: "invalid-record" });
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
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await expect(collectRecords(f.store)).rejects.toMatchObject({ code: "invalid-record" });
    await rm(duplicate); const oldPath = join(f.directory, "task-1.json"); await rename(join(f.directory, name), oldPath);
    await expect(f.store.page({})).rejects.toMatchObject({ code: "invalid-record" });
    expect(await readFile(oldPath)).toEqual(original);
  });
});

describe("HomeTaskStore staged publications", () => {
  // A crash between the temporary write and its rename leaves this name behind.
  const leftover = (name: string) => `${name}.4242.0123456789ab.tmp`;

  it("skips a crash-leftover temporary in every enumeration and removes it only at recovery", async () => {
    const f = await fixture(); await f.store.initialize();
    await f.store.put(task(), null);
    const record = (await f.store.read("task-1"))!;
    const taskTemporary = join(f.directory, leftover(`${String(record.createdAt + 1).padStart(13, "0")}-task-2.json`));
    const authorizationTemporary = join(f.directory, leftover("authorization.json"));
    await writeFile(taskTemporary, "{\"partial\":", { mode: 0o600 });
    await writeFile(authorizationTemporary, "{", { mode: 0o600 });
    expect((await collectRecords(f.store)).map(row => row.taskId)).toEqual(["task-1"]);
    expect((await f.store.page({})).items.map(row => row.taskId)).toEqual(["task-1"]);
    expect(await f.store.read("task-1")).toMatchObject({ taskId: "task-1" });
    const streamed: string[] = [];
    for await (const row of f.store.records()) streamed.push(row.taskId);
    expect(streamed).toEqual(["task-1"]);
    await f.store.put({ ...task(), taskId: "task-3" }, null);
    expect(await readFile(taskTemporary, "utf8")).toBe("{\"partial\":");
    await f.store.removeAbandonedTemporaries();
    expect((await readdir(f.directory)).filter(name => name.endsWith(".tmp"))).toEqual([]);
    expect((await collectRecords(f.store)).map(row => row.taskId).sort()).toEqual(["task-1", "task-3"]);
  });

  it("refuses recovery for a staged name that is not this user's regular file, and removes nothing", async () => {
    const f = await fixture(); await f.store.initialize();
    await f.store.put(task(), null);
    const outside = join(f.root, "outside.json");
    await writeFile(outside, "{}", { mode: 0o600 });
    const linked = join(f.directory, leftover("authorization.json"));
    await symlink(outside, linked);
    await expect(f.store.removeAbandonedTemporaries()).rejects.toMatchObject({ code: "unsafe-state" });
    expect(await readFile(outside, "utf8")).toBe("{}");
    expect((await lstat(linked)).isSymbolicLink()).toBe(true);
  });
});

function terminalTask(taskId: string): HomeTaskWrite {
  return { ...task(), taskId, lifecycle: "terminal", revision: 1, terminalEvidence: { outcome: "unknown", sessionId: null, entryIds: [], reason: "cold-no-report" },
    wake: { eventId: `task-result-${createHash("sha256").update(taskId).digest("hex")}`, routeGeneration: 1, createdAt: new Date(1_000).toISOString(),
      state: "pending", push: "pending", delivery: null, acknowledgedAt: null, redeliveries: [] } };
}

async function fileReadsDuring(operation: () => Promise<unknown>): Promise<{ tasks: number; authority: number }> {
  fileReads.tasks = 0; fileReads.authority = 0; fileReads.active = true;
  try { await operation(); } finally { fileReads.active = false; }
  return { tasks: fileReads.tasks, authority: fileReads.authority };
}

describe("HomeTaskStore operation cost", () => {
  it("reads only the target record and authority for each by-ID operation, at any task count", async () => {
    const f = await fixture(); await f.store.initialize();
    await f.store.put(task(), null);
    await f.store.put(terminalTask("task-terminal"), null);
    let tokens = 0;
    const byIdCosts = async () => {
      const current = (await f.store.read("task-1"))!;
      const { createdAt: _createdAt, updatedAt: _updatedAt, ...write } = current;
      const state = await f.store.authorization.load();
      return {
        read: await fileReadsDuring(() => f.store.read("task-1")),
        put: await fileReadsDuring(() => f.store.put({ ...write, revision: current.revision + 1 }, current.revision)),
        update: await fileReadsDuring(() => f.store.update("task-1", record => ({ ...record,
          spend: { sourceDigest: "a".repeat(64), inputTokens: ++tokens, outputTokens: 0 } }))),
        updateWake: await fileReadsDuring(() => f.store.updateWake("task-terminal", wake => ({ ...wake, push: "decided" }))),
        authorityLoad: await fileReadsDuring(() => f.store.authorization.load()),
        authoritySave: await fileReadsDuring(() => f.store.authorization.save(state)),
      };
    };
    const small = await byIdCosts();
    for (let index = 2; index <= 299; index++) await f.store.put({ ...task(), taskId: `task-${index}` }, null);
    const large = await byIdCosts();
    expect(small.read).toEqual({ tasks: 1, authority: 1 });
    expect(large).toEqual(small);
  }, 60_000);

  it("reads authorization once per full scan, not once per record", async () => {
    const f = await fixture(); await f.store.initialize();
    for (let index = 1; index <= 300; index++) await f.store.put({ ...task(), taskId: `task-${index}` }, null);
    const cost = await fileReadsDuring(async () => { for await (const _record of f.store.records()) { /* drain */ } });
    expect(cost.authority).toBe(1);
  }, 60_000);

  it("yields a record that cites authority published after the scan's authority read", async () => {
    const f = await fixture(); await f.store.initialize();
    await f.store.put({ ...task(), taskId: "task-a" }, null);
    await f.store.put({ ...task(), taskId: "task-b" }, null);
    const stream = f.store.records();
    try {
      const first = (await stream.next()).value as HomeTaskRecord;
      const other = first.taskId === "task-a" ? "task-b" : "task-a";
      const grant = await issueGrant(authorization(f.store), request, { decisionId: "decision-1", expiresAt: 2_000 });
      const current = (await f.store.read(other))!;
      const { createdAt: _createdAt, updatedAt: _updatedAt, ...write } = current;
      await f.store.put({ ...write, revision: current.revision + 1, grantRef: grant.id }, current.revision);
      const second = await stream.next();
      expect(second.value).toMatchObject({ taskId: other, grantRef: grant.id });
    } finally { await stream.return(undefined); }
  });

  it("refuses an authority save that removes a scope a task references", async () => {
    const f = await fixture(); await f.store.initialize();
    const scope = await authorization(f.store).enableInitialScope("epoch-1");
    await f.store.put({ ...task(), scopeRef: scope.id }, null);
    const before = await readFile(f.authPath, "utf8");
    const state = await f.store.authorization.load();
    await expect(f.store.authorization.save({ ...state, scopes: [] })).rejects.toMatchObject({ code: "invalid-record" });
    expect(await readFile(f.authPath, "utf8")).toBe(before);
  });
});
