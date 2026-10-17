import { generateKeyPairSync } from "node:crypto";
import { MacTerminalKeys } from "../security/mac-terminal.js";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "./trust-service.js";
import { SettingsChangePath, SettingsModel } from "./settings-model.js";
import { SettingsChangeRecord, type ChangeEntry } from "./settings-record.js";
import { SettingsApprovals } from "./settings-approvals.js";
import { OutsideChanges } from "./settings-outside.js";
import { McpAdminService } from "./mcp-admin-service.js";
import { ModelConfigService } from "./model-config-service.js";
import { SettingsRiskEvaluator, type SettingsRiskInput } from "./settings-risk.js";
import { JEV_MAX_ESTIMATED_CHARGE_CENTS } from "../knowledge/jev-client.js";
import { CONTROLS } from "./settings-types.js";
import { composedBelow, readBinding, type Resolution, type SettingsStores } from "./settings-resolver.js";
import { KEYS, type KeyDeclaration } from "./settings-schema.js";
import type { PresentedResolution } from "./settings-presentation.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";

/**
 * The one settings change path at its real boundaries (docs/settings-model.md
 * 5.1-5.3, 5.7, foundation F2): `settings.change`, `settings.undo` and
 * `settings.history` through the Gateway, over the real Mac file, trust store,
 * a live chat's slot lane, and real git repositories for Project writes. The
 * record and a transcript of each case are retained as an artifact.
 */
const ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../test-results/settings-change.json");
const EVERY_KEY_ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../test-results/settings-every-key.json");
const roots: string[] = [];
const registries: RuntimeRegistry[] = [];
const outsides: OutsideChanges[] = [];
const transcript: Array<{ case: string; detail: unknown }> = [];
afterEach(async () => {
  vi.unstubAllEnvs();
  for (const outside of outsides.splice(0)) outside.dispose();
  await Promise.all(registries.splice(0).map(registry => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  await mkdir(dirname(ARTIFACT), { recursive: true });
  await writeFile(ARTIFACT, `${JSON.stringify(transcript, null, 2)}\n`);
});

const GIT_ENV = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid" };
const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, stdio: "pipe", env: GIT_ENV }).toString();

/** The paired iPhone whose Mac Terminal key the every-key case changes. */
const ENROLLED_IPHONE = "00000000-0000-4000-8000-000000000001";

/** A fresh OpenSSH ecdsa-sha2-nistp256 public key, as the iPhone's Secure Enclave key enrolls. */
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

