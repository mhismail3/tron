import { TEST_SETTINGS_SCHEMA } from "../../../test-support/settings-schema.js";
import { displayOwnerOf, createTestRegistry } from "../../../test-support/gateway-registry.js";
import { generateKeyPairSync } from "node:crypto";
import { MacTerminalKeys } from "../../security/mac-terminal.js";
import { MacTerminalService } from "../../security/mac-terminal-service.js";
import { execFileSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { SettingsStoreAdapter } from "../../admin/settings-model.js";
import { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import { SettingsModel } from "../../kernel/settings/settings-model.js";
import { SettingsChangeRecord, type ChangeEntry } from "../../kernel/settings/settings-record.js";
import { maintainerChange } from "../../../test-support/native-change.js";
import { OutsideChanges } from "../../admin/settings-outside.js";
import { McpAdminService } from "../../admin/mcp-admin-service.js";
import { ModelConfigService } from "../../admin/model-config-service.js";
import { type SettingsStores } from "../../kernel/settings/settings-types.js";
import { composedBelow, readBinding } from "../../kernel/settings/settings-resolver.js";
import { type Resolution } from "../../kernel/settings/tool-contract.js";
import { type KeyDeclaration } from "../../kernel/settings/settings-schema.js";
const { KEYS } = TEST_SETTINGS_SCHEMA;
import type { PresentedResolution } from "../../admin/settings-presentation.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { waitFor } from "../../../test-support/wait-for.js";
const ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../../test-results/settings-change.json");
const EVERY_KEY_ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../../test-results/settings-every-key.json");
const transcript: Array<{ case: string; detail: unknown }> = [];
type CaseOwner = {
  bodies: Array<Promise<void>>;
  roots: string[];
  registries: RuntimeRegistry[];
  outsides: OutsideChanges[];
};
let testOwners: CaseOwner[] = [];
function newCaseOwner(): CaseOwner {
  const owner: CaseOwner = { bodies: [], roots: [], registries: [], outsides: [] };
  testOwners.push(owner);
  return owner;
}
function ownCase(owner: CaseOwner, body: () => Promise<void>): Promise<void> {
  const running = body();
  owner.bodies.push(running);
  return running;
}
async function watcherDelivers(outside: OutsideChanges, agentDir: string): Promise<void> {
  const settings = join(agentDir, "settings.json");
  const bytes = await readFile(settings);
  let rescans = 0;
  const reconcile = outside.reconcile;
  outside.reconcile = (...args) => {
    const work = reconcile.apply(outside, args);
    void work.then(() => { rescans += 1; }, () => { rescans += 1; });
    return work;
  };
  try {
    await waitFor(async () => {
      await writeFile(settings, bytes);
      await new Promise(resolve => setTimeout(resolve, 400));
      return rescans > 0;
    }, "the settings directory watcher delivers an event", { intervalMs: 0 });
  } finally {
    delete (outside as { reconcile?: unknown }).reconcile;
  }
}
const caseIt = (name: string, body: (owner: CaseOwner) => Promise<void>) => it(name, () => {
  testOwners = [];
  const owner = newCaseOwner();
  return ownCase(owner, () => body(owner));
});
const caseEach = (values: string[]) => (name: string, body: (value: string, owner: CaseOwner) => Promise<void>, timeout: number) =>
  it.each(values)(name, value => {
    testOwners = [];
    const owner = newCaseOwner();
    return ownCase(owner, () => body(value, owner));
  }, timeout);
async function disposeCase(owner: CaseOwner): Promise<void> {
  const failures: unknown[] = [];
  let kept: string[] = [];
  try {
    for (const settled of await Promise.allSettled(owner.bodies.splice(0))) {
      if (settled.status === "rejected") failures.push(settled.reason);
    }
    const roots = owner.roots.splice(0);
    const disposals = await Promise.allSettled([
      ...owner.outsides.splice(0).map(outside => Promise.resolve().then(() => outside.dispose())),
      ...owner.registries.splice(0).map(registry => registry.dispose()),
    ]);
    const disposalFailures = disposals.flatMap(settled => settled.status === "rejected" ? [settled.reason] : []);
    failures.push(...disposalFailures);
    if (disposalFailures.length > 0) {
      kept = roots;
    } else {
      for (const settled of await Promise.allSettled(roots.map(root => rm(root, { recursive: true, force: true })))) {
        if (settled.status === "rejected") failures.push(settled.reason);
      }
    }
  } finally {
    await mkdir(dirname(ARTIFACT), { recursive: true });
    await writeFile(ARTIFACT, `${JSON.stringify(transcript, null, 2)}\n`);
  }
  if (failures.length > 0) throw new AggregateError(failures, `settings-change case teardown failed${kept.length > 0 ? `; fixture roots kept: ${kept.join(", ")}` : ""}`);
}
afterEach(async () => {
  const failures: unknown[] = [];
  for (const owner of testOwners.splice(0)) await disposeCase(owner).catch((failure: unknown) => { failures.push(failure); });
  if (failures.length === 1) throw failures[0];
  if (failures.length > 1) throw new AggregateError(failures, "settings-change case teardowns failed");
});
function observeJoin(body: Promise<void>, onJoin: () => void): void {
  const then = body.then;
  Object.defineProperty(body, "then", { value: function (this: Promise<void>, ...args: unknown[]) { onJoin(); return Reflect.apply(then, this, args); } });
}
function holdChild() {
  const held = spawn(process.execPath, ["-e", "process.stdin.resume()"], { stdio: ["pipe", "ignore", "ignore"] });
  return { held, exited: once(held, "exit") };
}
async function releaseChild({ held, exited }: ReturnType<typeof holdChild>): Promise<void> {
  held.stdin.end();
  if (held.exitCode === null && held.signalCode === null) held.kill();
  await exited;
}
const outcomeOf = (teardown: Promise<void>) => teardown.then(() => undefined, (error: unknown) => ({ error }));

describe("settings-change fixture teardown", () => {
  caseIt("joins an in-flight case body before it removes the fixture root", async () => {
    const owned = newCaseOwner();
    const f = await fixture(owned);
    const child = holdChild();
    let joinEntered = (): void => {};
    const joining = new Promise<string>(resolve => { joinEntered = () => resolve("join entered"); });
    let teardown: ReturnType<typeof outcomeOf> | undefined;
    try {
      observeJoin(ownCase(owned, async () => {
        await child.exited;
        await writeFile(join(f.root, "late-write"), "written after teardown began\n");
      }), joinEntered);
      teardown = outcomeOf(disposeCase(owned));
      expect(await Promise.race([joining, teardown.then(() => "teardown finished")])).toBe("join entered");
      expect(existsSync(f.root)).toBe(true);
      child.held.stdin.end();
      expect(await teardown).toBeUndefined();
      expect(existsSync(f.root)).toBe(false);
    } finally {
      await releaseChild(child);
      await teardown;
    }
  });

  caseIt("removes a failed body's root once it settles, and reports that body's own failure", async () => {
    const owned = newCaseOwner();
    const f = await fixture(owned);
    const cause = new Error("body failed after writing");
    ownCase(owned, async () => {
      await writeFile(join(f.root, "partial"), "written before the failure\n");
      throw cause;
    });
    const error = await disposeCase(owned).then(() => undefined, (caught: unknown) => caught);
    expect(error).toBeInstanceOf(AggregateError);
    expect((error as AggregateError).errors).toHaveLength(1);
    expect((error as AggregateError).errors[0]).toBe(cause);
    expect(existsSync(f.root)).toBe(false);
  });

  caseIt("keeps and names a root whose registry cannot shut down, then removes it once the registry is disposed", async () => {
    const owned = newCaseOwner();
    const f = await fixture(owned);
    const cwd = join(f.root, "chat");
    await mkdir(cwd);
    await f.trust.set(cwd, true);
    const slot = await f.registry.create(cwd);
    const marker = join(f.tronHome, "gateway", "runtime-markers", `${slot.id}.json`);
    await mkdir(join(marker, "blocker"), { recursive: true });
    try {
      const error = await disposeCase(owned).then(() => undefined, (caught: unknown) => caught);
      expect(error).toBeInstanceOf(AggregateError);
      expect((error as AggregateError).message).toBe(`settings-change case teardown failed; fixture roots kept: ${f.root}`);
      const [registryFailure] = (error as AggregateError).errors as AggregateError[];
      expect(registryFailure).toBeInstanceOf(AggregateError);
      expect(registryFailure!.message).toBe("One or more session runtimes failed to shut down");
      expect(registryFailure!.errors[0]).toMatchObject({ code: "ERR_FS_EISDIR" });
      expect(existsSync(f.root)).toBe(true);
    } finally {
      await rm(marker, { recursive: true, force: true });
      await f.registry.dispose();
      await rm(f.root, { recursive: true, force: true });
    }
  });

  caseIt("a teardown removes only its own case's roots, including one its body registers after teardown began", async () => {
    const inFlight = newCaseOwner();
    const later = newCaseOwner();
    const child = holdChild();
    let lateRoot: string | undefined;
    let teardown: ReturnType<typeof outcomeOf> | undefined;
    try {
      const f = await fixture(inFlight);
      ownCase(inFlight, async () => {
        await child.exited;
        const late = await fixture(inFlight);
        lateRoot = late.root;
        await writeFile(join(late.root, "late-write"), "written after teardown began\n");
      });
      teardown = outcomeOf(disposeCase(inFlight));
      const sibling = await fixture(later);
      child.held.stdin.end();
      expect(await teardown).toBeUndefined();
      expect(lateRoot).toBeDefined();
      expect(existsSync(f.root)).toBe(false);
      expect(existsSync(lateRoot!)).toBe(false);
      expect(existsSync(sibling.root)).toBe(true);
      await disposeCase(later);
      expect(existsSync(sibling.root)).toBe(false);
    } finally {
      await releaseChild(child);
      await teardown;
    }
  });
});

function outsideLatch() {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}

describe("outside settings retirement", () => {
  caseIt("joins a file-watch reconciliation through its observer before retiring", async owner => {
    const f = await fixture(owner);
    const reading = outsideLatch(), reader = outsideLatch(), publishing = outsideLatch(), observer = outsideLatch(), finished = outsideLatch();
    let hold = false, disposed = false;
    const errors: unknown[] = [];
    const outside = new OutsideChanges(TEST_SETTINGS_SCHEMA, f.tronHome, f.agentDir, f.record, {
      ...f.settingsModel.owner.observedReaders,
      global: async () => {
        const values = await f.settingsModel.owner.observedReaders.global();
        if (hold) { reading.release(); await reader.promise; }
        return values;
      },
    });
    owner.outsides.push(outside);
    await outside.reconcile([{ kind: "global" }]);
    outside.observe({ outside: async () => {
      publishing.release();
      try {
        await observer.promise;
        await outside.reconcile([{ kind: "global" }]);
        await writeFile(join(f.root, "published"), "settled\n");
      }
      finally { finished.release(); }
    } });
    outside.startWatching(error => { errors.push(error); finished.release(); });
    await watcherDelivers(outside, f.agentDir);
    hold = true;
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ retry: { maxRetries: 8 } }));
    await reading.promise;
    const closing = Promise.resolve(outside.dispose()).then(() => { disposed = true; });
    try {
      await writeFile(join(f.root, "retirement-probe"), "reader held\n");
      expect(disposed, "retirement cannot precede the accepted file read").toBe(false);
      reader.release();
      await publishing.promise;
      await readFile(join(f.root, "retirement-probe"));
      expect(disposed, "joining the mutex alone does not join observer publication").toBe(false);
      observer.release();
      await closing;
      expect(await readFile(join(f.root, "published"), "utf8")).toBe("settled\n");
      const observed = await readFile(outside.path, "utf8");
      const history = await f.history();
      expect(history.some(entry => entry.status === "outside" && entry.key === "run.retry.maxRetries")).toBe(true);
      await expect(outside.reconcile([{ kind: "global" }])).rejects.toThrow(/disposed/);
      expect(await readFile(outside.path, "utf8")).toBe(observed);
      expect(errors).toEqual([]);
      transcript.push({ case: "outside retirement", detail: { fileWatch: true, readerJoined: true, observerJoined: true, lateAdmissionRefused: true } });
    } finally {
      reader.release(); observer.release();
      await finished.promise;
      await closing;
    }
  });

  caseIt("joins a failing observer and preserves its filesystem error", async owner => {
    const f = await fixture(owner);
    const publishing = outsideLatch(), observer = outsideLatch(), publishingSecond = outsideLatch(), secondObserver = outsideLatch();
    let calls = 0, disposed = false;
    const outside = new OutsideChanges(TEST_SETTINGS_SCHEMA, f.tronHome, f.agentDir, f.record, f.settingsModel.owner.observedReaders);
    owner.outsides.push(outside);
    await outside.reconcile([{ kind: "global" }]);
    const destination = join(f.root, "observer-destination");
    await mkdir(destination);
    outside.observe({ outside: async () => {
      if (++calls === 1) {
        publishing.release(); await observer.promise;
        await writeFile(destination, "cannot replace a directory\n");
      } else {
        publishingSecond.release(); await secondObserver.promise;
        await writeFile(join(f.root, "second-observer"), "settled\n");
      }
    } });
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ retry: { maxRetries: 8 } }));
    const work = outside.reconcile([{ kind: "global" }]);
    const operation = work.then(() => undefined, (error: unknown) => error);
    await publishing.promise;
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ retry: { maxRetries: 9 } }));
    const secondWork = outside.reconcile([{ kind: "global" }]);
    await publishingSecond.promise;
    const closing = Promise.resolve(outside.dispose()).then(() => { disposed = true; }, (error: unknown) => { disposed = true; return error; });
    try {
      observer.release();
      const error = await operation;
      expect(error).toMatchObject({ code: "EISDIR" });
      await readFile(join(f.agentDir, "settings.json"));
      expect(disposed, "one failure cannot retire another accepted observer").toBe(false);
      secondObserver.release();
      await secondWork;
      const disposal = await closing;
      expect(disposal).toBeInstanceOf(AggregateError);
      expect((disposal as AggregateError).errors).toEqual([error]);
      transcript.push({ case: "outside retirement error", detail: { code: "EISDIR", originalCausePreserved: true } });
    } finally {
      observer.release(); secondObserver.release(); await operation; await secondWork; await closing;
      owner.outsides.splice(owner.outsides.indexOf(outside), 1);
    }
  });
});

