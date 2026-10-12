import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "./trust-service.js";
import { SettingsChangePath, SettingsModel } from "./settings-model.js";
import { SettingsChangeRecord, type ChangeEntry } from "./settings-record.js";
import { SettingsApprovals } from "./settings-approvals.js";
import { SettingsRiskEvaluator, type SettingsRiskInput } from "./settings-risk.js";
import { JEV_MAX_ESTIMATED_CHARGE_CENTS } from "../knowledge/jev-client.js";
import type { Resolution } from "./settings-resolver.js";
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
const roots: string[] = [];
const registries: RuntimeRegistry[] = [];
const transcript: Array<{ case: string; detail: unknown }> = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map(registry => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  await mkdir(dirname(ARTIFACT), { recursive: true });
  await writeFile(ARTIFACT, `${JSON.stringify(transcript, null, 2)}\n`);
});

const GIT_ENV = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid" };
const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, stdio: "pipe", env: GIT_ENV }).toString();

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
  const settingsModel = new SettingsModel({ agentDir, tronHome, trust, modelRuntime });
  const record = new SettingsChangeRecord(tronHome, options.segmentEntries);
  const settingsChanges = new SettingsChangePath(settingsModel, record, new SettingsApprovals(tronHome), {
    ...(options.assessRisk ? { assessRisk: options.assessRisk } : {}),
    setTrust: async (project, decision) => {
      return trust.setAndApply(project, decision,
        async inspection => { await registry.reloadProject(inspection.cwd, inspection.effectiveDecision === true, false); },
        async inspection => { await registry.commitProjectReload(inspection.cwd); });
    },
  }, agentDir);
  const broadcasts: Array<{ topic: string; payload: unknown }> = [];
  const service = new GatewayService({
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime, trust, settingsModel, settingsChanges, sessions: registry, receipts: new CommandReceiptStore(tronHome),
    broadcast: (topic: string, payload: unknown) => broadcasts.push({ topic, payload }),
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
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
  return { root, tronHome, agentDir, trust, registry, service, record, settingsChanges, broadcasts, change, history, macDocument, faux };
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
      .rejects.toMatchObject({ code: "conflict", details: { current: 10, after: 8 } });
    expect((await f.macDocument()).retry).toEqual({ maxRetries: 10 });

    // A redacted key records only "changed", and its change is not undoable.
    const proxy = await f.change({ kind: "mac" }, [{ key: "run.httpProxy", layer: "mac", op: "set", value: "http://proxy.invalid:3128" }]);
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

    // An ignored .pi: written, not staged, with the reason.
    const ignored = await gitProject(f.root, "ignored");
    await f.trust.set(ignored, true);
    git(ignored, "rm", "-q", "--cached", ".pi/settings.json");
    await writeFile(join(ignored, ".gitignore"), ".pi/\n");
    git(ignored, "add", ".gitignore");
    git(ignored, "commit", "-q", "-m", "ignore .pi");
    const local = await f.change({ kind: "project", cwd: ignored }, transport("websocket"));
    expect(local.changes[0]!.git).toMatchObject({ staged: false, reason: ".pi is ignored by git" });
    expect(JSON.parse(await readFile(join(ignored, ".pi", "settings.json"), "utf8"))).toEqual({ transport: "websocket" });

    // No repository: written, not staged.
    const plain = join(f.root, "plain");
    await mkdir(plain);
    await f.trust.set(plain, true);
    const unstaged = await f.change({ kind: "project", cwd: plain }, transport("sse"));
    expect(unstaged.changes[0]!.git).toMatchObject({ staged: false, reason: "not in a git repository" });
    expect(JSON.parse(await readFile(join(plain, ".pi", "settings.json"), "utf8"))).toEqual({ transport: "sse" });

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
    const resolved = await f.service.invoke(client(), "settings.resolve", { target: { kind: "mac" } }) as unknown as PresentedResolution;
    const recent = resolved.sections.find(section => section.id === "run")!.summary.recent;
    expect(recent.map(entry => entry.changeId)).toEqual([first.changes[0]!.changeId]);
    transcript.push({ case: "sparse filtered paging", detail: { newest, middle, oldest, recent } });
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