async function fixture(options: { segmentEntries?: number; assessRisk?: (input: SettingsRiskInput, signal: AbortSignal) => Promise<{ tier: "quiet" | "notify" | "approve"; rationale: string }> } = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-change-"));
  roots.push(root);
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
  const registry = new RuntimeRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: runtimeFactory, trust,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  registries.push(registry);
  await registry.initialize();
  const macTerminalKeys = new MacTerminalKeys(join(root, "home", ".ssh"));
  const settingsModel = new SettingsModel({ agentDir, tronHome, trust, modelRuntime, macTerminalKeys });
  const record = new SettingsChangeRecord(tronHome, options.segmentEntries);
  // Production wiring: every read reconciles outside changes (doc 5.6).
  const outside = new OutsideChanges(tronHome, agentDir, record, settingsModel.observedReaders);
  settingsModel.observeOutside(outside);
  outsides.push(outside);
  const settingsChanges = new SettingsChangePath(settingsModel, record, new SettingsApprovals(tronHome), {
    ...(options.assessRisk ? { assessRisk: options.assessRisk } : {}),
    setTrust: async (project, decision) => {
      return trust.setAndApply(project, decision,
        async inspection => { await registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false); },
        async inspection => { await registry.commitProjectReload(inspection.projectDir); });
    },
  }, agentDir);
  registry.setSettings(settingsModel, settingsChanges);
  const broadcasts: Array<{ topic: string; payload: unknown }> = [];
  // The relay boundary: what would be pushed to the maintainer's iPhone.
  const pushes: Array<{ sourceId: string; title: string; message: string }> = [];
  const notifications = { enqueue: async (push: { sourceId: string; title: string; message: string }) => { pushes.push(push); } };
  const service = new GatewayService({
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime, trust, settingsModel, settingsChanges, sessions: registry, receipts: new CommandReceiptStore(tronHome), notifications,
    broadcast: (topic: string, payload: unknown) => broadcasts.push({ topic, payload }),
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
    // The production MCP owner over the bundled pi CLI, and the custom-model owner (gateway-main.ts).
    mcpAdmin: new McpAdminService(agentDir, join(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))), "bundle/cli.js")),
    modelConfig: new ModelConfigService(agentDir),
  } as unknown as GatewayServiceDependencies);
  const change = (target: Record<string, unknown>, changes: unknown[], extra: Record<string, unknown> = {}, c = client()) =>
    service.invoke(c, "settings.change", { commandId: commandId(), target, changes, ...extra }) as Promise<{ status: string; changes: Array<{ changeId: string; revision?: number; git?: Record<string, unknown> }> }>;
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
  return { root, tronHome, agentDir, trust, macTerminalKeys, registry, service, record, settingsChanges, broadcasts, pushes, outside, change, history, macDocument, faux };
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
  it("persists a schema numeric map and rejects unoffered fields without erasing the current store", async () => {
    const f = await fixture();
    await f.change({ kind: "mac" }, [{ key: "model.thinkingBudgets", layer: "mac", op: "set", value: { low: 1_234 } }]);
    expect((await f.macDocument()).thinkingBudgets).toEqual({ low: 1_234 });
    await expect(f.change({ kind: "mac" }, [{ key: "model.thinkingBudgets", layer: "mac", op: "set", value: { unoffered: 3 } }]))
      .rejects.toMatchObject({ code: "invalid_request" });
    expect((await f.macDocument()).thinkingBudgets).toEqual({ low: 1_234 });
    const resolution = await f.service.invoke(client(), "settings.resolve", {
      target: { kind: "mac" }, keys: ["model.thinkingBudgets"], renderer: { version: 1, controls: ["list", "readOnly"] },
    }) as unknown as PresentedResolution;
    expect(resolution.keys[0]).toMatchObject({ value: { low: 1_234 }, presentation: {
      control: "list", valueKind: "numberMap", options: expect.arrayContaining([{ value: "low", label: "Low" }]),
      range: { min: 0, max: 10_000_000, step: 1, unit: "tokens" },
    } });
    transcript.push({ case: "numeric-map-persistence", detail: resolution });
  });

  it("holds a non-UI change when the bounded risk model raises its tier", async () => {
    const f = await fixture({ assessRisk: async () => ({ tier: "approve", rationale: "unexpected scope" }) });
    const result = await f.settingsChanges.change({ kind: "mac" }, [
      { key: "run.retry.maxRetries", layer: "mac", op: "set", value: 6 },
    ], { actor: { kind: "home", id: "home-fixture" }, reason: "Retry a bounded failure" });
    expect(result.status).toBe("pending");
    // A held change still names its values, so the agent's settings tool detail shows old → new (#957).
    expect(result.changes[0]).toMatchObject({ key: "run.retry.maxRetries", status: "pending", before: 4, after: 6 });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 4 });
    expect((await f.history())[0]).toMatchObject({ tier: "approve", tierBasis: { floor: "quiet", risk: "approve" } });
    transcript.push({ case: "risk-raise-held", detail: { result, history: await f.history() } });
  });

  it("keeps lowered maintainer floors and web escalation, audits risk failure and timeout, and withholds value secrets", async () => {
    let mode: "quiet" | "fail" | "timeout" = "quiet";
    const calls: unknown[] = [];
    const evaluator = new SettingsRiskEvaluator({ evaluate: async (request, signal, context) => {
      calls.push(request);
      expect(context?.maxChargeCents).toBe(JEV_MAX_ESTIMATED_CHARGE_CENTS);
      if (mode === "fail") throw new Error("provider failure must not be copied into audit");
      if (mode === "timeout") await new Promise((_, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
      return { requestedModel: "jev-latest", actualModel: "jev-latest", usage: { input_tokens: 50, output_tokens: 0 },
        estimatedCostCents: 0.001, maxEstimatedChargeCents: JEV_MAX_ESTIMATED_CHARGE_CENTS,
        answers: { tier: { type: "choice", choice: "quiet", confidence: 1, probabilities: { quiet: 1, notify: 0, approve: 0 } },
          rationale: { type: "choice", choice: "baseline", confidence: 1, probabilities: { baseline: 1, scope: 0, consequence: 0, uncertain: 0 } } } };
    } });
    const f = await fixture({ assessRisk: evaluator.assess.bind(evaluator) });
    const agent = { actor: { kind: "home" as const, id: "home-fixture" }, reason: "Change the declared setting" };
    await f.change({ kind: "mac" }, [{ key: "context.images.block", layer: "mac", op: "set", value: true }]);
    await f.change({ kind: "mac" }, [{ key: "permissions.floor", layer: "mac", op: "set", value: "notify",
      qualifiers: { key: "context.images.block", direction: "widen" } }]);
    expect(calls).toHaveLength(0); // UI taps never spend on risk classification.
    const lowered = await f.settingsChanges.change({ kind: "mac" }, [
      { key: "context.images.block", layer: "mac", op: "set", value: false },
    ], agent);
    expect(lowered).toMatchObject({ status: "applied", tier: "notify" });
    expect((await f.history({ key: "context.images.block" })).find(e => e.changeId === lowered.changes[0]!.changeId))
      .toMatchObject({ tierBasis: { floor: "notify", floorSource: "override", risk: "quiet", riskEvaluation: { status: "assessed" } } });
    const web = await f.settingsChanges.change({ kind: "mac" }, [
      { key: "run.retry.maxRetries", layer: "mac", op: "set", value: 5 },
    ], { ...agent, web: true });
    expect(web).toMatchObject({ status: "applied", tier: "notify" });
    mode = "fail";
    const failed = await f.settingsChanges.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 6 }], agent);
    expect(failed).toMatchObject({ status: "applied", tier: "quiet" });
    expect((await f.history()).find(e => e.changeId === failed.changes[0]!.changeId))
      .toMatchObject({ tierBasis: { risk: null, riskEvaluation: { status: "failed" } } });
    mode = "timeout";
    const timedOut = await f.settingsChanges.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 7 }], agent);
    expect(timedOut).toMatchObject({ status: "applied", tier: "quiet" });
    expect((await f.history()).find(e => e.changeId === timedOut.changes[0]!.changeId))
      .toMatchObject({ tierBasis: { risk: null, riskEvaluation: { status: "timeout" } } });
    mode = "quiet";
    const beforeRefusal = calls.length;
    await expect(f.settingsChanges.change({ kind: "mac" }, [
      { key: "run.retry.maxRetries", layer: "mac", op: "set", value: 8 },
      { key: "run.httpProxy", layer: "mac", op: "set", value: "http://private-fixture.invalid:3128" },
    ], agent))
      .rejects.toMatchObject({ code: "invalid_request", message: "HTTP proxy cannot be changed by home" });
    expect(calls).toHaveLength(beforeRefusal); // Authorization precedes disclosure.
    await f.settingsChanges.change({ kind: "mac" }, [{ key: "tools.shell.commandPrefix", layer: "mac", op: "set", value: "API_TOKEN=private-fixture.invalid" }],
      { ...agent, reason: "Use Bearer fixture-secret-token-123456789" });
    expect(JSON.stringify(calls)).not.toContain("private-fixture.invalid");
    expect(JSON.stringify(calls)).not.toContain("fixture-secret-token");
    expect(JSON.stringify(await f.history())).not.toContain("provider failure must not be copied");
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 7 });
    transcript.push({ case: "risk-floor-failure-timeout-redaction", detail: { calls, outcomes: (await f.history()).map(e => ({ key: e.key, tier: e.tier, basis: e.tierBasis })) } });
  });

  it("records every change once with actor and diff, undoes it, refuses a stale undo, and never undoes a redacted key", async () => {
    const f = await fixture();
    const applied = await f.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 6, expected: 4 }]);
    expect(applied.status).toBe("applied");
    expect(applied.changes[0]).toMatchObject({ before: 4, after: 6 });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 6 });
    expect(f.broadcasts).toContainEqual({ topic: "settings.changed", payload: expect.objectContaining({ keys: ["run.retry.maxRetries"], layer: "mac" }) });
    const [entry] = await f.history({ key: "run.retry.maxRetries" });
    expect(entry).toMatchObject({ actor: { kind: "ui", id: "device:phone" }, layer: "mac", before: 4, after: 6, status: "applied", tier: "quiet",
      tierBasis: { floor: "quiet", floorSource: "code", web: false, risk: null },
      presentation: { label: "Retries", section: "run", actor: "You", layer: "Mac", display: { before: "4 retries", after: "6 retries" } } });

    // A stale `expected` is refused and changes nothing.
    await expect(f.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 9, expected: 4 }])).rejects.toMatchObject({ code: "conflict" });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 6 });

    // Undo writes `before` back as an ordinary change that names what it undid.
    const undone = await f.service.invoke(client(), "settings.undo", { commandId: commandId(), changeId: applied.changes[0]!.changeId }) as { changes: Array<{ changeId: string }> };
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 4 });
    const undoEntry = (await f.history()).find(candidate => candidate.changeId === undone.changes[0]!.changeId);
    expect(undoEntry).toMatchObject({ undoOf: applied.changes[0]!.changeId, before: 6, after: 4 });

    // Undo after a later conflicting change is refused with the current value.
    const second = await f.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 8 }]);
    await f.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 10 }]);
    await expect(f.service.invoke(client(), "settings.undo", { commandId: commandId(), changeId: second.changes[0]!.changeId }))
      .rejects.toMatchObject({ code: "conflict", details: { current: 10, after: 8,
        display: { current: "10 retries", after: "8 retries" } } });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 10 });

    // A redacted key records only "changed", and its change is not undoable.
    const proxy = await f.change({ kind: "mac" }, [{ key: "run.httpProxy", layer: "mac", op: "set", value: "http://proxy.invalid:3128" }]);
    // A redacted key's outcome withholds both values, as its record does.
    expect(proxy.changes[0]).toMatchObject({ redacted: true });
    expect(proxy.changes[0]).not.toHaveProperty("after");
    expect(JSON.stringify(proxy)).not.toContain("proxy.invalid");
    const proxyEntry = (await f.history({ key: "run.httpProxy" }))[0]!;
    expect(proxyEntry).toMatchObject({ changed: true, redacted: true, tier: "notify",
      presentation: { label: "HTTP proxy", display: { before: "Hidden", after: "Changed" } } });
    expect(JSON.stringify(await f.history())).not.toContain("proxy.invalid");
    await expect(f.service.invoke(client(), "settings.undo", { commandId: commandId(), changeId: proxy.changes[0]!.changeId }))
      .rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("not undoable") });

    // A layer the key does not allow, and a key with no writer, are refused.
    await expect(f.change({ kind: "mac" }, [{ key: "setup.sessionDir", layer: "mac", op: "set", value: "/elsewhere" }])).rejects.toMatchObject({ code: "invalid_request" });
    // Permanent history remains readable after a schema key retires. The outside
    // actor must not be mislabeled as a UI change, and projection never rewrites audit.
    await f.record.append([{ ...entry!, changeId: "retired-key-entry", key: "retired.setting", actor: { kind: "outside", id: "fixture" }, before: "old", after: "new" }]);
    expect((await f.history({ key: "retired.setting" }))[0]).toMatchObject({
      presentation: { label: "retired.setting", actor: "Outside Tron", display: { before: '"old"', after: '"new"' } },
    });
    expect((await f.record.entry(entry!.changeId))?.entry).not.toHaveProperty("presentation");
    transcript.push({ case: "record, undo and redaction", detail: await f.history() });
  });

  it("changes a live chat's Chat layer through its slot lane and records it", async () => {
    const f = await fixture();
    const cwd = join(f.root, "chat");
    await mkdir(cwd);
    await f.trust.set(cwd, true);
    const slot = await f.registry.create(cwd);
    const first = f.faux.getModel("first")!;
    const second = f.faux.getModel("second")!;
    await slot.setModel(first.provider, first.id);
    const before = slot.snapshot();
    const result = await f.change({ kind: "session", sessionId: slot.id },
      [{ key: "model.ref[role=chat]", layer: "chat", op: "set", value: { provider: second.provider, id: second.id } }],
      { fence: { runtimeGeneration: before.runtimeGeneration, model: before.model } }, client([slot.id]));
    expect(slot.snapshot().model).toEqual({ provider: second.provider, id: second.id });
    expect(result.changes[0]!.revision).toBe(slot.snapshot().revision);
    // A stale fence is refused by the lane guard and changes nothing.
    await expect(f.change({ kind: "session", sessionId: slot.id },
      [{ key: "model.thinking[role=chat]", layer: "chat", op: "set", value: "low" }],
      { fence: { runtimeGeneration: "retired", model: before.model } }, client([slot.id]))).rejects.toMatchObject({ code: "conflict" });
    const entry = (await f.history({ key: "model.ref[role=chat]" }))[0]!;
    expect(entry).toMatchObject({ layer: "chat", target: { kind: "session", sessionId: slot.id }, before: { provider: first.provider, id: first.id }, after: { provider: second.provider, id: second.id } });
    const failed = (await f.history({ status: "failed" }))[0]!;
    expect(failed).toMatchObject({ key: "model.thinking[role=chat]", status: "failed" });
    transcript.push({ case: "chat layer", detail: { entry, failed } });
  });

  it("rolls back every store when a change in the same request fails, leaving both unchanged", async () => {
    const f = await fixture();
    const project = join(f.root, "conflicted");
    await mkdir(join(project, ".pi"), { recursive: true });
    const conflicted = "{\n<<<<<<< HEAD\n  \"transport\": \"sse\"\n=======\n  \"transport\": \"websocket\"\n>>>>>>> theirs\n}\n";
    await writeFile(join(project, ".pi", "settings.json"), conflicted);
    await f.trust.set(project, true);
    const resolved = await f.service.invoke(client(), "settings.resolve", { target: { kind: "project", cwd: project } }) as unknown as Resolution;
    expect(resolved.projectUnreadable).toBe(true);
    await expect(f.change({ kind: "project", cwd: project }, [
      { key: "run.retry.maxRetries", layer: "mac", op: "set", value: 7 },
      { key: "run.transport", layer: "project", op: "set", value: "auto" },
    ])).rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("cannot be parsed") });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 4 });
    expect(await readFile(join(project, ".pi", "settings.json"), "utf8")).toBe(conflicted);
    const failed = await f.history({ status: "failed" });
    expect(failed.map(entry => entry.key).sort()).toEqual(["run.retry.maxRetries", "run.transport"]);
    expect(failed.find(entry => entry.key === "run.transport")!.failure).toContain("cannot be parsed");
    expect(failed.find(entry => entry.key === "run.retry.maxRetries")!.failure).toContain("Rolled back");
    transcript.push({ case: "cross-store rollback", detail: failed });
  });

  it("writes and stages Project changes, never commits, and records why a write was not staged", async () => {
    const f = await fixture();
    const transport = (value: string) => [{ key: "run.transport", layer: "project", op: "set", value }];

    // A clean repository: written, staged, never committed.
    const clean = await gitProject(f.root, "clean");
    await f.trust.set(clean, true);
    const staged = await f.change({ kind: "project", cwd: clean }, transport("websocket"));
    expect(git(clean, "diff", "--cached", "--name-only").trim()).toBe(".pi/settings.json");
    expect(git(clean, "log", "--oneline").trim().split("\n")).toHaveLength(1);
    expect(staged.changes[0]!.git).toMatchObject({ staged: true, path: ".pi/settings.json", blob: expect.stringMatching(/^[0-9a-f]{40}$/u) });
    expect(staged.changes[0]!.git!.warning).toBeUndefined();
    // Every other key and the file's indentation are kept.
    expect(await readFile(join(clean, ".pi", "settings.json"), "utf8")).toBe(`${JSON.stringify({ transport: "websocket" }, null, 4)}\n`);

    // Other staged work and the maintainer's own unstaged edits: staged anyway, with a warning.
    const busy = await gitProject(f.root, "busy");
    await f.trust.set(busy, true);
    await writeFile(join(busy, "README.md"), "other work\n");
    git(busy, "add", "README.md");
    await writeFile(join(busy, ".pi", "settings.json"), `${JSON.stringify({ transport: "sse", steeringMode: "all" }, null, 4)}\n`);
    const warned = await f.change({ kind: "project", cwd: busy }, transport("auto"));
    expect(warned.changes[0]!.git).toMatchObject({ staged: true, warning: expect.stringContaining("Other staged work: README.md") });
    expect(warned.changes[0]!.git!.warning).toContain("unstaged edits");
    expect(git(busy, "diff", "--cached", "--name-only").trim().split("\n").sort()).toEqual([".pi/settings.json", "README.md"]);

    const localBadge = async (cwd: string) => ((await f.service.invoke(client(), "settings.resolve", { target: { kind: "project", cwd }, keys: ["run.transport"] })) as unknown as
      { keys: Array<{ badges: Array<{ label: string; detail?: string }> }> }).keys[0]!.badges.find(badge => badge.label === "Local only");
    // An ignored .pi: written, not staged, with the reason; its row says Local only.
    const ignored = await gitProject(f.root, "ignored");
    await f.trust.set(ignored, true);
    git(ignored, "rm", "-q", "--cached", ".pi/settings.json");
    await writeFile(join(ignored, ".gitignore"), ".pi/\n");
    git(ignored, "add", ".gitignore");
    git(ignored, "commit", "-q", "-m", "ignore .pi");
    const local = await f.change({ kind: "project", cwd: ignored }, transport("websocket"));
    expect(local.changes[0]!.git).toMatchObject({ staged: false, reason: ".pi is ignored by git" });
    expect(JSON.parse(await readFile(join(ignored, ".pi", "settings.json"), "utf8"))).toEqual({ transport: "websocket" });
    expect(await localBadge(ignored)).toMatchObject({ detail: "Project: .pi is ignored by git" });

    // No repository: written, not staged.
    const plain = join(f.root, "plain");
    await mkdir(plain);
    await f.trust.set(plain, true);
    const unstaged = await f.change({ kind: "project", cwd: plain }, transport("sse"));
    expect(unstaged.changes[0]!.git).toMatchObject({ staged: false, reason: "not in a git repository" });
    expect(JSON.parse(await readFile(join(plain, ".pi", "settings.json"), "utf8"))).toEqual({ transport: "sse" });
    expect(await localBadge(plain)).toMatchObject({ detail: "Project: not in a git repository" });

    // An untrusted project is never written.
    const untrusted = await gitProject(f.root, "untrusted");
    await f.trust.set(untrusted, false);
    await expect(f.change({ kind: "project", cwd: untrusted }, transport("auto"))).rejects.toMatchObject({ code: "trust_required" });
    expect(git(untrusted, "diff", "--cached", "--name-only").trim()).toBe("");

    // A conflicted file: a failed entry, the file untouched.
    const conflictedRepo = await gitProject(f.root, "conflicted-repo");
    await f.trust.set(conflictedRepo, true);
    await writeFile(join(conflictedRepo, ".pi", "settings.json"), "<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> other\n");
    await expect(f.change({ kind: "project", cwd: conflictedRepo }, transport("auto"))).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(join(conflictedRepo, ".pi", "settings.json"), "utf8")).toContain("<<<<<<<");
    expect((await f.history({ status: "failed" })).find(entry => entry.target.kind === "project" && entry.target.cwd.endsWith("conflicted-repo"))).toMatchObject({ key: "run.transport", status: "failed" });
    transcript.push({ case: "project writes", detail: await f.history({ key: "run.transport" }) });
  });

  it("changes trust through the change path and undoes it", async () => {
    const f = await fixture();
    const project = join(f.root, "trusted");
    await mkdir(project);
    const granted = await f.change({ kind: "project", cwd: project }, [{ key: "permissions.projectTrust", layer: "mac", op: "set", value: true }]);
    expect((await f.trust.inspect(project)).savedDecision).toBe(true);
    expect(f.broadcasts.some(event => event.topic === "trust.changed")).toBe(true);
    expect((await f.history({ key: "permissions.projectTrust" }))[0]).toMatchObject({ after: true, tier: "approve", tierBasis: { direction: "widen" } });
    await f.service.invoke(client(), "settings.undo", { commandId: commandId(), changeId: granted.changes[0]!.changeId });
    expect((await f.trust.inspect(project)).savedDecision).toBeNull();

    // Trust is keyed by the Project root: a Mac request naming a subdirectory
    // reads, records and writes its worktree root's decision, so Tron's own
    // write is not reported as an outside change.
    const repository = await realpath(await gitProject(f.root, "rooted"));
    const subdirectory = join(repository, "packages", "app");
    await mkdir(subdirectory, { recursive: true });
    const rooted = await f.change({ kind: "mac" }, [{ key: "permissions.projectTrust", layer: "mac", op: "set", value: true, qualifiers: { project: subdirectory } }]);
    expect(rooted.changes[0]).toMatchObject({ qualifiers: { project: repository } });
    expect(await f.trust.inspect(subdirectory)).toMatchObject({ projectDir: repository, savedDecision: true });
    expect((await f.history({ key: "permissions.projectTrust" })).some(entry => entry.actor?.kind === "outside")).toBe(false);

    // A decision saved for a parent folder covers the project (pi's nearest-entry
    // rule): its row shows the inherited value, not Not set, and an explicit
    // change at the project still undoes to "no decision of its own".
    const parent = join(f.root, "workspace");
    const child = join(parent, "child");
    await mkdir(child, { recursive: true });
    await f.trust.set(parent, true);
    const trustRow = async () => (await f.service.invoke(client(), "settings.resolve", { target: { kind: "project", cwd: child }, keys: ["permissions.projectTrust"] }) as unknown as Resolution).keys[0]!;
    expect(await f.trust.inspect(child)).toMatchObject({ effectiveDecision: true });
    expect(await trustRow()).toMatchObject({ value: true, layer: "mac" });
    const blocked = await f.change({ kind: "project", cwd: child }, [{ key: "permissions.projectTrust", layer: "mac", op: "set", value: false }]);
    expect(await trustRow()).toMatchObject({ value: false });
    await f.service.invoke(client(), "settings.undo", { commandId: commandId(), changeId: blocked.changes[0]!.changeId });
    expect((await f.trust.inspect(child)).savedDecision).toBe(true);
    expect(JSON.parse(await readFile(join(f.agentDir, "trust.json"), "utf8"))[await realpath(child)]).toBeUndefined();
  });

  it("filters paged Changes by actor, layer and section without dropping older matches", async () => {
    const f = await fixture({ segmentEntries: 2 });
    const homeRun = await f.settingsChanges.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 2 }], {
      actor: { kind: "home", id: "home" }, reason: "Reduce retries",
    });
    await f.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 3 }]);
    const worker = await f.settingsChanges.change({ kind: "mac" }, [{ key: "run.transport", layer: "mac", op: "set", value: "sse" }], {
      actor: { kind: "worker", id: "worker", taskId: "task" }, reason: "Use streaming HTTP",
    });
    const profile = await f.settingsChanges.change({ kind: "home" }, [{ key: "model.thinking[role=worker]", layer: "profile", op: "set", value: "low" }], {
      actor: { kind: "home", id: "home" }, reason: "Use less thinking for workers",
    });
    const ids = async (filter: Record<string, unknown>) => (await f.history(filter)).map(entry => entry.changeId);
    expect(await ids({ actor: "agents", section: "run" })).toEqual([worker.changes[0]!.changeId, homeRun.changes[0]!.changeId]);
    expect(await ids({ actor: "home", layer: "profile", section: "model" })).toEqual([profile.changes[0]!.changeId]);
    expect(await ids({ actor: "home", layer: "mac", key: "run.retry.maxRetries", status: "applied" })).toEqual([homeRun.changes[0]!.changeId]);
    expect(await ids({ actor: "ui" })).toHaveLength(1);
    expect(await ids({})).toHaveLength(4);
    for (const filter of [{ actor: "unknown" }, { layer: "builtin" }, { section: "unknown" }]) {
      await expect(f.service.invoke(client(), "settings.history", filter)).rejects.toMatchObject({ code: "invalid_request" });
    }
    transcript.push({ case: "Changes filters", detail: await f.history({ actor: "agents" }) });
  });

  it("bounds a sparse filtered history page to one segment and resumes without losing older matches", async () => {
    const f = await fixture({ segmentEntries: 2 });
    const first = await f.settingsChanges.change({ kind: "mac" }, [{ key: "run.transport", layer: "mac", op: "set", value: "sse" }], {
      actor: { kind: "home", id: "home" }, reason: "Prefer streaming HTTP",
    });
    for (let value = 0; value < 5; value += 1) {
      await f.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value }]);
    }
    const query = { key: "run.transport", limit: 50 };
    const newest = await f.service.invoke(client(), "settings.history", query) as unknown as { entries: ChangeEntry[]; nextCursor?: string };
    // Sparse filters must not scan the forever-growing record in one request.
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

  it("keeps every entry forever in bounded segments and pages through them", async () => {
    const f = await fixture({ segmentEntries: 5 });
    for (let value = 0; value < 23; value += 1) {
      await f.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: value % 20 }]);
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
    // Newest first.
    const all = await f.history();
    expect(all[0]!.after).toBe(22 % 20);
    transcript.push({ case: "paging", detail: { pages, segments: files.length } });
  });
});