const GIT_ENV = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid" };
const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, stdio: "pipe", env: GIT_ENV }).toString();

const ENROLLED_IPHONE = "00000000-0000-4000-8000-000000000001";

function macTerminalSampleKey(): string {
  const point = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({ format: "der", type: "spki" }).subarray(-65);
  const field = (value: Buffer) => { const length = Buffer.alloc(4); length.writeUInt32BE(value.length); return Buffer.concat([length, value]); };
  return `ecdsa-sha2-nistp256 ${Buffer.concat([field(Buffer.from("ecdsa-sha2-nistp256")), field(Buffer.from("nistp256")), field(point)]).toString("base64")}`;
}

function client(sessionIds: string[] = []): ClientContext {
  return { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: (id: string) => sessionIds.includes(id), isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
}

let command = 0;
const commandId = () => `settings-change-${String(++command).padStart(4, "0")}`;

async function fixture(owner: CaseOwner, options: { segmentEntries?: number } = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-change-"));
  owner.roots.push(root);
  const tronHome = join(root, "tron");
  const agentDir = join(tronHome, "agent");
  const sessionDir = join(root, "sessions");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
  const faux = fauxProvider({ provider: "tron-settings-change", tokensPerSecond: 10_000, models: [{ id: "first", reasoning: true }, { id: "second", reasoning: true }] });
  const runtimeFactory = async () => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    return runtime;
  };
  const modelRuntime = await runtimeFactory();
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir, retry: { maxRetries: 4 } }));
  const trust = new TrustService(agentDir);
  const registry = await createTestRegistry({ agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: runtimeFactory, trust,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  owner.registries.push(registry);
  await registry.initialize();
  const privateService = new MacTerminalService(tronHome, { launchAgentDirectory: join(root, "agents") });
  const macTerminalKeys = new MacTerminalKeys(privateService.root);
  const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome, trust, modelRuntime, macTerminalKeys: privateService }));
  const record = new SettingsChangeRecord(tronHome, options.segmentEntries);
  const outside = new OutsideChanges(TEST_SETTINGS_SCHEMA, tronHome, agentDir, record, settingsModel.owner.observedReaders);
  settingsModel.owner.observeOutside(outside);
  owner.outsides.push(outside);
  const settingsChanges = new SettingsChangePath(settingsModel, record, {
    setTrust: async (project, decision) => {
      return trust.setAndApply(project, decision,
        async inspection => { await registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false); },
        async inspection => { await registry.commitProjectReload(inspection.projectDir); },
        async inspection => { await registry.abortProjectReload(inspection.projectDir); });
    },
  });
  registry.setSettings(settingsModel, settingsChanges);
  const broadcasts: Array<{ topic: string; payload: unknown }> = [];
  const pushes: Array<{ sourceId: string; title: string; message: string }> = [];
  const notifications = { enqueue: async (push: { sourceId: string; title: string; message: string }) => { pushes.push(push); } };
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime, trust, settingsModel, settingsChanges, sessions: registry, receipts: new CommandReceiptStore(tronHome), notifications,
    broadcast: (topic: string, payload: unknown) => broadcasts.push({ topic, payload }),
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
    mcpAdmin: new McpAdminService(agentDir, join(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))), "bundle/cli.js")),
    modelConfig: new ModelConfigService(agentDir),
  } as unknown as GatewayServiceDependencies);
  const change = (target: Record<string, unknown>, changes: unknown[], extra: Record<string, unknown> = {}, c = client()) =>
    maintainerChange(service, c, "settings.change", { commandId: commandId(), target, changes, ...extra });
  const agentChange = async (target: Parameters<SettingsChangePath["change"]>[0], changes: Parameters<SettingsChangePath["change"]>[1]) => {
    const result = await settingsChanges.change(target, changes, {
      actor: { kind: "agent", id: "repository-agent" }, reason: "Update repository configuration",
    });
    if (result.status !== "review") return result;
    return settingsChanges.change(target, changes, { actor: { kind: "ui", id: "device:phone" },
      reason: "Update repository configuration", confirmationDigest: result.review!.digest });
  };
  const history = async (filter: Record<string, unknown> = {}) => {
    const entries: ChangeEntry[] = [];
    let cursor: string | undefined;
    do {
      const page = await service.invoke(client(), "settings.history", { limit: 50, ...filter, ...(cursor ? { cursor } : {}) }) as unknown as { entries: ChangeEntry[]; nextCursor?: string };
      entries.push(...page.entries);
      cursor = page.nextCursor;
    } while (cursor);
    return entries;
  };
  const macDocument = async () => JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8")) as Record<string, unknown>;
  const published = async (key: string, qualifier?: [string, string]) => {
    for (const event of broadcasts.filter(event => event.topic === "settings.changed")) {
      for (const id of (event.payload as { changeIds: string[] }).changeIds) {
        const entry = await record.find(id);
        if (entry?.key === key && (!qualifier || entry.qualifiers?.[qualifier[0] as "server"] === qualifier[1])) return true;
      }
    }
    return false;
  };
  return { root, tronHome, agentDir, trust, macTerminalKeys, registry, service, record, settingsModel, settingsChanges, broadcasts, pushes, published, outside, change, agentChange, history, macDocument, faux };
}

async function gitProject(root: string, name: string) {
  const project = join(root, name);
  await mkdir(join(project, ".pi"), { recursive: true });
  git(project, "init", "-q", "-b", "main");
  await writeFile(join(project, ".pi", "settings.json"), `${JSON.stringify({ transport: "sse" }, null, 4)}\n`);
  await writeFile(join(project, "README.md"), "fixture\n");
  git(project, "add", ".");
  git(project, "commit", "-q", "-m", "init");
  return project;
}

describe("settings.change", () => {
  caseIt("persists a schema numeric map and rejects unoffered fields without erasing the current store", async owner => {
    const f = await fixture(owner);
    await f.change({ kind: "global" }, [{ key: "model.thinkingBudgets", layer: "global", op: "set", value: { low: 1_234 } }]);
    expect((await f.macDocument()).thinkingBudgets).toEqual({ low: 1_234 });
    await expect(f.change({ kind: "global" }, [{ key: "model.thinkingBudgets", layer: "global", op: "set", value: { unoffered: 3 } }]))
      .rejects.toMatchObject({ code: "invalid_request" });
    expect((await f.macDocument()).thinkingBudgets).toEqual({ low: 1_234 });
    const resolution = await f.service.invoke(client(), "settings.resolve", {
      target: { kind: "global" }, keys: ["model.thinkingBudgets"], renderer: { version: 1, controls: ["list", "readOnly"] },
    }) as unknown as PresentedResolution;
    expect(resolution.keys[0]).toMatchObject({ value: { low: 1_234 }, presentation: { valueKind: "numberMap" } });
    expect(resolution.keys[0]!.presentation.control).toBeUndefined();
    transcript.push({ case: "numeric-map-persistence", detail: resolution });
  });

  caseIt("refuses unauthorized bundles before review and discloses no credentials in a native preview", async owner => {
    const f = await fixture(owner);
    const actor = { actor: { kind: "home" as const, id: "home-fixture" }, reason: "Change the declared setting" };
    await expect(f.settingsChanges.change({ kind: "global" }, [
      { key: "run.retry.maxRetries", layer: "global", op: "set", value: 8 },
      { key: "run.httpProxy", layer: "global", op: "set", value: "http://private-fixture.invalid:3128" },
    ], actor)).rejects.toMatchObject({ code: "invalid_request", message: "HTTP proxy cannot be changed by home" });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 4 });
    expect(await f.history()).toEqual([]);
    const preview = await f.settingsChanges.change({ kind: "global" }, [
      { key: "tools.shell.commandPrefix", layer: "global", op: "set", value: "API_TOKEN=sk-fixturesecret123456789" },
    ], { ...actor, reason: "Use Bearer fixture-secret-token-123456789" });
    expect(preview).toMatchObject({ status: "review", review: { requiresTap: true } });
    expect(JSON.stringify(preview)).not.toContain("sk-fixturesecret123456789");
    expect(JSON.stringify(preview)).not.toContain("fixture-secret-token");
    expect(await f.history()).toEqual([]);
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 4 });
  });

  caseIt("an agent pages its settings history and undoes without borrowing another session's authority", async owner => {
    const f = await fixture(owner);
    const cwd = join(f.root, "history-chat");
    await mkdir(cwd);
    const slot = await f.registry.create(cwd);
    const model = f.faux.getModel();
    await slot.setModel(model.provider, model.id);
    let calls = 0;
    const call = async (input: Record<string, unknown>) => {
      const id = `history-tool-${++calls}`;
      f.faux.setResponses([
        fauxAssistantMessage([fauxToolCall("settings", input, { id })], { stopReason: "toolUse" }),
        fauxAssistantMessage("Done"),
      ]);
      await slot.prompt("Use the requested settings action");
      await waitFor(() => !slot.isBusy && !slot.hasActiveAgentRun || undefined, "settings history tool turn settled");
      const result = slot.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === id);
      if (result?.type !== "message" || result.message.role !== "toolResult") throw new Error("No canonical settings tool result");
      return result.message;
    };
    expect((await call({ action: "change", reason: "Reduce retry attempts", changes: [
      { key: "run.retry.maxRetries", layer: "global", op: "set", value: 3 },
    ] })).isError).not.toBe(true);
    const page = await call({ action: "history", key: "run.retry.maxRetries", limit: 1 });
    expect(page.isError).not.toBe(true);
    const entries = (page.details as { entries: ChangeEntry[] }).entries;
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({ actor: { kind: "agent", sessionId: slot.id }, before: 4, after: 3 });
    const undone = await call({ action: "undo", changeId: entries[0]!.changeId, reason: "Restore retry attempts" });
    expect(undone.isError).not.toBe(true);
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 4 });
    expect((await f.history({ key: "run.retry.maxRetries" }))[0]).toMatchObject({ undoOf: entries[0]!.changeId, actor: { kind: "agent", sessionId: slot.id } });
    const latest = (await call({ action: "history", key: "run.retry.maxRetries", limit: 1 })).details as { entries: ChangeEntry[]; nextCursor: string };
    expect(latest.entries).toHaveLength(1);
    expect(latest.entries[0]!.undoOf).toBe(entries[0]!.changeId);
    expect(latest.nextCursor).toBeTypeOf("string");
    const previous = (await call({ action: "history", key: "run.retry.maxRetries", cursor: latest.nextCursor, limit: 1 })).details as { entries: ChangeEntry[] };
    expect(previous.entries.map(entry => entry.changeId)).toEqual([entries[0]!.changeId]);
    expect((await call({ action: "history", reason: "Not a history parameter" })).isError).toBe(true);
    const other = await f.registry.create(cwd);
    const foreign = await f.change({ kind: "session", sessionId: other.id }, [
      { key: "run.retry.maxRetries", layer: "session", op: "set", value: 8 },
    ], { fence: { runtimeGeneration: other.snapshot().runtimeGeneration, model: other.snapshot().model } }, client([other.id]));
    expect((await call({ action: "undo", changeId: foreign.changes[0]!.changeId, reason: "Attempt cross-session undo" })).isError).toBe(true);
    const foreignResolution = await f.service.invoke(client([other.id]), "settings.resolve", { target: { kind: "session", sessionId: other.id }, keys: ["run.retry.maxRetries"] }) as unknown as Resolution;
    expect(foreignResolution.keys[0]!.value).toBe(8);
    const shell = await f.change({ kind: "global" }, [{ key: "tools.shell.path", layer: "global", op: "set", value: "/bin/sh" }]);
    expect((await call({ action: "undo", changeId: shell.changes[0]!.changeId, reason: "Attempt Home-only undo" })).isError).toBe(true);
  });

  caseIt("records every change once with actor and diff, undoes it, refuses a stale undo, and never undoes a redacted key", async owner => {
    const f = await fixture(owner);
    const applied = await f.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 6, expected: 4 }]);
    expect(applied.status).toBe("applied");
    expect(applied.changes[0]).toMatchObject({ before: 4, after: 6 });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 6 });
    expect(f.broadcasts).toContainEqual({ topic: "settings.changed", payload: expect.objectContaining({ keys: ["run.retry.maxRetries"], layer: "global" }) });
    const [entry] = await f.history({ key: "run.retry.maxRetries" });
    expect(entry).toMatchObject({ actor: { kind: "ui", id: "device:phone" }, layer: "global", before: 4, after: 6, status: "applied",
      presentation: { label: "Retries", section: "run", actor: "You", layer: "Global", display: { before: "4 retries", after: "6 retries" } } });

    await expect(f.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 9, expected: 4 }])).rejects.toMatchObject({ code: "conflict" });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 6 });

    const undone = await maintainerChange(f.service, client(), "settings.undo", { commandId: commandId(), changeId: applied.changes[0]!.changeId }) as { changes: Array<{ changeId: string }> };
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 4 });
    const undoEntry = (await f.history()).find(candidate => candidate.changeId === undone.changes[0]!.changeId);
    expect(undoEntry).toMatchObject({ undoOf: applied.changes[0]!.changeId, before: 6, after: 4 });

    const second = await f.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 8 }]);
    await f.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 10 }]);
    await expect(maintainerChange(f.service, client(), "settings.undo", { commandId: commandId(), changeId: second.changes[0]!.changeId }))
      .rejects.toMatchObject({ code: "conflict", details: { current: 10, after: 8,
        display: { current: "10 retries", after: "8 retries" } } });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 10 });

    const proxy = await f.change({ kind: "global" }, [{ key: "run.httpProxy", layer: "global", op: "set", value: "http://proxy.invalid:3128" }]);
    expect(proxy.changes[0]).toMatchObject({ redacted: true });
    expect(proxy.changes[0]).not.toHaveProperty("after");
    expect(JSON.stringify(proxy)).not.toContain("proxy.invalid");
    const proxyEntry = (await f.history({ key: "run.httpProxy" }))[0]!;
    expect(proxyEntry).toMatchObject({ changed: true, redacted: true,
      presentation: { label: "HTTP proxy", display: { before: "Hidden", after: "Changed" } } });
    expect(JSON.stringify(await f.history())).not.toContain("proxy.invalid");
    await expect(maintainerChange(f.service, client(), "settings.undo", { commandId: commandId(), changeId: proxy.changes[0]!.changeId }))
      .rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("not undoable") });

    await expect(f.change({ kind: "global" }, [{ key: "setup.sessionDir", layer: "global", op: "set", value: "/elsewhere" }])).rejects.toMatchObject({ code: "invalid_request" });
    await f.record.append([{ ...entry!, changeId: "retired-key-entry", key: "retired.setting", actor: { kind: "outside", id: "fixture" }, before: "old", after: "new" }]);
    expect((await f.history({ key: "retired.setting" }))[0]).toMatchObject({
      presentation: { label: "retired.setting", actor: "Outside Tron", display: { before: '"old"', after: '"new"' } },
    });
    expect((await f.record.entry(entry!.changeId))?.entry).not.toHaveProperty("presentation");
    transcript.push({ case: "record, undo and redaction", detail: await f.history() });
  });

  caseIt("changes a live chat's Session scope through its slot lane and records it", async owner => {
    const f = await fixture(owner);
    const cwd = join(f.root, "chat");
    await mkdir(cwd);
    await f.trust.set(cwd, true);
    const slot = await f.registry.create(cwd);
    const first = f.faux.getModel("first")!;
    const second = f.faux.getModel("second")!;
    await slot.setModel(first.provider, first.id);
    const before = slot.snapshot();
    const result = await f.change({ kind: "session", sessionId: slot.id },
      [{ key: "model.ref[role=chat]", layer: "session", op: "set", value: { provider: second.provider, id: second.id } }],
      { fence: { runtimeGeneration: before.runtimeGeneration, model: before.model } }, client([slot.id]));
    expect(slot.snapshot().model).toEqual({ provider: second.provider, id: second.id });
    expect(result.changes[0]!.revision).toBe(slot.snapshot().revision);
    await expect(f.change({ kind: "session", sessionId: slot.id },
      [{ key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low" }],
      { fence: { runtimeGeneration: "retired", model: before.model } }, client([slot.id]))).rejects.toMatchObject({ code: "conflict" });
    const entry = (await f.history({ key: "model.ref[role=chat]" }))[0]!;
    expect(entry).toMatchObject({ layer: "session", target: { kind: "session", sessionId: slot.id }, before: { provider: first.provider, id: first.id }, after: { provider: second.provider, id: second.id } });
    const failed = (await f.history({ status: "failed" }))[0]!;
    expect(failed).toMatchObject({ key: "model.thinking[role=chat]", status: "failed" });
    transcript.push({ case: "session scope", detail: { entry, failed } });
  });

  caseIt("rolls back every store when a change in the same request fails, leaving both unchanged", async owner => {
    const f = await fixture(owner);
    const homeDirectory = join(f.tronHome, "gateway", "home");
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(join(homeDirectory, "profile.json"), "{}\n");
    await chmod(homeDirectory, 0o500);
    try {
      await expect(f.change({ kind: "home" }, [
        { key: "run.retry.maxRetries", layer: "global", op: "set", value: 7 },
        { key: "model.thinking[role=worker]", layer: "session", op: "set", value: "low" },
      ])).rejects.toBeDefined();
    } finally { await chmod(homeDirectory, 0o700); }
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 4 });
    expect(await readFile(join(homeDirectory, "profile.json"), "utf8")).toBe("{}\n");
    const failed = await f.history({ status: "failed" });
    expect(failed.map(entry => entry.key).sort()).toEqual(["model.thinking[role=worker]", "run.retry.maxRetries"]);
    expect(failed.find(entry => entry.key === "run.retry.maxRetries")!.failure).toContain("Rolled back");
    transcript.push({ case: "cross-store rollback", detail: failed });
  });

  caseIt("records the store whose compensating write failed instead of reporting it rolled back", async owner => {
    const f = await fixture(owner);
    const project = join(f.root, "rollback-refused");
    await mkdir(project);
    let trustWrites = 0;
    const changes = new SettingsChangePath(f.settingsModel, f.record, { setTrust: async (path, decision) => {
      trustWrites += 1;
      if (trustWrites > 1) throw new Error("trust store unavailable");
      return f.trust.set(path, decision);
    } });
    const request = [
      { key: "permissions.projectTrust", layer: "global", op: "set", value: true, qualifiers: { project } },
      { key: "model.thinking[role=worker]", layer: "session", op: "set", value: "low" },
    ] as Parameters<SettingsChangePath["change"]>[1];
    const context = { actor: { kind: "ui" as const, id: "device:phone" }, reason: "Trust the project and lower worker thinking" };
    const homeDirectory = join(f.tronHome, "gateway", "home");
    await mkdir(homeDirectory, { recursive: true });
    await writeFile(join(homeDirectory, "profile.json"), "{}\n");
    await chmod(homeDirectory, 0o500);
    try {
      await expect(changes.change({ kind: "home" }, request, context)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
    } finally { await chmod(homeDirectory, 0o700); }
    expect(trustWrites).toBe(2);
    expect((await f.trust.inspect(project)).savedDecision).toBe(true);
    const failed = await f.history({ status: "failed" });
    expect(failed.find(entry => entry.key === "permissions.projectTrust")!.failure)
      .toBe("Not rolled back: the trust store refused its compensating write (trust store unavailable); it may still hold the new value");
  });

  caseIt("refuses every Project write without touching the repository, and badges its git state", async owner => {
    const f = await fixture(owner);
    const transport = (value: string) => [{ key: "run.transport", layer: "project", op: "set", value }] as Parameters<SettingsChangePath["change"]>[1];
    const clean = await gitProject(f.root, "clean");
    await f.trust.set(clean, true);
    const before = await readFile(join(clean, ".pi", "settings.json"), "utf8");
    for (const actor of ["agent", "ui"] as const) {
      const change = actor === "agent" ? f.agentChange({ kind: "project", cwd: clean }, transport("websocket"))
        : f.change({ kind: "project", cwd: clean }, transport("websocket"));
      await expect(change).rejects.toThrow("Project settings are read-only");
    }
    expect(await readFile(join(clean, ".pi", "settings.json"), "utf8")).toBe(before);
    expect(git(clean, "status", "--porcelain").trim()).toBe("");
    expect(await f.history({ key: "run.transport" })).toEqual([]);

    const localBadge = async (cwd: string) => ((await f.service.invoke(client(), "settings.resolve", { target: { kind: "project", cwd }, keys: ["run.transport"] })) as unknown as
      { keys: Array<{ badges: Array<{ label: string; detail?: string }> }> }).keys[0]!.badges.find(badge => badge.label === "Local only");
    const ignored = await gitProject(f.root, "ignored");
    await f.trust.set(ignored, true);
    git(ignored, "rm", "-q", "--cached", ".pi/settings.json");
    await writeFile(join(ignored, ".gitignore"), ".pi/\n");
    git(ignored, "add", ".gitignore");
    git(ignored, "commit", "-q", "-m", "ignore .pi");
    expect(await localBadge(ignored)).toMatchObject({ detail: "Project: .pi is ignored by git" });
    const plain = join(f.root, "plain");
    await mkdir(join(plain, ".pi"), { recursive: true });
    await writeFile(join(plain, ".pi", "settings.json"), `${JSON.stringify({ transport: "sse" })}\n`);
    await f.trust.set(plain, true);
    expect(await localBadge(plain)).toMatchObject({ detail: "Project: not in a git repository" });
    transcript.push({ case: "project writes refused", detail: await f.history({ key: "run.transport" }) });
  });

  caseIt("changes trust through the change path and undoes it", async owner => {
    const f = await fixture(owner);
    const project = join(f.root, "trusted");
    await mkdir(project);
    const granted = await f.change({ kind: "project", cwd: project }, [{ key: "permissions.projectTrust", layer: "global", op: "set", value: true }]);
    expect((await f.trust.inspect(project)).savedDecision).toBe(true);
    expect(f.broadcasts.some(event => event.topic === "trust.changed")).toBe(true);
    expect((await f.history({ key: "permissions.projectTrust" }))[0]).toMatchObject({ after: true, status: "applied" });
    await maintainerChange(f.service, client(), "settings.undo", { commandId: commandId(), changeId: granted.changes[0]!.changeId });
    expect((await f.trust.inspect(project)).savedDecision).toBeNull();

    const repository = await realpath(await gitProject(f.root, "rooted"));
    const subdirectory = join(repository, "packages", "app");
    await mkdir(subdirectory, { recursive: true });
    const rooted = await f.change({ kind: "global" }, [{ key: "permissions.projectTrust", layer: "global", op: "set", value: true, qualifiers: { project: subdirectory } }]);
    expect(rooted.changes[0]).toMatchObject({ qualifiers: { project: repository } });
    expect(await f.trust.inspect(subdirectory)).toMatchObject({ projectDir: repository, savedDecision: true });
    expect((await f.history({ key: "permissions.projectTrust" })).some(entry => entry.actor?.kind === "outside")).toBe(false);

    const parent = join(f.root, "workspace");
    const child = join(parent, "child");
    await mkdir(child, { recursive: true });
    await f.trust.set(parent, true);
    const trustRow = async () => (await f.service.invoke(client(), "settings.resolve", { target: { kind: "project", cwd: child }, keys: ["permissions.projectTrust"] }) as unknown as Resolution).keys[0]!;
    expect(await f.trust.inspect(child)).toMatchObject({ effectiveDecision: true });
    expect(await trustRow()).toMatchObject({ value: true, layer: "global" });
    const blocked = await f.change({ kind: "project", cwd: child }, [{ key: "permissions.projectTrust", layer: "global", op: "set", value: false }]);
    expect(await trustRow()).toMatchObject({ value: false });
    await maintainerChange(f.service, client(), "settings.undo", { commandId: commandId(), changeId: blocked.changes[0]!.changeId });
    expect((await f.trust.inspect(child)).savedDecision).toBe(true);
    expect(JSON.parse(await readFile(join(f.agentDir, "trust.json"), "utf8"))[await realpath(child)]).toBeUndefined();
  });

  caseIt("filters paged Changes by actor, layer and section without dropping older matches", async owner => {
    const f = await fixture(owner, { segmentEntries: 2 });
    const homeRun = await f.settingsChanges.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 2 }], {
      actor: { kind: "home", id: "home" }, reason: "Reduce retries",
    });
    await f.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 3 }]);
    const worker = await f.settingsChanges.change({ kind: "global" }, [{ key: "run.transport", layer: "global", op: "set", value: "sse" }], {
      actor: { kind: "worker", id: "worker", taskId: "task" }, reason: "Use streaming HTTP",
    });
    const profile = await f.settingsChanges.change({ kind: "home" }, [{ key: "model.thinking[role=worker]", layer: "session", op: "set", value: "low" }], {
      actor: { kind: "home", id: "home" }, reason: "Use less thinking for workers",
    });
    const ids = async (filter: Record<string, unknown>) => (await f.history(filter)).map(entry => entry.changeId);
    expect(await ids({ actor: "agents", section: "run" })).toEqual([worker.changes[0]!.changeId, homeRun.changes[0]!.changeId]);
    expect(await ids({ actor: "home", layer: "session", section: "workers" })).toEqual([profile.changes[0]!.changeId]);
    expect(await ids({ actor: "home", layer: "global", key: "run.retry.maxRetries", status: "applied" })).toEqual([homeRun.changes[0]!.changeId]);
    expect(await ids({ actor: "ui" })).toHaveLength(1);
    expect(await ids({})).toHaveLength(4);
    for (const filter of [{ actor: "unknown" }, { layer: "everywhere" }, { section: "unknown" }, { section: "advanced" }]) {
      await expect(f.service.invoke(client(), "settings.history", filter)).rejects.toMatchObject({ code: "invalid_request" });
    }
    transcript.push({ case: "Changes filters", detail: await f.history({ actor: "agents" }) });
  });

  caseIt("bounds a sparse filtered history page to one segment and resumes without losing older matches", async owner => {
    const f = await fixture(owner, { segmentEntries: 2 });
    const first = await f.settingsChanges.change({ kind: "global" }, [{ key: "run.transport", layer: "global", op: "set", value: "sse" }], {
      actor: { kind: "home", id: "home" }, reason: "Prefer streaming HTTP",
    });
    for (let value = 0; value < 5; value += 1) {
      await f.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value }]);
    }
    const query = { key: "run.transport", limit: 50 };
    const newest = await f.service.invoke(client(), "settings.history", query) as unknown as { entries: ChangeEntry[]; nextCursor?: string };
    expect(newest.entries).toEqual([]);
    expect(newest.nextCursor).toBeDefined();
    const middle = await f.service.invoke(client(), "settings.history", { ...query, cursor: newest.nextCursor }) as unknown as { entries: ChangeEntry[]; nextCursor?: string };
    expect(middle.entries).toEqual([]);
    expect(middle.nextCursor).toBeDefined();
    const oldest = await f.service.invoke(client(), "settings.history", { ...query, cursor: middle.nextCursor }) as unknown as { entries: ChangeEntry[]; nextCursor?: string };
    expect(oldest.entries.map(entry => entry.changeId)).toEqual([first.changes[0]!.changeId]);
    expect(oldest.nextCursor).toBeUndefined();
    expect((await f.history(query)).map(entry => entry.changeId)).toEqual([first.changes[0]!.changeId]);
    transcript.push({ case: "sparse filtered paging", detail: { newest, middle, oldest } });
  });

  caseIt("keeps every entry forever in bounded segments and pages through them", async owner => {
    const f = await fixture(owner, { segmentEntries: 5 });
    for (let value = 0; value < 23; value += 1) {
      await f.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: value % 20 }]);
    }
    const pages: number[] = [];
    const seen: string[] = [];
    let cursor: string | undefined;
    do {
      const page = await f.service.invoke(client(), "settings.history", { limit: 4, ...(cursor ? { cursor } : {}) }) as unknown as { entries: ChangeEntry[]; nextCursor?: string };
      pages.push(page.entries.length);
      seen.push(...page.entries.map(entry => entry.changeId));
      cursor = page.nextCursor;
    } while (cursor);
    expect(new Set(seen).size).toBe(23);
    expect(Math.max(...pages)).toBeLessThanOrEqual(4);
    const files = (await readdir(f.record.path)).filter(name => name.endsWith(".jsonl")).sort();
    expect(files).toHaveLength(5);
    for (const name of files) {
      expect((await readFile(join(f.record.path, name), "utf8")).trim().split("\n").length).toBeLessThanOrEqual(5);
    }
    const all = await f.history();
    expect(all[0]!.after).toBe(22 % 20);
    transcript.push({ case: "paging", detail: { pages, segments: files.length } });
  });
});