/**
 * Outside changes (docs/settings-model.md 5.6, 5.7; #764) against the real Mac
 * file and real git repositories: per-key `outside` entries, Tron's own writes
 * never echo, rename-replace and missed events are caught by digest, git state
 * badges, commit facts, Apply again, and pushes decided by each key's floor.
 */
describe("outside changes", () => {
  type Row = { key: string; value: unknown; layer: string; badges: Array<{ label: string; detail?: string; action?: { kind: string; changeId?: string } }> };
  const rows = async (f: Awaited<ReturnType<typeof fixture>>, target: Record<string, unknown>, keys: string[]) =>
    (await f.service.invoke(client(), "settings.resolve", { target, keys }) as unknown as { keys: Row[] }).keys;
  const row = async (f: Awaited<ReturnType<typeof fixture>>, target: Record<string, unknown>, key: string) => (await rows(f, target, [key]))[0]!;
  const outsideEntries = async (f: Awaited<ReturnType<typeof fixture>>) => (await f.history()).filter(entry => entry.status === "outside");
  const label = (r: Row, text: string) => r.badges.find(badge => badge.label === text);

  it("records one outside entry per hand-edited Mac key, never Tron's own write, and catches rename-replace", async () => {
    const f = await fixture();
    await row(f, { kind: "mac" }, "run.retry.maxRetries"); // the first read is the baseline

    // A Tron write: no outside entry (negative control), on this read and the next.
    await f.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 6 }]);
    expect(await outsideEntries(f)).toEqual([]);
    expect(label(await row(f, { kind: "mac" }, "run.retry.maxRetries"), "Changed outside Tron")).toBeUndefined();

    // A hand edit of two keys: exactly one entry per key, the live value follows the file.
    const document = await f.macDocument();
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...document, retry: { maxRetries: 9 }, transport: "sse" }));
    const edited = await row(f, { kind: "mac" }, "run.retry.maxRetries");
    await row(f, { kind: "mac" }, "run.retry.maxRetries"); // a second read records nothing more
    const first = await outsideEntries(f);
    expect(first.map(entry => [entry.key, entry.before, entry.after, entry.actor.kind]).sort()).toEqual([
      ["run.retry.maxRetries", 6, 9, "outside"], ["run.transport", undefined, "sse", "outside"],
    ]);
    expect(edited.value).toBe(9);
    // It replaced Tron's value, so the row offers Apply again with the diff.
    const changed = label(edited, "Changed outside Tron")!;
    expect(changed.detail).toBe("Mac: 6 retries → 9 retries");
    expect(changed.action).toMatchObject({ kind: "applyAgain", changeId: first.find(entry => entry.key === "run.retry.maxRetries")!.changeId });
    // A value Tron never wrote shows the change without Apply again.
    expect(label(await row(f, { kind: "mac" }, "run.transport"), "Changed outside Tron")!.action).toBeUndefined();

    // Apply again is an ordinary audited change; the row clears.
    const again = await f.service.invoke(client(), "settings.applyAgain", { commandId: commandId(), changeId: changed.action!.changeId }) as unknown as { status: string; changes: Array<{ changeId: string }> };
    expect(again.status).toBe("applied");
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 6 });
    expect((await f.history())[0]).toMatchObject({ applyAgainOf: changed.action!.changeId, after: 6, actor: { kind: "ui" } });
    expect(label(await row(f, { kind: "mac" }, "run.retry.maxRetries"), "Changed outside Tron")).toBeUndefined();
    // A stale Apply again (the store moved on) is refused, not applied.
    await expect(f.service.invoke(client(), "settings.applyAgain", { commandId: commandId(), changeId: changed.action!.changeId })).rejects.toMatchObject({ code: "conflict" });

    // An editor's rename-replace write is detected like any other.
    const temporary = join(f.agentDir, "settings.json.swp");
    await writeFile(temporary, JSON.stringify({ ...(await f.macDocument()), retry: { maxRetries: 2 } }));
    await rename(temporary, join(f.agentDir, "settings.json"));
    expect((await row(f, { kind: "mac" }, "run.retry.maxRetries")).value).toBe(2);
    expect((await outsideEntries(f)).filter(entry => entry.key === "run.retry.maxRetries").map(entry => entry.after)).toEqual([2, 9]);

    // A redacted key is recorded as changed, never with its value.
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...(await f.macDocument()), httpProxy: "http://user:secret@proxy.invalid" }));
    await row(f, { kind: "mac" }, "run.httpProxy");
    const proxy = (await outsideEntries(f)).find(entry => entry.key === "run.httpProxy")!;
    expect(proxy).toMatchObject({ redacted: true, changed: true });
    expect(JSON.stringify(proxy)).not.toContain("secret");
    expect(await readFile(f.outside.path, "utf8")).not.toContain("secret");
    transcript.push({ case: "outside mac", detail: await outsideEntries(f) });
  });

  it("a file event alone records the change and pushes by floor: quiet keys never push", async () => {
    const f = await fixture();
    f.outside.startWatching(() => {});
    await row(f, { kind: "mac" }, "run.retry.maxRetries");
    const until = async (done: () => boolean | Promise<boolean>) => {
      for (let attempt = 0; attempt < 100 && !(await done()); attempt += 1) await new Promise(resolve => setTimeout(resolve, 50));
    };
    // Quiet floor: recorded and broadcast, not pushed.
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...(await f.macDocument()), retry: { maxRetries: 8 } }));
    await until(() => f.broadcasts.some(event => event.topic === "settings.changed" && JSON.stringify(event.payload).includes("run.retry.maxRetries")));
    expect((await f.record.page({ limit: 10 })).entries.map(entry => [entry.key, entry.status])).toEqual([["run.retry.maxRetries", "outside"]]);
    expect(f.pushes).toEqual([]);
    // Adding a package (a widening with a notify floor) pushes.
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...(await f.macDocument()), packages: ["npm:outside-package"] }));
    await until(() => f.pushes.length > 0);
    expect(f.pushes).toEqual([expect.objectContaining({ title: "Changed outside Tron", message: expect.stringContaining("Packages") })]);
  });

  it("a git project: staged, committed, unstaged, stash, restore, branch switches and a pull", async () => {
    const f = await fixture();
    const project = await gitProject(f.root, "repo");
    await f.trust.set(project, true);
    const target = { kind: "project", cwd: project };
    const transport = async () => row(f, target, "run.transport");
    const read = async () => JSON.parse(await readFile(join(project, ".pi", "settings.json"), "utf8")) as Record<string, unknown>;
    await transport();
    const baseline = (await outsideEntries(f)).length; // trust was set by hand before the first read

    // A staged Tron edit: Staged, then a commit appends `committed` and the badge drops to Project.
    const written = await f.change(target, [{ key: "run.transport", layer: "project", op: "set", value: "websocket" }]);
    expect(label(await transport(), "Staged")).toBeDefined();
    git(project, "commit", "-q", "-m", "transport");
    const committedRow = await transport();
    expect(committedRow.badges.map(badge => badge.label)).toEqual(["Set in project"]);
    const committed = (await f.history()).find(entry => entry.status === "committed")!;
    expect(committed).toMatchObject({ refersTo: written.changes[0]!.changeId, git: { head: git(project, "rev-parse", "HEAD").trim() } });

    // Unstaging keeps the value: Uncommitted, and no outside entry.
    await f.change(target, [{ key: "run.transport", layer: "project", op: "set", value: "auto" }]);
    git(project, "restore", "--staged", ".pi/settings.json");
    const unstaged = await transport();
    expect(unstaged.value).toBe("auto");
    expect(label(unstaged, "Uncommitted")).toBeDefined();
    expect((await outsideEntries(f)).length).toBe(baseline);

    // A stash drops Tron's value: one outside entry with Apply again; the live value follows the working tree.
    git(project, "stash", "-q");
    const stashed = await transport();
    expect(stashed.value).toBe("websocket");
    const stash = (await outsideEntries(f)).slice(0, (await outsideEntries(f)).length - baseline);
    expect(stash.map(entry => [entry.key, entry.before, entry.after])).toEqual([["run.transport", "auto", "websocket"]]);
    expect(stash[0]!.git).toMatchObject({ head: git(project, "rev-parse", "HEAD").trim(), branch: "main" });
    const apply = label(stashed, "Changed outside Tron")!.action!;
    expect(apply.kind).toBe("applyAgain");
    // Apply again re-writes and re-stages through the change path.
    const reapplied = await f.service.invoke(client(), "settings.applyAgain", { commandId: commandId(), changeId: apply.changeId }) as unknown as { changes: Array<{ git?: Record<string, unknown> }> };
    expect(reapplied.changes[0]!.git).toMatchObject({ staged: true });
    expect((await read()).transport).toBe("auto");
    expect(git(project, "diff", "--cached", "--name-only").trim()).toBe(".pi/settings.json");
    git(project, "stash", "drop", "-q");

    // `git restore --staged --worktree` drops it again: one more outside entry with Apply again.
    git(project, "restore", "--staged", "--worktree", ".pi/settings.json");
    const restored = await transport();
    expect(restored.value).toBe("websocket");
    expect(label(restored, "Changed outside Tron")!.action!.kind).toBe("applyAgain");
    expect((await outsideEntries(f)).length).toBe(baseline + 2);

    // A branch switch that carries an uncommitted edit changes no value: nothing recorded.
    await f.change(target, [{ key: "run.transport", layer: "project", op: "set", value: "sse" }]);
    git(project, "switch", "-q", "-c", "carry");
    expect((await transport()).value).toBe("sse");
    expect((await outsideEntries(f)).length).toBe(baseline + 2);
    // A branch switch that drops it (committed on one branch only): one outside entry with Apply again.
    git(project, "commit", "-q", "-am", "sse on carry");
    git(project, "switch", "-q", "main");
    const switched = await transport();
    expect(switched.value).toBe("websocket");
    expect(label(switched, "Changed outside Tron")!.action!.kind).toBe("applyAgain");
    expect((await outsideEntries(f))[0]).toMatchObject({ key: "run.transport", before: "sse", after: "websocket", git: { branch: "main" } });

    // A pull (fast-forward from a clone): the change lists its commit; a quiet key does not push,
    // a new package (notify on widening) does.
    const clone = join(f.root, "clone");
    git(f.root, "clone", "-q", project, clone);
    await writeFile(join(clone, ".pi", "settings.json"), `${JSON.stringify({ transport: "auto", packages: ["npm:pulled"] }, null, 4)}\n`);
    git(clone, "commit", "-q", "-am", "upstream settings");
    const pushesBefore = f.pushes.length;
    git(project, "pull", "-q", "--ff-only", clone, "main");
    await transport();
    const pulled = (await outsideEntries(f)).filter(entry => entry.git?.head === git(project, "rev-parse", "HEAD").trim());
    expect(pulled.map(entry => [entry.key, entry.tier]).sort()).toEqual([["run.transport", "quiet"], ["sources.packages", "notify"]]);
    expect(f.pushes.slice(pushesBefore)).toEqual([expect.objectContaining({ message: expect.stringContaining("Packages") })]);
    expect(f.pushes.slice(pushesBefore).some(push => push.message.includes("Transport"))).toBe(false);
    transcript.push({ case: "outside git", detail: await outsideEntries(f) });
  });
});