describe("outside changes", () => {
  type Row = { key: string; value: unknown; layer: string; badges: Array<{ label: string; detail?: string; action?: { kind: string; changeId?: string } }> };
  const rows = async (f: Awaited<ReturnType<typeof fixture>>, target: Record<string, unknown>, keys: string[]) =>
    (await f.service.invoke(client(), "settings.resolve", { target, keys }) as unknown as { keys: Row[] }).keys;
  const row = async (f: Awaited<ReturnType<typeof fixture>>, target: Record<string, unknown>, key: string) => (await rows(f, target, [key]))[0]!;
  const outsideEntries = async (f: Awaited<ReturnType<typeof fixture>>) => (await f.history()).filter(entry => entry.status === "outside");
  const label = (r: Row, text: string) => r.badges.find(badge => badge.label === text);

  caseIt("records one outside entry per hand-edited Global key, never Tron's own write, and catches rename-replace", async owner => {
    const f = await fixture(owner);
    await row(f, { kind: "global" }, "run.retry.maxRetries");

    await f.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 6 }]);
    expect(await outsideEntries(f)).toEqual([]);
    expect(label(await row(f, { kind: "global" }, "run.retry.maxRetries"), "Changed outside Tron")).toBeUndefined();

    const document = await f.macDocument();
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...document, retry: { maxRetries: 9 }, transport: "sse" }));
    const edited = await row(f, { kind: "global" }, "run.retry.maxRetries");
    await row(f, { kind: "global" }, "run.retry.maxRetries");
    const first = await outsideEntries(f);
    expect(first.map(entry => [entry.key, entry.before, entry.after, entry.actor.kind]).sort()).toEqual([
      ["run.retry.maxRetries", 6, 9, "outside"], ["run.transport", undefined, "sse", "outside"],
    ]);
    expect(edited.value).toBe(9);
    const changed = label(edited, "Changed outside Tron")!;
    expect(changed.detail).toBe("Global: 6 retries → 9 retries");
    expect(changed.action).toMatchObject({ kind: "applyAgain", changeId: first.find(entry => entry.key === "run.retry.maxRetries")!.changeId });
    expect(label(await row(f, { kind: "global" }, "run.transport"), "Changed outside Tron")!.action).toBeUndefined();

    const again = await f.service.invoke(client(), "settings.applyAgain", { commandId: commandId(), changeId: changed.action!.changeId }) as unknown as { status: string; changes: Array<{ changeId: string }> };
    expect(again.status).toBe("applied");
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 6 });
    expect((await f.history())[0]).toMatchObject({ applyAgainOf: changed.action!.changeId, after: 6, actor: { kind: "ui" } });
    expect(label(await row(f, { kind: "global" }, "run.retry.maxRetries"), "Changed outside Tron")).toBeUndefined();
    await expect(f.service.invoke(client(), "settings.applyAgain", { commandId: commandId(), changeId: changed.action!.changeId })).rejects.toMatchObject({ code: "conflict" });

    const temporary = join(f.agentDir, "settings.json.swp");
    await writeFile(temporary, JSON.stringify({ ...(await f.macDocument()), retry: { maxRetries: 2 } }));
    await rename(temporary, join(f.agentDir, "settings.json"));
    expect((await row(f, { kind: "global" }, "run.retry.maxRetries")).value).toBe(2);
    expect((await outsideEntries(f)).filter(entry => entry.key === "run.retry.maxRetries").map(entry => entry.after)).toEqual([2, 9]);

    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...(await f.macDocument()), httpProxy: "http://user:secret@proxy.invalid" }));
    await row(f, { kind: "global" }, "run.httpProxy");
    const proxy = (await outsideEntries(f)).find(entry => entry.key === "run.httpProxy")!;
    expect(proxy).toMatchObject({ redacted: true, changed: true });
    expect(JSON.stringify(proxy)).not.toContain("secret");
    expect(await readFile(f.outside.path, "utf8")).not.toContain("secret");
    transcript.push({ case: "outside mac", detail: await outsideEntries(f) });
  });

  caseIt("a file event alone records and broadcasts each change without a tier push", async owner => {
    const f = await fixture(owner);
    f.outside.startWatching(() => {});
    await row(f, { kind: "global" }, "run.retry.maxRetries");
    await watcherDelivers(f.outside, f.agentDir);
    const until = async (done: () => boolean | Promise<boolean>) => {
      for (let attempt = 0; attempt < 100 && !(await done()); attempt += 1) await new Promise(resolve => setTimeout(resolve, 50));
    };
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...(await f.macDocument()), retry: { maxRetries: 8 } }));
    await until(() => f.broadcasts.some(event => event.topic === "settings.changed" && JSON.stringify(event.payload).includes("run.retry.maxRetries")));
    expect((await f.record.page({ limit: 10 })).entries.map(entry => [entry.key, entry.status])).toEqual([["run.retry.maxRetries", "outside"]]);
    expect(f.pushes).toEqual([]);
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...(await f.macDocument()), packages: ["npm:outside-package"] }));
    await until(() => f.published("sources.packages"));
    expect(await f.published("sources.packages")).toBe(true);
    expect(f.pushes).toEqual([]);
  });

  caseIt("a git project: owner edits, commits, a stash and a pull are outside changes Tron never offers to re-apply", async owner => {
    const f = await fixture(owner);
    const project = await gitProject(f.root, "repo");
    await f.trust.set(project, true);
    const target = { kind: "project" as const, cwd: project };
    const transport = async () => row(f, target, "run.transport");
    const write = (value: Record<string, unknown>) => writeFile(join(project, ".pi", "settings.json"), `${JSON.stringify(value, null, 4)}\n`);
    await transport();
    const baseline = (await outsideEntries(f)).length;

    await write({ transport: "websocket" });
    const edited = await transport();
    expect(edited.value).toBe("websocket");
    expect(label(edited, "Uncommitted")).toBeDefined();
    expect(label(edited, "Changed outside Tron")?.action).toBeUndefined();
    expect((await outsideEntries(f)).length).toBe(baseline + 1);
    git(project, "commit", "-q", "-am", "transport");
    const committed = await transport();
    expect(committed.value).toBe("websocket");
    expect(label(committed, "Uncommitted")).toBeUndefined();
    expect((await outsideEntries(f)).length).toBe(baseline + 1);
    await write({ transport: "auto" });
    await transport();
    git(project, "stash", "-q");
    expect((await transport()).value).toBe("websocket");
    expect((await outsideEntries(f))[0]).toMatchObject({ key: "run.transport", before: "auto", after: "websocket", git: { branch: "main" } });
    git(project, "stash", "drop", "-q");

    const clone = join(f.root, "clone");
    git(f.root, "clone", "-q", project, clone);
    await writeFile(join(clone, ".pi", "settings.json"), `${JSON.stringify({ transport: "auto", packages: ["npm:pulled"] }, null, 4)}\n`);
    git(clone, "commit", "-q", "-am", "upstream settings");
    const pushesBefore = f.pushes.length;
    git(project, "pull", "-q", "--ff-only", clone, "main");
    await transport();
    const pulled = (await outsideEntries(f)).filter(entry => entry.git?.head === git(project, "rev-parse", "HEAD").trim());
    expect(pulled.map(entry => entry.key).sort()).toEqual(["run.transport", "sources.packages"]);
    expect(await f.published("sources.packages")).toBe(true);
    expect(await f.published("run.transport")).toBe(true);
    expect(f.pushes.slice(pushesBefore)).toEqual([]);
    transcript.push({ case: "outside git", detail: await outsideEntries(f) });
  });
});

describe("outside changes to MCP servers and custom models", () => {
  const until = async (stage: string, done: () => boolean | Promise<boolean>) => {
    const started = performance.now();
    try {
      for (let attempt = 0; attempt < 100 && !(await done()); attempt += 1) await new Promise(resolve => setTimeout(resolve, 50));
    } finally {
      transcript.push({ case: "outside mcp and models stage", detail: { stage, ms: Math.round(performance.now() - started) } });
    }
  };
  type Presented = ChangeEntry & { presentation: { label: string; section?: string; display: { before: string; after: string } } };
  const outsideEntries = async (f: Awaited<ReturnType<typeof fixture>>) => (await f.history()).filter(entry => entry.status === "outside") as Presented[];
  const servers = async (f: Awaited<ReturnType<typeof fixture>>, params: Record<string, unknown>) =>
    ((await f.service.invoke(client(), "mcp.list", params)) as { servers: Array<{ name: string; scope: string }> }).servers.map(server => `${server.scope}:${server.name}`).sort();
  const writeJson = async (path: string, value: unknown) => {
    await writeFile(`${path}.swp`, `${JSON.stringify(value, null, 2)}\n`);
    await rename(`${path}.swp`, path);
  };
  const stagedFixture = async (owner: CaseOwner) => {
    const f = await fixture(owner);
    const invoke = f.service.invoke.bind(f.service);
    f.service.invoke = (async (client: ClientContext, method: string, params: unknown) => {
      const started = performance.now();
      try { return await invoke(client, method, params as never); }
      finally { transcript.push({ case: "outside mcp and models stage", detail: { stage: `invoke ${method}`, ms: Math.round(performance.now() - started) } }); }
    }) as typeof f.service.invoke;
    f.outside.startWatching(() => {});
    await watcherDelivers(f.outside, f.agentDir);
    return f;
  };

  caseEach(["mcp-auth.json", "coalesced.lock"])("reconciles missed global MCP drift from the directory hint %s (#1900)", async (filename, owner) => {
    const f = await fixture(owner);
    const target = join(f.root, "shared-mcp.json");
    await writeFile(target, JSON.stringify({ mcpServers: {} }));
    await symlink(target, join(f.agentDir, "mcp.json"));
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "global" } });
    const failures: string[] = [];
    const filenames: string[] = [];
    f.outside.startWatching(error => { failures.push(String(error)); });
    const native = f.outside as unknown as { watchers: Map<string, import("node:fs").FSWatcher>; timers: Map<string, NodeJS.Timeout>; reconciliations: Set<Promise<void>> };
    for (const watcher of native.watchers.values()) {
      watcher.on("change", (_event, name) => { filenames.push(String(name)); });
    }
    const hint = async () => {
      await writeFile(join(f.agentDir, filename), "{}\n");
      await new Promise(resolve => setTimeout(resolve, 400));
    };
    try {
      await waitFor(async () => { await hint(); return filenames.includes(filename); }, "the native auth-file directory event");
      await waitFor(() => native.timers.size === 0 && native.reconciliations.size === 0, "initial native rescans settle before controlled drift");
      filenames.length = 0;
      await writeFile(target, JSON.stringify({ mcpServers: { "missed-write": { command: "echo", args: ["fixture"] } } }));
      await waitFor(async () => {
        await hint();
        return f.published("tools.mcp.server", ["server", "missed-write"]);
      }, "an unclassified directory event publishes the missed MCP change");
      const entries = (await f.history()).filter(entry => entry.actor.kind === "outside");
      expect(entries).toHaveLength(1);
      expect(entries[0]).toMatchObject({ key: "tools.mcp.server", qualifiers: { server: "missed-write" }, status: "outside", redacted: true });
      expect(failures).toEqual([]);
    } finally {
      transcript.push({ case: "coalesced global directory hint", detail: { filename, filenames, broadcasts: f.broadcasts, failures } });
    }
  }, 30_000);

  caseIt("records global Mac mcp.json edits per server by digest, pushes, refreshes the MCP owner, and never records Tron's own writes", async owner => {
    const f = await stagedFixture(owner);
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "global" }, keys: ["run.transport"] });
    const baseline = (await outsideEntries(f)).length;

    await f.service.invoke(client(), "mcp.add", { commandId: commandId(), scope: "global", server: "tron-added", transport: "http", url: "http://127.0.0.1:1/tron" });
    expect(f.broadcasts).toContainEqual({ topic: "mcp.changed", payload: { scope: "global" } });
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "global" }, keys: ["run.transport"] });
    expect((await outsideEntries(f)).length).toBe(baseline);
    expect(await servers(f, { scope: "global" })).toEqual(["global:tron-added"]);

    const globalMcp = join(f.agentDir, "mcp.json");
    const current = JSON.parse(await readFile(globalMcp, "utf8")) as { mcpServers: Record<string, unknown> };
    await writeJson(globalMcp, { ...current, mcpServers: { ...current.mcpServers, "hand-added": { url: "http://127.0.0.1:1/hand", headers: { Authorization: "Bearer outside-secret" } } } });
    await until("publication: MCP server hand-added", () => f.published("tools.mcp.server", ["server", "hand-added"]));
    const added = (await outsideEntries(f))[0]!;
    expect(added).toMatchObject({ key: "tools.mcp.server", qualifiers: { server: "hand-added" }, op: "set", added: true, redacted: true,
      layer: "global", target: { kind: "global" }, actor: { kind: "outside", id: globalMcp },
      presentation: { label: "MCP server hand-added", section: "tools", display: { before: "Not configured", after: "Added" } } });
    expect(f.pushes).toEqual([]);
    expect(f.broadcasts.filter(event => event.topic === "mcp.changed").length).toBe(2);
    expect(JSON.stringify(await f.history())).not.toContain("outside-secret");
    expect(await readFile(f.outside.path, "utf8")).not.toContain("outside-secret");
    expect(await servers(f, { scope: "global" })).toEqual(["global:hand-added", "global:tron-added"]);
    const afterAdd = JSON.parse(await readFile(globalMcp, "utf8")) as { mcpServers: Record<string, unknown> };
    delete afterAdd.mcpServers["tron-added"];
    await writeJson(globalMcp, afterAdd);
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "global" }, keys: ["run.transport"] });
    expect((await outsideEntries(f))[0]).toMatchObject({ key: "tools.mcp.server", qualifiers: { server: "tron-added" }, op: "unset",
      presentation: { display: { before: "Configured", after: "Removed" } } });

    const beforeTron = JSON.parse(await readFile(globalMcp, "utf8")) as { mcpServers: Record<string, unknown> };
    await writeJson(globalMcp, { ...beforeTron, mcpServers: { ...beforeTron.mcpServers, "edited-before-tron": { url: "http://127.0.0.1:1/before" } } });
    await f.service.invoke(client(), "mcp.add", { commandId: commandId(), scope: "global", server: "tron-second", transport: "http", url: "http://127.0.0.1:1/second" });
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "global" }, keys: ["run.transport"] });
    const aroundTron = await outsideEntries(f);
    expect(aroundTron.filter(entry => entry.qualifiers?.server === "edited-before-tron").map(entry => entry.op)).toEqual(["set"]);
    expect(aroundTron.some(entry => entry.qualifiers?.server === "tron-second")).toBe(false);
    expect((await f.history({ section: "tools" })).some(entry => entry.key === "tools.mcp.server")).toBe(true);
    transcript.push({ case: "outside mcp and models", detail: await outsideEntries(f) });
  });

  caseIt("records Project mcp.json edits from a late .pi watch, a Git pull, and the Project MCP owner under the Project root", async owner => {
    const f = await stagedFixture(owner);
    const project = await gitProject(f.root, "mcp-repo");
    const subdirectory = join(project, "packages", "app");
    await mkdir(subdirectory, { recursive: true });
    await f.trust.set(project, true);
    const projectTarget = { kind: "project", cwd: subdirectory };
    await f.service.invoke(client(), "settings.resolve", { target: projectTarget, keys: ["run.transport"] });

    const late = join(f.root, "late-pi");
    await mkdir(late);
    await f.trust.set(late, true);
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "project", cwd: late }, keys: ["run.transport"] });
    await mkdir(join(late, ".pi"));
    await writeJson(join(late, ".pi", "mcp.json"), { mcpServers: { first: { url: "http://127.0.0.1:1/first" } } });
    await until("publication: MCP server first", () => f.published("tools.mcp.server", ["server", "first"]));
    await new Promise(resolve => setTimeout(resolve, 400));
    await writeJson(join(late, ".pi", "mcp.json"), { mcpServers: { first: { url: "http://127.0.0.1:1/first" }, second: { url: "http://127.0.0.1:1/second" } } });
    await until("publication: MCP server second", () => f.published("tools.mcp.server", ["server", "second"]));
    expect(await f.published("tools.mcp.server", ["server", "second"])).toBe(true);

    const chat = await f.registry.create(subdirectory);
    expect(chat.cwd).toBe(await realpath(subdirectory));
    expect(chat.projectDir).toBe(await realpath(project));
    await expect(f.service.invoke(client(), "mcp.add", { commandId: commandId(), scope: "project", cwd: subdirectory, server: "project-tron", transport: "http", url: "http://127.0.0.1:1/project" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await writeJson(join(project, ".pi", "mcp.json"), { mcpServers: { "project-tron": { url: "http://127.0.0.1:1/project" } } });
    await until("publication: MCP server project-tron", () => f.published("tools.mcp.server", ["server", "project-tron"]));
    await expect(readFile(join(subdirectory, ".pi", "mcp.json"), "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    git(project, "add", ".pi/mcp.json");
    git(project, "commit", "-q", "-m", "project mcp");
    const beforePull = (await outsideEntries(f)).length;
    await f.service.invoke(client(), "settings.resolve", { target: projectTarget, keys: ["run.transport"] });
    expect((await outsideEntries(f)).length).toBe(beforePull);
    const clone = join(f.root, "mcp-clone");
    git(f.root, "clone", "-q", project, clone);
    const cloned = JSON.parse(await readFile(join(clone, ".pi", "mcp.json"), "utf8")) as { mcpServers: Record<string, unknown> };
    await writeFile(join(clone, ".pi", "mcp.json"), `${JSON.stringify({ ...cloned, mcpServers: { ...cloned.mcpServers, pulled: { command: "/usr/bin/false" } } }, null, 2)}\n`);
    git(clone, "commit", "-q", "-am", "add pulled server");
    const pushesBefore = f.pushes.length;
    git(project, "pull", "-q", "--ff-only", clone, "main");
    await f.service.invoke(client(), "settings.resolve", { target: projectTarget, keys: ["run.transport"] });
    const pulled = (await outsideEntries(f))[0]!;
    expect(pulled).toMatchObject({ key: "tools.mcp.server", qualifiers: { server: "pulled" }, added: true, layer: "project",
      target: { kind: "project", cwd: await realpath(project) }, git: { path: ".pi/mcp.json", head: git(project, "rev-parse", "HEAD").trim(), branch: "main" } });
    await until("publication: MCP server pulled", () => f.published("tools.mcp.server", ["server", "pulled"]));
    expect(f.pushes.slice(pushesBefore)).toEqual([]);
    expect(f.broadcasts).toContainEqual({ topic: "mcp.changed", payload: { scope: "project", projectDir: await realpath(project) } });
    expect(await servers(f, { scope: "project", cwd: subdirectory })).toEqual(expect.arrayContaining(["project:project-tron", "project:pulled"]));
    transcript.push({ case: "outside mcp and models", detail: await outsideEntries(f) });
  });

  caseIt("records custom model provider edits by digest and pushes, and never records Tron's own save", async owner => {
    const f = await stagedFixture(owner);
    const document = { providers: { "tron-provider": { baseUrl: "https://tron-models.invalid/v1", api: "openai-completions", apiKey: "tron-key", models: [{ id: "m" }] } } };
    await f.service.invoke(client(), "models.custom.put", { commandId: commandId(), document });
    expect(f.broadcasts.at(-1)).toEqual({ topic: "models.customChanged", payload: {} });
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "global" }, keys: ["run.transport"] });
    const beforeModels = (await outsideEntries(f)).length;
    const modelsPath = join(f.agentDir, "models.json");
    const saved = JSON.parse(await readFile(modelsPath, "utf8")) as { providers: Record<string, unknown> };
    await writeJson(modelsPath, { providers: { ...saved.providers, "hand-provider": { baseUrl: "https://hand-models.invalid/v1", api: "openai-completions", apiKey: "outside-model-secret", models: [{ id: "h" }] } } });
    await until("publication: custom model provider hand-provider", () => f.published("accounts.models.provider", ["provider", "hand-provider"]));
    expect((await outsideEntries(f)).length).toBe(beforeModels + 1);
    expect((await outsideEntries(f))[0]).toMatchObject({ key: "accounts.models.provider", qualifiers: { provider: "hand-provider" }, added: true,
      presentation: { label: "Custom model provider hand-provider", section: "accounts" } });
    expect(f.broadcasts).toContainEqual({ topic: "models.customChanged", payload: {} });
    expect(JSON.stringify(await f.history())).not.toContain("outside-model-secret");
    const served = await f.service.invoke(client(), "models.custom.get", {}) as { document: { providers: Record<string, unknown> } };
    expect(Object.keys(served.document.providers).sort()).toEqual(["hand-provider", "tron-provider"]);
    transcript.push({ case: "outside mcp and models", detail: await outsideEntries(f) });
  });
});