describe("outside changes to MCP servers and custom models", () => {
  const until = async (done: () => boolean | Promise<boolean>) => {
    for (let attempt = 0; attempt < 100 && !(await done()); attempt += 1) await new Promise(resolve => setTimeout(resolve, 50));
  };
  type Presented = ChangeEntry & { presentation: { label: string; section?: string; display: { before: string; after: string } } };
  const outsideEntries = async (f: Awaited<ReturnType<typeof fixture>>) => (await f.history()).filter(entry => entry.status === "outside") as Presented[];
  const servers = async (f: Awaited<ReturnType<typeof fixture>>, params: Record<string, unknown>) =>
    ((await f.service.invoke(client(), "mcp.list", params)) as { servers: Array<{ name: string; scope: string }> }).servers.map(server => `${server.scope}:${server.name}`).sort();
  const writeJson = async (path: string, value: unknown) => {
    // An editor's rename-replace write.
    await writeFile(`${path}.swp`, `${JSON.stringify(value, null, 2)}\n`);
    await rename(`${path}.swp`, path);
  };

  it("records Mac and Project mcp.json and models.json edits per server or provider by digest, pushes, refreshes their owners, and never records Tron's own writes", async () => {
    const f = await fixture();
    // The CLI child reads the agent directory from the environment, as under the Gateway (gateway-main.ts).
    vi.stubEnv("PI_CODING_AGENT_DIR", f.agentDir);
    f.outside.startWatching(() => {});
    const project = await gitProject(f.root, "mcp-repo");
    const subdirectory = join(project, "packages", "app");
    await mkdir(subdirectory, { recursive: true });
    await f.trust.set(project, true);
    const projectTarget = { kind: "project", cwd: subdirectory };
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "mac" }, keys: ["run.transport"] }); // baselines
    await f.service.invoke(client(), "settings.resolve", { target: projectTarget, keys: ["run.transport"] });
    const baseline = (await outsideEntries(f)).length; // trust was set by hand before the first read

    // Tron's own MCP write (through the bundled CLI) is not an outside change, and refreshes the MCP surface.
    await f.service.invoke(client(), "mcp.add", { commandId: commandId(), scope: "global", server: "tron-added", transport: "http", url: "http://127.0.0.1:1/tron" });
    expect(f.broadcasts).toContainEqual({ topic: "mcp.changed", payload: { scope: "global" } });
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "mac" }, keys: ["run.transport"] });
    expect((await outsideEntries(f)).length).toBe(baseline);
    expect(await servers(f, { scope: "global" })).toEqual(["global:tron-added"]);

    // A hand edit adding a server with a credential header: a file event alone records it by digest and pushes.
    const globalMcp = join(f.agentDir, "mcp.json");
    const current = JSON.parse(await readFile(globalMcp, "utf8")) as { mcpServers: Record<string, unknown> };
    await writeJson(globalMcp, { ...current, mcpServers: { ...current.mcpServers, "hand-added": { url: "http://127.0.0.1:1/hand", headers: { Authorization: "Bearer outside-secret" } } } });
    await until(() => f.pushes.some(push => push.message.includes("MCP server hand-added")));
    const added = (await outsideEntries(f))[0]!;
    expect(added).toMatchObject({ key: "tools.mcp.server", qualifiers: { server: "hand-added" }, op: "set", added: true, tier: "notify", redacted: true,
      layer: "mac", target: { kind: "mac" }, actor: { kind: "outside", id: globalMcp },
      presentation: { label: "MCP server hand-added", section: "tools", display: { before: "Not configured", after: "Added" } } });
    expect(f.pushes.at(-1)).toMatchObject({ title: "Changed outside Tron" });
    expect(f.broadcasts.filter(event => event.topic === "mcp.changed").length).toBe(2);
    expect(JSON.stringify(await f.history())).not.toContain("outside-secret");
    expect(await readFile(f.outside.path, "utf8")).not.toContain("outside-secret");
    // The MCP owner serves the edited file to the app.
    expect(await servers(f, { scope: "global" })).toEqual(["global:hand-added", "global:tron-added"]);
    // Removing the server Tron added is one more entry.
    const afterAdd = JSON.parse(await readFile(globalMcp, "utf8")) as { mcpServers: Record<string, unknown> };
    delete afterAdd.mcpServers["tron-added"];
    await writeJson(globalMcp, afterAdd);
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "mac" }, keys: ["run.transport"] });
    expect((await outsideEntries(f))[0]).toMatchObject({ key: "tools.mcp.server", qualifiers: { server: "tron-added" }, op: "unset",
      presentation: { display: { before: "Configured", after: "Removed" } } });

    // A hand edit just before Tron's own write is recorded, never absorbed into it.
    const beforeTron = JSON.parse(await readFile(globalMcp, "utf8")) as { mcpServers: Record<string, unknown> };
    await writeJson(globalMcp, { ...beforeTron, mcpServers: { ...beforeTron.mcpServers, "edited-before-tron": { url: "http://127.0.0.1:1/before" } } });
    await f.service.invoke(client(), "mcp.add", { commandId: commandId(), scope: "global", server: "tron-second", transport: "http", url: "http://127.0.0.1:1/second" });
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "mac" }, keys: ["run.transport"] });
    const aroundTron = await outsideEntries(f);
    expect(aroundTron.filter(entry => entry.qualifiers?.server === "edited-before-tron").map(entry => entry.op)).toEqual(["set"]);
    expect(aroundTron.some(entry => entry.qualifiers?.server === "tron-second")).toBe(false);

    // A project whose `.pi/` appears later: its creation is seen through the
    // root, and later edits inside it push from the file event alone.
    const late = join(f.root, "late-pi");
    await mkdir(late);
    await f.trust.set(late, true);
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "project", cwd: late }, keys: ["run.transport"] });
    await mkdir(join(late, ".pi"));
    await writeJson(join(late, ".pi", "mcp.json"), { mcpServers: { first: { url: "http://127.0.0.1:1/first" } } });
    await until(() => f.pushes.some(push => push.message.includes("MCP server first")));
    await new Promise(resolve => setTimeout(resolve, 400)); // the rescan that replaces the root watch settles
    await writeJson(join(late, ".pi", "mcp.json"), { mcpServers: { first: { url: "http://127.0.0.1:1/first" }, second: { url: "http://127.0.0.1:1/second" } } });
    await until(() => f.pushes.some(push => push.message.includes("MCP server second")));
    expect(f.pushes.some(push => push.message.includes("MCP server second"))).toBe(true);

    // Project scope follows the Project root, not the subdirectory a chat runs in.
    const chat = await f.registry.create(subdirectory);
    expect(chat.cwd).toBe(await realpath(subdirectory));
    expect(chat.projectDir).toBe(await realpath(project));
    await f.service.invoke(client(), "mcp.add", { commandId: commandId(), scope: "project", cwd: subdirectory, server: "project-tron", transport: "http", url: "http://127.0.0.1:1/project" });
    expect(f.broadcasts.at(-1)).toEqual({ topic: "mcp.changed", payload: { scope: "project", projectDir: await realpath(project) } });
    await expect(readFile(join(subdirectory, ".pi", "mcp.json"), "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    git(project, "add", ".pi/mcp.json");
    git(project, "commit", "-q", "-m", "project mcp");
    const beforePull = (await outsideEntries(f)).length;
    await f.service.invoke(client(), "settings.resolve", { target: projectTarget, keys: ["run.transport"] });
    expect((await outsideEntries(f)).length).toBe(beforePull);
    // A pull adds a server: recorded against the root with its commit, pushed, and served by the project MCP owner.
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
    await until(() => f.pushes.length > pushesBefore);
    expect(f.pushes.slice(pushesBefore)).toEqual([expect.objectContaining({ message: expect.stringContaining("MCP server pulled") })]);
    expect(f.broadcasts).toContainEqual({ topic: "mcp.changed", payload: { scope: "project", projectDir: await realpath(project) } });
    expect(await servers(f, { scope: "project", cwd: subdirectory })).toEqual(expect.arrayContaining(["project:project-tron", "project:pulled"]));

    // Custom models: Tron's save is Tron's; a hand edit of a provider is recorded by digest and pushes.
    const document = { providers: { "tron-provider": { baseUrl: "https://tron-models.invalid/v1", api: "openai-completions", apiKey: "tron-key", models: [{ id: "m" }] } } };
    await f.service.invoke(client(), "models.custom.put", { commandId: commandId(), document });
    expect(f.broadcasts.at(-1)).toEqual({ topic: "models.customChanged", payload: {} });
    await f.service.invoke(client(), "settings.resolve", { target: { kind: "mac" }, keys: ["run.transport"] });
    const beforeModels = (await outsideEntries(f)).length;
    const modelsPath = join(f.agentDir, "models.json");
    const saved = JSON.parse(await readFile(modelsPath, "utf8")) as { providers: Record<string, unknown> };
    await writeJson(modelsPath, { providers: { ...saved.providers, "hand-provider": { baseUrl: "https://hand-models.invalid/v1", api: "openai-completions", apiKey: "outside-model-secret", models: [{ id: "h" }] } } });
    await until(() => f.pushes.some(push => push.message.includes("Custom model provider hand-provider")));
    expect((await outsideEntries(f)).length).toBe(beforeModels + 1);
    expect((await outsideEntries(f))[0]).toMatchObject({ key: "accounts.models.provider", qualifiers: { provider: "hand-provider" }, added: true,
      presentation: { label: "Custom model provider hand-provider", section: "accounts" } });
    expect(f.broadcasts).toContainEqual({ topic: "models.customChanged", payload: {} });
    expect(JSON.stringify(await f.history())).not.toContain("outside-model-secret");
    const served = await f.service.invoke(client(), "models.custom.get", {}) as { document: { providers: Record<string, unknown> } };
    expect(Object.keys(served.document.providers).sort()).toEqual(["hand-provider", "tron-provider"]);
    // A section filter finds the subject entries with their section's keys.
    expect((await f.history({ section: "tools" })).some(entry => entry.key === "tools.mcp.server")).toBe(true);
    transcript.push({ case: "outside mcp and models", detail: await outsideEntries(f) });
  });
});