describe("every key at every allowed layer", () => {
  const report: Array<Record<string, unknown>> = [];
  caseEach(["session", "home", "project", "global"])("changes, resolves, stores and undoes each declared key instance at the %s store", async (only, owner) => {
    const f = await fixture(owner);
    const first = f.faux.getModel("first")!, second = f.faux.getModel("second")!;
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...(await f.macDocument()), defaultProvider: first.provider, defaultModel: first.id }));
    const project = await gitProject(f.root, "every");
    await writeFile(join(project, ".pi", "settings.json"), JSON.stringify({ transport: "sse", modelContextWindows: { [`${first.provider}/${first.id}`]: 64_000 } }));
    await f.trust.set(project, true);
    await f.macTerminalKeys.set(ENROLLED_IPHONE, macTerminalSampleKey());
    const slot = await f.registry.create(project);
    await slot.setModel(first.provider, first.id);
    const targets: Record<string, Record<string, unknown>> = {
      session: { kind: "session", sessionId: slot.id }, home: { kind: "home" }, project: { kind: "project", cwd: project }, global: { kind: "global" },
    };
    type Served = { key: string; group: string; qualifiers?: Record<string, string>; value: unknown; layer: string;
      projectSetting?: { file: string; path: string }; presentation: { editable: boolean } };
    const resolve = async (layer: string, key: string) => {
      const resolution = await f.service.invoke(client([slot.id]), "settings.resolve", { target: targets[layer], keys: [key] }) as unknown as { keys: Served[] };
      if (key === "permissions.macTerminalKey") expect(resolution.keys[0]?.group).toBe("connections");
      return resolution.keys[0];
    };
    const fence = () => { const snapshot = slot.snapshot(); return { runtimeGeneration: snapshot.runtimeGeneration, model: snapshot.model, revision: snapshot.revision }; };
    const differs = (left: unknown, right: unknown) => JSON.stringify(left ?? null) !== JSON.stringify(right ?? null);
    const sample = async (layer: string, row: Served, key: KeyDeclaration): Promise<unknown> => {
      const { kind: valueKind, options, range } = key.type;
      const { optionsSource } = key;
      if (key.fixed?.role && valueKind === "stringList") return [`${second.provider}/${second.id}`, `${first.provider}/${first.id}`];
      if (optionsSource?.name === "catalog.models") return differs(row.value, { provider: second.provider, id: second.id }) ? { provider: second.provider, id: second.id } : { provider: first.provider, id: first.id };
      if (optionsSource?.name === "catalog.thinkingLevels") {
        const served = await f.service.invoke(client([slot.id]), "settings.options", { target: targets[layer], key: row.key, ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) }) as unknown as { options: Array<{ value: unknown }> };
        return served.options.map(option => option.value).find(value => differs(value, row.value));
      }
      if (optionsSource?.name === "catalog.contextWindow") return row.value === first.contextWindow ? first.contextWindow - 1 : first.contextWindow;
      if (row.key === "permissions.macTerminalKey") return macTerminalSampleKey();
      if (valueKind === "boolean") return row.value !== true;
      if (valueKind === "numberMap") return { [String(options![0]!.value)]: range!.min + 1 };
      if (options?.length) return options.map(option => option.value).find(value => differs(value, row.value));
      if (valueKind === "integer") return Math.floor((range!.min + range!.max) / 2) === row.value ? range!.min : Math.floor((range!.min + range!.max) / 2);
      if (valueKind === "toolSelection") return layer === "home" ? ["settings"] : ["read"];
      if (valueKind === "stringList") return ["sample-entry"];
      if (valueKind === "packages") return ["npm:sample-package"];
      if (valueKind === "text") return "sample-text";
      throw new Error(`No generic sample for ${row.key} (${valueKind})`);
    };
    const stored = async (key: KeyDeclaration, layer: string, qualifiers: Record<string, string>) => {
      const binding = key.layers[layer as "global"]!;
      const json = async (path: string) => JSON.parse(await readFile(path, "utf8").catch(() => "{}")) as Record<string, unknown>;
      const stores = {
        layers: ["session", "home", "project", "global", "default"], global: await json(join(f.agentDir, "settings.json")),
        project: { root: project, document: await json(join(project, ".pi", "settings.json")), applied: true },
        home: await json(join(f.tronHome, "gateway", "home", "profile.json")),
        trust: await json(join(f.agentDir, "trust.json")) as Record<string, boolean>,
        macTerminal: await f.macTerminalKeys.read(),
        gateway: await json(join(f.tronHome, "gateway", "settings", "gateway.json")),
        session: slot.settingsSessionLayer(),
      } as unknown as SettingsStores;
      const qualified = binding.store === "pi" && binding.qualified !== undefined && qualifiers.model !== undefined;
      const raw = readBinding(stores, layer as "global", binding, qualifiers, qualified, key.id);
      return key.type.compose && raw !== undefined ? key.type.compose(composedBelow(stores, key, qualifiers, layer as "global"), raw) : raw;
    };
    for (const key of KEYS) {
      for (const layer of Object.keys(key.layers).filter(layer => layer === only)) {
        const row = await resolve(layer, key.id);
        const instance = { key: key.id, layer, qualifiers: row?.qualifiers };
        if (!row) { report.push({ ...instance, result: key.writers.length === 0 ? "verified unserved: no writer" : "no instance on its target" }); continue; }
        const value = await sample(layer, row, key);
        const scope = layer === "home" ? "session" : layer;
        const request = [{ key: key.id, layer: scope, op: "set", value, ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) }];
        const extra = layer === "session" ? { fence: fence() } : {};
        if (row.projectSetting && layer === "session") {
          await expect(f.change(targets[layer]!, request, extra, client([slot.id]))).rejects.toThrow("edit its Project key instead");
          report.push({ ...instance, result: "verified masked by Project" });
          continue;
        }
        if (!row.presentation.editable) {
          await expect(f.change(targets[layer]!, request, extra, client([slot.id]))).rejects.toMatchObject({ code: "invalid_request" });
          report.push({ ...instance, result: "verified read-only" });
          continue;
        }
        if (key.id === "permissions.macTerminalKey" || key.id === "permissions.macTerminalServer") {
          const actor = key.id === "permissions.macTerminalKey"
            ? { ...client([slot.id]), identity: ENROLLED_IPHONE } as ClientContext : client([slot.id]);
          expect(await f.change(targets[layer]!, request, { ...extra, dryRun: true }, actor))
            .toMatchObject({ dryRun: true, status: "applied", review: { requiresTap: true } });
          report.push({ ...instance, result: "native mutation: real sshd Gateway round trips" });
          continue;
        }
        let applied: Awaited<ReturnType<typeof f.change>>;
        try {
          const actor = key.id === "permissions.macTerminalKey"
            ? { ...client([slot.id]), identity: ENROLLED_IPHONE } as ClientContext : client([slot.id]);
          applied = await f.change(targets[layer]!, request, extra, actor);
        } catch (error) {
          report.push({ ...instance, result: `refused: ${(error as Error).message}` });
          continue;
        }
        expect(applied.status, `${key.id}@${layer}`).toBe("applied");
        const after = await resolve(layer, key.id);
        const expectedValue = key.redacted ? undefined : value;
        expect(after!.layer, `${key.id}@${layer} source`).toBe(scope);
        if (!key.redacted) expect(after!.value, `${key.id}@${layer} value`).toEqual(expectedValue);
        expect(await stored(key, layer, after!.qualifiers ?? row.qualifiers ?? {}), `${key.id}@${layer} store`).toEqual(value);
        const undo = maintainerChange(f.service, client([slot.id]), "settings.undo", { commandId: commandId(), changeId: applied.changes[0]!.changeId, ...(layer === "session" ? { fence: fence() } : {}) });
        if (key.redacted) {
          await expect(undo).rejects.toMatchObject({ code: "conflict" });
          await f.change(targets[layer]!, [{ key: key.id, layer: scope, op: "unset", ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) }], extra, client([slot.id]));
          expect(await stored(key, layer, row.qualifiers ?? {}), `${key.id}@${layer} unset`).toBeUndefined();
        } else await undo;
        const undone = await resolve(layer, key.id);
        if (!key.redacted) expect(undone!.value, `${key.id}@${layer} undo`).toEqual(row.value);
        report.push({ ...instance, result: "round-trip", value: key.redacted ? "redacted" : value });
      }
    }
    transcript.push({ case: `every key: ${only}`, detail: report.filter(entry => entry.layer === only) });
    await mkdir(dirname(EVERY_KEY_ARTIFACT), { recursive: true });
    await writeFile(EVERY_KEY_ARTIFACT, `${JSON.stringify(report, null, 2)}\n`);
    const gaps = report.filter(entry => entry.layer === only && !["round-trip", "verified read-only", "verified masked by Project", "verified unserved: no writer", "native mutation: real sshd Gateway round trips"].includes(String(entry.result)) && !String(entry.result).startsWith("Home applier"));
    expect(gaps).toEqual([]);
  }, 60_000);
});