/**
 * Every declared key at every layer it allows (docs/settings-model.md 4, F1/F4),
 * derived from `KEYS` and the served presentation, never a second key list:
 * `settings.change` as the maintainer, the effective value and source on a target
 * whose top layer that is, the value in the real store bytes through the schema
 * binding, and `settings.undo` restoring the prior value. Keys added later are
 * covered automatically. The per-instance report is a retained artifact.
 */
describe("every key at every allowed layer", () => {
  // One case per layer: each owns its budget and failure, and the per-instance
  // report accumulates across them into one artifact.
  const report: Array<Record<string, unknown>> = [];
  it.each(["chat", "profile", "project", "mac"])("changes, resolves, stores and undoes each declared key instance at the %s layer", async (only) => {
    const f = await fixture();
    const first = f.faux.getModel("first")!, second = f.faux.getModel("second")!;
    // A Mac default model gives model-qualified keys an instance on every target.
    await writeFile(join(f.agentDir, "settings.json"), JSON.stringify({ ...(await f.macDocument()), defaultProvider: first.provider, defaultModel: first.id }));
    const project = await gitProject(f.root, "every");
    await f.trust.set(project, true);
    // An enrolled iPhone gives the Mac Terminal key its one Mac instance.
    await f.macTerminalKeys.set(ENROLLED_IPHONE, macTerminalSampleKey());
    const slot = await f.registry.create(project);
    await slot.setModel(first.provider, first.id);
    const controls = [...CONTROLS];
    const targets: Record<string, Record<string, unknown>> = {
      chat: { kind: "session", sessionId: slot.id }, profile: { kind: "home" }, project: { kind: "project", cwd: project }, mac: { kind: "mac" },
    };
    type Served = { key: string; qualifiers?: Record<string, string>; value: unknown; layer: string;
      presentation: { valueKind: string; options?: Array<{ value: unknown }>; range?: { min: number; max: number }; optionsSource?: { name: string } } };
    const resolve = async (layer: string, key: string) => {
      const resolution = await f.service.invoke(client([slot.id]), "settings.resolve", { target: targets[layer], keys: [key], renderer: { version: 1, controls } }) as unknown as { keys: Served[] };
      return resolution.keys[0];
    };
    const fence = () => { const snapshot = slot.snapshot(); return { runtimeGeneration: snapshot.runtimeGeneration, model: snapshot.model, revision: snapshot.revision }; };
    const differs = (left: unknown, right: unknown) => JSON.stringify(left ?? null) !== JSON.stringify(right ?? null);
    /** A valid value other than the current one, from the served type and its options. */
    const sample = async (layer: string, row: Served): Promise<unknown> => {
      const { valueKind, options, range, optionsSource } = row.presentation;
      // A model queue is a list of the served models, in order.
      if (optionsSource?.name === "catalog.models" && valueKind === "stringList") return [`${second.provider}/${second.id}`, `${first.provider}/${first.id}`];
      if (optionsSource?.name === "catalog.models") return differs(row.value, { provider: second.provider, id: second.id }) ? { provider: second.provider, id: second.id } : { provider: first.provider, id: first.id };
      if (optionsSource?.name === "catalog.thinkingLevels") {
        const served = await f.service.invoke(client([slot.id]), "settings.options", { target: targets[layer], key: row.key, ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) }) as unknown as { options: Array<{ value: unknown }> };
        return served.options.map(option => option.value).find(value => differs(value, row.value));
      }
      if (optionsSource?.name === "catalog.contextWindow") {
        const served = await f.service.invoke(client([slot.id]), "settings.options", { target: targets[layer], key: row.key, ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) }) as unknown as { range: { min: number; max: number } };
        return Math.floor((served.range.min + served.range.max) / 2);
      }
      if (row.key === "permissions.macTerminalKey") return macTerminalSampleKey();
      if (valueKind === "boolean") return row.value !== true;
      if (valueKind === "numberMap") return { [String(options![0]!.value)]: range!.min + 1 };
      if (options?.length) return options.map(option => option.value).find(value => differs(value, row.value));
      if (valueKind === "integer") return Math.floor((range!.min + range!.max) / 2) === row.value ? range!.min : Math.floor((range!.min + range!.max) / 2);
      if (valueKind === "toolSelection") return ["read"];
      if (valueKind === "stringList") return ["sample-entry"];
      if (valueKind === "packages") return ["npm:sample-package"];
      if (valueKind === "text") return "sample-text";
      throw new Error(`No generic sample for ${row.key} (${valueKind})`);
    };
    /** The value in the store's own bytes, read through the schema binding. */
    const stored = async (key: KeyDeclaration, layer: string, qualifiers: Record<string, string>) => {
      const binding = key.layers[layer as "mac"]!;
      const json = async (path: string) => JSON.parse(await readFile(path, "utf8").catch(() => "{}")) as Record<string, unknown>;
      const stores = {
        layers: ["chat", "profile", "project", "mac", "builtin"], mac: await json(join(f.agentDir, "settings.json")),
        project: { root: project, document: await json(join(project, ".pi", "settings.json")), applied: true },
        profile: await json(join(f.tronHome, "gateway", "home", "profile.json")),
        trust: await json(join(f.agentDir, "trust.json")) as Record<string, boolean>,
        macTerminal: await f.macTerminalKeys.read(),
        floors: await json(join(f.tronHome, "gateway", "settings", "floors.json")),
        gateway: await json(join(f.tronHome, "gateway", "settings", "gateway.json")),
        chat: slot.settingsChatLayer(),
      } as unknown as SettingsStores;
      const qualified = binding.store === "pi" && binding.qualified !== undefined && qualifiers.model !== undefined;
      const raw = readBinding(stores, layer as "mac", binding, qualifiers, qualified, key.id);
      // A composing layer may store its selection relative to the layers below.
      return key.type.compose && raw !== undefined ? key.type.compose(composedBelow(stores, key, qualifiers, layer as "mac"), raw) : raw;
    };
    for (const key of KEYS) {
      for (const layer of Object.keys(key.layers).filter(layer => layer === only)) {
        const row = await resolve(layer, key.id);
        const instance = { key: key.id, layer, qualifiers: row?.qualifiers };
        if (!row) { report.push({ ...instance, result: "no instance on its target" }); continue; }
        const value = await sample(layer, row);
        const request = [{ key: key.id, layer, op: "set", value, ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) }];
        const extra = layer === "chat" ? { fence: fence() } : {};
        if (key.writers.length === 0) {
          await expect(f.change(targets[layer]!, request, extra, client([slot.id]))).rejects.toMatchObject({ code: "invalid_request" });
          report.push({ ...instance, result: "refused: no writer" });
          continue;
        }
        let applied: Awaited<ReturnType<typeof f.change>>;
        try {
          // An iPhone enrolls only its own Mac Terminal key, so that key is changed as its device.
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
        expect(after!.layer, `${key.id}@${layer} source`).toBe(layer);
        if (!key.redacted) expect(after!.value, `${key.id}@${layer} value`).toEqual(expectedValue);
        expect(await stored(key, layer, after!.qualifiers ?? row.qualifiers ?? {}), `${key.id}@${layer} store`).toEqual(value);
        const undo = f.service.invoke(client([slot.id]), "settings.undo", { commandId: commandId(), changeId: applied.changes[0]!.changeId, ...(layer === "chat" ? { fence: fence() } : {}) });
        if (key.redacted) {
          // A redacted change has no recorded `before`: never undoable, so unset it directly.
          await expect(undo).rejects.toMatchObject({ code: "conflict" });
          await f.change(targets[layer]!, [{ key: key.id, layer, op: "unset", ...(row.qualifiers ? { qualifiers: row.qualifiers } : {}) }], extra, client([slot.id]));
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
    const gaps = report.filter(entry => entry.layer === only && entry.result !== "round-trip" && entry.result !== "refused: no writer" && !String(entry.result).startsWith("Home applier"));
    expect(gaps).toEqual([]);
  }, 60_000);
});
