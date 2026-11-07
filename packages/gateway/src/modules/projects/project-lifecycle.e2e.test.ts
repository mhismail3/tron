import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { promisify } from "node:util";
import { createServer } from "node:http";
import WebSocket from "ws";
import { GatewayServer } from "../../transport/server.js";
import { DeviceStore } from "../../security/device-store.js";
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage, type TranscriptContext } from "@earendil-works/pi-ai";
import { disposeFixtures, fixture as homeFixture, reportCall } from "../../../test-support/home-task-fixture.js";
import { displayOwnerOf, homeOwnerOf, projectsOwnerOf } from "../../../test-support/gateway-registry.js";
import { setHomeMemoryModels } from "../../../test-support/settings-dependencies.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { UploadStore } from "../../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../../config.js";
import type { ProjectChangeResult as ChangeResult } from "./project-lifecycle.js";
import type { ExtensionInteraction } from "../../protocol/types.js";
import { maintainerChange } from "../../../test-support/native-change.js";

const exec = promisify(execFile);
const artifact = join(dirname(new URL(import.meta.url).pathname), "../../../test-results/project-lifecycle/report.json");
const evidence: unknown[] = [];
const roots: string[] = [];
afterEach(async () => {
  const disposals = await Promise.allSettled([disposeFixtures()]);
  const removals = await Promise.allSettled(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  const failures = [...disposals, ...removals].flatMap(result => result.status === "rejected" ? [result.reason] : []);
  if (failures.length) throw new AggregateError(failures, "project fixture teardown failed");
});
afterAll(async () => { await mkdir(dirname(artifact), { recursive: true }); await writeFile(artifact, JSON.stringify(evidence, null, 2)); });
let command = 0;
const phone = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-project-lifecycle-")));
  roots.push(root);
  const workspace = join(root, "Workspace");
  await mkdir(workspace);
  let clock = Date.now();
  const f = await homeFixture(false, false, undefined, false, undefined, { projectOptions: { workspace }, settingsNow: () => new Date(clock) });
  const changes = f.settings.settingsChanges;
  await setHomeMemoryModels(f.registry, [f.model]);
  const service = new GatewayService({ display: displayOwnerOf(f.registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: f.tronHome, agentDir: f.agentDir },
    modelRuntime: f.gateway, trust: f.trust, settingsModel: f.settings.settingsModel, settingsChanges: changes, sessions: f.registry, home: homeOwnerOf(f.registry),
    receipts: new CommandReceiptStore(f.tronHome), uploads: new UploadStore(f.tronHome, DEFAULT_MAX_UPLOAD_BYTES),
    notifications: { enqueue: async () => "queued" }, broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (op: () => Promise<unknown>) => op(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const home = await f.registry.acquire(f.home.sessionId);
  const calls = new Map<string, Record<string, unknown>>();
  const results = new Map<string, { isError: boolean; details: ChangeResult; text: string }>();
  const text = (message: { content: unknown }) => typeof message.content === "string" ? message.content : (message.content as Array<{ text?: string }>).map(part => part.text ?? "").join("");
  const responder = (context: TranscriptContext): AssistantMessage => {
    const last = context.messages.at(-1)!;
    if (last.role === "toolResult") {
      const key = [...calls.keys()].findLast(key => context.messages.some(message => message.role === "user" && text(message) === key));
      if (key) results.set(key, { isError: last.isError === true, details: last.details as ChangeResult, text: text(last) });
      return fauxAssistantMessage("Done");
    }
    if (context.messages.some(message => message.role === "user" && text(message).includes("Report ready"))) return fauxAssistantMessage([reportCall("project-ready", "Trusted project admitted")], { stopReason: "toolUse" });
    const turn = context.messages.slice(context.messages.findLastIndex(message => message.role === "assistant") + 1);
    const key = turn.map(text).find(key => calls.has(key));
    return key ? fauxAssistantMessage([fauxToolCall("projects", calls.get(key)!)], { stopReason: "toolUse" }) : fauxAssistantMessage("Outcome noted");
  };
  f.faux.setResponses(Array.from({ length: 100 }, () => responder as never));
  const settled = () => waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null && home.snapshot().phase === "idle" || undefined, "Home idle");
  const cards = new Map<string, { key: string; interaction: Extract<ExtensionInteraction, { method: "change" }> }>();
  // The agent tool only creates. Trust and untrust are paired-native project
  // reviews (agents change trust through the settings tool).
  async function request(args: { action: string; name: string }) {
    if (args.action !== "create") {
      const native = await service.invoke(phone, "projects.change", { commandId: `native-request-${++command}`,
        action: args.action, name: args.name, reason: "Lifecycle boundary proof" }).then(
        details => ({ isError: false, text: "Exact native review", details: details as unknown as ChangeResult }),
        (error: Error) => ({ isError: true, text: error.message, details: { status: "review" as const, changes: [] } as ChangeResult }));
      evidence.push({ args, ...native });
      return native;
    }
    await (homeOwnerOf(f.registry) as unknown as { wakeDrain?: Promise<void> }).wakeDrain;
    await settled();
    const key = `project request ${++command}`;
    calls.set(key, { reason: "Lifecycle boundary proof", name: args.name });
    await home.prompt(key);
    const result = await waitFor(() => results.get(key) ?? (() => {
      const interaction = home.snapshot().extensionPresentation.pendingInteractions[0];
      if (interaction?.method !== "change") return undefined;
      cards.set(interaction.review.digest, { key, interaction });
      return { isError: false, text: "Exact native review", details: { status: "review" as const, review: interaction.review, changes: [] } };
    })(), "project result or exact native review");
    if (result.details.status !== "review") await settled();
    evidence.push({ args, ...result });
    return result;
  }
  const decide = async (result: ChangeResult, approved = true): Promise<ChangeResult> => {
    const card = cards.get(result.review!.digest);
    if (card) {
      const { interaction } = card;
      await service.invoke(phone, "extension.respond", { commandId: `project-native-${++command}`, sessionId: home.id,
        interactionId: interaction.id, hostEpoch: interaction.hostEpoch, presentationRevision: interaction.presentationRevision,
        value: { digest: result.review!.digest, approved } });
      const answer = await waitFor(() => results.get(card.key), "native project callback result");
      await settled();
      if (answer.isError) throw new Error(answer.text);
      return answer.details;
    }
    if (!approved) throw new Error("Direct native review cancellation sends no mutation");
    const intent = result.intent as { operation: string; name: string };
    return service.invoke(phone, "projects.change", { commandId: `project-native-${++command}`, action: intent.operation,
      name: intent.name, reason: result.review!.reason, confirmation: { digest: result.review!.digest, intent } }) as unknown as Promise<ChangeResult>;
  };
  const path = (name: string) => join(workspace, name);
  const git = async (name: string, args: string[]) => (await exec("git", ["-C", path(name), ...args])).stdout.trim();
  async function create(name: string) {
    const result = await request({ action: "create", name });
    expect(result.isError, result.text).toBe(false);
    expect(result.details.status).toBe("review");
    return result.details;
  }
  return { ...f, root, workspace, path, git, request, create, decide, changes, service, settled, advance: (ms: number) => { clock += ms; } };
}

type NativeRow = { name: string; path: string; trust: { effectiveDecision: boolean | null; savedDecision: boolean | null } | null;
  eligibility: Record<"trust" | "untrust", { allowed: boolean; code?: string; reason?: string }> };
type NativePage = { workspace: string; projects: NativeRow[]; nextCursor: string | null };

describe("Gateway project lifecycle", () => {
  it("native requests are receipt-backed UI requests and only a separate canonical tap applies each lifecycle effect", async () => {
    const f = await fixture();
    const list = () => f.service.invoke(phone, "projects.list", {}) as unknown as Promise<NativePage>;
    const ask = (action: string, name: string, extra: Record<string, unknown> = {}) => f.service.invoke(phone, "projects.change",
      { commandId: `native-project-${++command}`, action, name, reason: "Native lifecycle boundary", ...extra }) as Promise<ChangeResult>;
    expect((await list()).projects).toEqual([]);
    const args = { commandId: `native-create-${++command}`, action: "create", name: "native-original", reason: "Create from paired iPhone" };
    const pending = await f.service.invoke(phone, "projects.change", args) as unknown as ChangeResult;
    expect(pending.status).toBe("review");
    expect((await list()).projects).toEqual([]);
    expect(await f.service.invoke(phone, "projects.change", args)).toEqual(pending);
    expect(await f.service.invoke(phone, "projects.change", { ...args, reason: "Different payload" })).toEqual(pending);
    expect((await f.decide(pending)).status).toBe("applied");
    await writeFile(f.path("native-original/data"), "retained native bytes");
    // A review alone changes nothing; only the separate confirmation applies it.
    const unconfirmed = await ask("untrust", "native-original");
    expect(unconfirmed.status).toBe("review");
    expect((await list()).projects.find(row => row.name === "native-original")?.trust?.effectiveDecision).toBe(true);
    await f.decide(await ask("untrust", "native-original"));
    expect((await list()).projects.find(row => row.name === "native-original")?.trust?.effectiveDecision).toBe(false);
    await f.decide(await ask("trust", "native-original"));
    expect((await list()).projects.find(row => row.name === "native-original")?.trust?.effectiveDecision).toBe(true);
    expect(await readFile(f.path("native-original/data"), "utf8")).toBe("retained native bytes");
    evidence.push({ nativeJourney: { pending, unconfirmed } });
  });

  it.each(["create", "untrust"] as const)("confirms the exact %s review after JSON object keys are reordered", async action => {
    const f = await fixture();
    if (action !== "create") await f.decide(await f.create("wire-source"));
    const fields = { action, name: "wire-source", reason: "Native JSON round trip" };
    const pending = await f.service.invoke(phone, "projects.change", {
      ...fields, commandId: `wire-review-${++command}`,
    }) as unknown as ChangeResult;
    const intent = JSON.parse(JSON.stringify(Object.fromEntries(Object.entries(pending.intent!).reverse())));
    const before = await readdir(f.workspace);
    await expect(f.service.invoke(phone, "projects.change", { ...fields, commandId: `wire-wrong-${++command}`,
      confirmation: { digest: "0".repeat(64), intent } })).rejects.toMatchObject({ code: "conflict" });
    await expect(f.service.invoke(phone, "projects.change", { ...fields, commandId: `wire-malformed-${++command}`,
      confirmation: "not an object" })).rejects.toMatchObject({ code: "invalid_request", message: "Project confirmation is invalid" });
    expect(await readdir(f.workspace)).toEqual(before);
    const result = await f.service.invoke(phone, "projects.change", { ...fields, commandId: `wire-confirm-${++command}`,
      confirmation: { digest: pending.review!.digest, intent } }) as unknown as ChangeResult;
    expect(result.status).toBe("applied");
    const destination = f.path("wire-source");
    expect(await readFile(join(destination, ".git/HEAD"), "utf8")).toBe("ref: refs/heads/main\n");
    expect((await f.trust.inspect(destination)).effectiveDecision).toBe(action === "create");
    evidence.push({ reorderedNativeIntent: { action, pending, result } });
  });

  it("native eligibility reads preserve trust and an idle session, and refuse unsupported saved folders", async () => {
    const f = await fixture();
    await f.decide(await f.create("native-idle"));
    const slot = await f.registry.create(f.path("native-idle"));
    const inspect = (cwd: string) => f.service.invoke(phone, "projects.inspect", { cwd }) as unknown as Promise<NativeRow>;
    const before = await f.trust.inspect(slot.cwd);
    const row = await inspect(slot.cwd);
    expect(row.trust).toMatchObject({ savedDecision: true, effectiveDecision: true });
    expect(row.eligibility.untrust.allowed).toBe(true);
    expect(row.eligibility.trust.allowed).toBe(true);
    await mkdir(f.path("not a supported name"));
    await symlink(f.root, f.path("linked-native"));
    const unsupported = await inspect(f.root);
    expect(Object.values(unsupported.eligibility).every(item => !item.allowed)).toBe(true);
    const linked = await inspect(f.path("linked-native"));
    expect(linked.trust).toBeNull();
    expect(Object.values(linked.eligibility).every(item => !item.allowed)).toBe(true);
    const names: string[] = [];
    let after: string | null = null;
    do {
      const page = await f.service.invoke(phone, "projects.list", { limit: 1, ...(after ? { after } : {}) }) as unknown as NativePage;
      expect(page.projects.length).toBeLessThanOrEqual(1);
      names.push(...page.projects.map(item => item.name));
      after = page.nextCursor;
    } while (after);
    expect(names).toEqual(["linked-native", "native-idle", "not a supported name"]);
    expect(await f.trust.inspect(slot.cwd)).toEqual(before);
    expect(slot.isDisposed).toBe(false);
    evidence.push({ nativeEligibility: { row, unsupported, linked, names } });
  });

  it("native socket cancellation ends the actual Git read process without affecting accepted requests", async () => {
    const f = await fixture();
    const created = await f.service.invoke(phone, "projects.change", { commandId: `native-socket-${++command}`,
      action: "create", name: "native-socket", reason: "Real socket read cancellation" }) as unknown as ChangeResult;
    await f.decide(created);
    const realGit = (await exec("/usr/bin/which", ["git"])).stdout.trim();
    const bin = join(f.root, "gate-bin"), marker = join(f.root, "git-reader-pid");
    await mkdir(bin);
    await writeFile(join(bin, "git"), `#!/usr/bin/env node
const fs = require("node:fs"), cp = require("node:child_process");
const args = process.argv.slice(2);
if (args.includes("worktree")) {
  require("node:net").createServer().listen(0, "127.0.0.1", () => fs.writeFileSync(${JSON.stringify(marker)}, String(process.pid)));
} else {
  const result = cp.spawnSync(${JSON.stringify(realGit)}, args, { stdio: "inherit" });
  process.exit(result.status ?? 1);
}
`, { mode: 0o700 });
    vi.stubEnv("PATH", `${bin}:${process.env.PATH}`);
    const devices = new DeviceStore(f.tronHome, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(f.tronHome, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const probe = createServer();
    await new Promise<void>(resolve => probe.listen(0, "127.0.0.1", resolve));
    const port = (probe.address() as { port: number }).port;
    await new Promise<void>(resolve => probe.close(() => resolve()));
    const cancelled: string[] = [];
    const gateway = new GatewayServer({ display: displayOwnerOf(f.registry), host: "127.0.0.1", port, maxFrameBytes: 1_048_576,
      devices, sessions: f.registry, service: f.service, uploads: new UploadStore(f.tronHome, DEFAULT_MAX_UPLOAD_BYTES),
      auth: { detachClient: () => {}, cancelOwner: () => {} } as never,
      logger: { log: (_level: string, _message: string, metadata?: Record<string, unknown>) => {
        if (metadata?.event === "rpc.cancelled") cancelled.push(String(metadata.method));
      } } as never });
    await gateway.listen();
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: Array<{ type?: string; id?: string }> = [];
    socket.on("message", raw => frames.push(JSON.parse(raw.toString())));
    try {
      await new Promise<void>(resolve => socket.once("open", resolve));
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 8 }));
      await waitFor(() => frames.some(frame => frame.type === "hello") || undefined, "native socket authenticated");
      for (const method of ["projects.inspect", "projects.list"]) {
        await rm(marker, { force: true });
        socket.send(JSON.stringify({ type: "request", id: method, method, params: method === "projects.inspect" ? { cwd: f.path("native-socket") } : {} }));
        const pid = await waitFor(async () => {
          try { return Number(await readFile(marker, "utf8")) || undefined; }
          catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
        }, "actual native Git reader started");
        socket.send(JSON.stringify({ type: "cancel", id: method }));
        const fence = `fence-${method}`;
        socket.send(JSON.stringify({ type: "request", id: fence, method: "system.info", params: {} }));
        await waitFor(() => frames.some(frame => frame.id === fence) || undefined, "cancel frame processed before later answer");
        expect(cancelled).toContain(method);
        await waitFor(() => {
          try { process.kill(pid, 0); return undefined; }
          catch (error) { if ((error as NodeJS.ErrnoException).code === "ESRCH") return true; throw error; }
        }, "cancelled Git reader exited");
      }
    } finally {
      socket.close();
      await gateway.close();
    }
    expect((await f.trust.inspect(f.path("native-socket"))).effectiveDecision).toBe(true);
    evidence.push({ nativeSocketCancellation: cancelled });
  });

  it("Cancel and Stop close the native continuation without filesystem effects or invented audit outcomes", async () => {
    const f = await fixture();
    const before = (await f.changes.record.page({ limit: 50 })).entries;
    const declined = await f.create("cancelled-create");
    expect((await f.decide(declined, false)).status).toBe("declined");
    await f.create("stopped-create");
    await (await f.registry.acquire(f.home.sessionId)).abort("agent");
    await f.settled();
    expect(await readdir(f.workspace)).toEqual([]);
    expect((await f.changes.record.page({ limit: 50 })).entries).toEqual(before);
  });

  it("retains the native response fence when a failed create's audit publication also fails", async () => {
    const f = await fixture(), audit = f.changes.record.path, retained = audit + "-retained";
    const realGit = (await exec("/usr/bin/which", ["git"])).stdout.trim();
    const bin = join(f.root, "failing-init-bin"), counter = join(f.root, "init-calls");
    await mkdir(bin);
    // Real Git for every read; `init` blocks the canonical audit file, then fails.
    await writeFile(join(bin, "git"), `#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = init ]; then
    printf attempt >> ${JSON.stringify(counter)}
    mv ${JSON.stringify(audit)} ${JSON.stringify(retained)}
    printf blocked > ${JSON.stringify(audit)}
    exit 7
  fi
done
exec ${JSON.stringify(realGit)} "$@"
`, { mode: 0o700 });
    const reviewed = await f.create("uncertain-init");
    vi.stubEnv("PATH", `${bin}:${process.env.PATH}`);
    try {
      await expect(f.decide(reviewed)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
    } finally { vi.unstubAllEnvs(); }
    expect((await f.trust.inspect(f.path("uncertain-init"))).effectiveDecision).toBe(false);
    await rm(audit); await rename(retained, audit);
    const directory = join(f.tronHome, "gateway", "command-receipts");
    const receipts = await Promise.all((await readdir(directory)).filter(name => name.endsWith(".json")).map(async name =>
      JSON.parse(await readFile(join(directory, name), "utf8"))));
    const pending = receipts.filter(receipt => receipt.method === "extension.respond" && receipt.status === "pending");
    expect(pending).toHaveLength(1);
    await expect(f.service.invoke(phone, "extension.respond", { commandId: pending[0].commandId })).rejects.toMatchObject({
      code: "conflict", details: { outcomeUnknown: true } });
    expect(await readFile(counter, "utf8")).toBe("attempt");
    evidence.push({ failedAuditReceipt: pending[0], partialCreateRetained: true });
  });

  it("native folder paths and cursors are exact and never trim into another project", async () => {
    const f = await fixture();
    await f.decide(await f.create("exact-native"));
    await mkdir(f.path("exact-native "));
    await mkdir(f.path("z-native"));
    const row = await f.service.invoke(phone, "projects.inspect", { cwd: f.path("exact-native ") }) as unknown as NativeRow;
    expect(row.path).toBe(f.path("exact-native "));
    expect(Object.values(row.eligibility).every(item => !item.allowed)).toBe(true);
    const first = await f.service.invoke(phone, "projects.list", { limit: 1 }) as unknown as NativePage;
    const second = await f.service.invoke(phone, "projects.list", { limit: 1, after: first.nextCursor }) as unknown as NativePage;
    const third = await f.service.invoke(phone, "projects.list", { limit: 1, after: second.nextCursor }) as unknown as NativePage;
    expect([first, second, third].flatMap(page => page.projects.map(project => project.name))).toEqual(["exact-native", "exact-native ", "z-native"]);
    expect(third.nextCursor).toBeNull();
    await expect(f.service.invoke(phone, "projects.change", { commandId: `native-exact-${++command}`,
      action: "untrust", name: "exact-native ", reason: "Never reinterpret an unsupported folder" })).rejects.toMatchObject({ code: "invalid_request" });
    expect((await f.trust.inspect(f.path("exact-native"))).effectiveDecision).toBe(true);
  });

  it("projects.list costs one Home task-store pass however long the task history is, and keeps rows exact", async () => {
    const f = await fixture();
    const names = ["alpha", "bravo", "charlie"];
    for (const name of names) {
      await mkdir(f.path(name));
      await exec("git", ["-C", f.path(name), "init", "--initial-branch=main"]);
    }
    const list = async () => {
      const started = performance.now();
      const page = await f.service.invoke(phone, "projects.list", {}) as unknown as NativePage;
      return { page, ms: performance.now() - started };
    };
    const best = async <T extends { ms: number }>(read: () => Promise<T>) => {
      const first = await read(), second = await read();
      return first.ms <= second.ms ? first : second;
    };
    // Calibrated on this host and run, so load changes neither side of the bound.
    const bare = await best(list);
    // Production holds ~900 settled tasks (about 13 KB each) and `projects.list` scales with them.
    const store = (homeOwnerOf(f.registry) as unknown as { tasks: { store: { initialize(): Promise<boolean>; put(record: unknown, expected: number | null): Promise<unknown> } } }).tasks.store;
    await store.initialize();
    const intent = { text: "x".repeat(8_000) };
    await store.put({ version: 1, taskId: "history-0", revision: 1, homeId: "home", generation: 1, routeGeneration: 1, intent,
      intentDigest: createHash("sha256").update(intent.text).digest("hex"), target: f.root, grantRef: null, scopeRef: null,
      lifecycle: "pending", sessionId: null, operationId: null, stopIntent: null, spend: null, reportRef: null, terminalEvidence: null, wake: null }, null);
    // This is a persisted-history read oracle, not 300 sequential admissions.
    // Derive fixture bytes/name from one real publication; production readers
    // still validate every record. Do not copy the store's filename algorithm.
    const directory = join(f.tronHome, "gateway", "home", "tasks");
    const templateName = (await readdir(directory)).find(name => name.endsWith("-history-0.json"))!;
    const template = JSON.parse(await readFile(join(directory, templateName), "utf8"));
    const publications = await Promise.allSettled(Array.from({ length: 299 }, async (_, offset) => {
      const taskId = `history-${offset + 1}`;
      await writeFile(join(directory, templateName.replace(/-history-0\.json$/, `-${taskId}.json`)),
        JSON.stringify({ ...template, taskId }), { mode: 0o600 });
    }));
    const publicationFailure = publications.find(result => result.status === "rejected");
    if (publicationFailure?.status === "rejected") throw publicationFailure.reason;
    expect((await homeOwnerOf(f.registry).taskList({ limit: 1 })).counts.active).toBe(300);
    const pass = await best(async () => {
      const started = performance.now();
      await homeOwnerOf(f.registry).taskList({ limit: 50 });
      return { ms: performance.now() - started };
    });
    const withHistory = await best(list);
    expect(withHistory.page.projects.map(row => row.name)).toEqual(names);
    expect(withHistory.page.projects.every(row => row.eligibility.untrust.allowed && row.eligibility.trust.allowed)).toBe(true);
    evidence.push({ projectsListHistory: { projects: names.length, tasks: 300, bareMs: Math.round(bare.ms), oneTaskPassMs: Math.round(pass.ms), listMs: Math.round(withHistory.ms) } });
    // A task pass per project eligibility check (and per page of tasks) is the measured defect: one pass is the whole budget.
    expect(withHistory.ms).toBeLessThan(bare.ms + 8 * pass.ms);
  });

  it("native reads cancel on disconnect while accepted commands survive and cannot spoof their actor or approval", async () => {
    const f = await fixture();
    const controller = new AbortController();
    const client = { ...phone, signal: controller.signal };
    const accepted = f.service.invoke(client, "projects.change", { commandId: `native-disconnect-${++command}`,
      action: "create", name: "native-disconnect", reason: "Accepted commands retain receipt ownership" });
    controller.abort();
    const pending = await accepted as unknown as ChangeResult;
    expect(pending.status).toBe("review");
    await expect(f.service.invoke(client, "projects.list", {})).rejects.toMatchObject({ name: "AbortError" });
    for (const extra of [{ actor: { kind: "ui", id: "forged" } }, { approved: true }]) {
      await expect(f.service.invoke(phone, "projects.change", { commandId: `native-spoof-${++command}`,
        action: "trust", name: "native-disconnect", reason: "Not caller authority", ...extra })).rejects.toMatchObject({ code: "invalid_request" });
    }
    expect(await readdir(f.workspace)).toEqual([]);
    expect((await f.changes.record.page({ limit: 50 })).entries.filter(entry => entry.key === "project.lifecycle")).toEqual([]);
  });

  it("Home creates an untrusted main repository, approval grants trust and the real delegate owner immediately admits work", async () => {
    const f = await fixture();
    await f.decide(await f.create("slim-key"));
    await f.decide((await f.request({ action: "untrust", name: "slim-key" })).details);
    expect(await f.git("slim-key", ["symbolic-ref", "--short", "HEAD"])).toBe("main");
    expect((await f.trust.inspect(f.path("slim-key"))).effectiveDecision).toBe(false);
    await expect(homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "untrusted-task", target: f.path("slim-key"), intent: "Report a finite result" }).then(handle => handle.completion)).rejects.toThrow(/trust/i);
    const pending = (await f.request({ action: "trust", name: "slim-key" })).details;
    const directReview = await f.service.invoke(phone, "projects.change", { commandId: `direct-trust-${++command}`,
      action: "trust", name: "slim-key", reason: "Cannot spoof the native actor" }) as unknown as ChangeResult;
    await expect(projectsOwnerOf(f.registry)!.request({ action: "trust", name: "slim-key", reason: "Cannot spoof the native actor" },
      { kind: "home", id: f.home.sessionId }, `forged-trust-${++command}`,
      { confirmation: { digest: directReview.review!.digest, intent: directReview.intent } })).rejects.toThrow(/paired native UI/i);
    expect((await f.decide(pending)).status).toBe("applied");
    expect((await f.trust.inspect(f.path("slim-key"))).effectiveDecision).toBe(true);
    const task = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "trusted-task", target: f.path("slim-key"), intent: "Report ready" });
    expect(task.taskId).toBeTruthy();
    const completed = await task.completion;
    expect(completed.lifecycle).toBe("terminal");
    evidence.push({ delegated: completed });
    expect(completed.reportRef?.resultId, JSON.stringify(completed)).toBe("project-ready");
  });

  it("refuses traversal, existing files/directories and project symlinks", async () => {
    const f = await fixture();
    for (const name of ["../escape", "/tmp/escape", ".archive", "a/b", "a b"]) expect((await f.request({ action: "create", name })).isError).toBe(true);
    await f.decide(await f.create("existing"));
    expect((await f.request({ action: "create", name: "existing" })).isError).toBe(true);
    await writeFile(f.path("existing-file"), "preserve");
    expect((await f.request({ action: "create", name: "existing-file" })).isError).toBe(true);
    await symlink(f.path("existing"), f.path("linked"));
    expect((await f.request({ action: "trust", name: "linked" })).isError).toBe(true);
    expect(await readFile(f.path("existing-file"), "utf8")).toBe("preserve");
  });

  it("busy real project work and linked worktrees refuse trust changes, including work starting after submission", async () => {
    const f = await fixture();
    await f.decide(await f.create("busy"));
    const pending = await f.request({ action: "untrust", name: "busy" });
    expect(pending.isError, pending.text).toBe(false);
    let release!: () => void;
    let entered = false;
    const held = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { entered = true; await held; return fauxAssistantMessage("Worker finished"); }]);
    const worker = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "busy-worker", target: f.path("busy"), intent: "Hold this real worker active" });
    await waitFor(() => entered || undefined, "worker model entered");
    const direct = () => projectsOwnerOf(f.registry)!.request({ action: "trust", name: "busy", reason: "Busy boundary" }, { kind: "home", id: f.home.sessionId, sessionId: f.home.sessionId }, `busy-request-${++command}`);
    try {
      await expect(f.decide(pending.details)).rejects.toThrow(/superseded|session|busy/i);
      await expect(direct()).rejects.toThrow(/session|busy|worker/i);
      await expect(projectsOwnerOf(f.registry)!.request({ action: "untrust", name: "busy", reason: "Active worker boundary" }, { kind: "home", id: f.home.sessionId }, `untrust-busy-${++command}`)).rejects.toThrow(/session|busy|worker/i);
    } finally { release(); await worker.completion; }
    await f.git("busy", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"]);
    await f.git("busy", ["worktree", "add", "-b", "worker", join(f.root, "worker-tree")]);
    await expect(projectsOwnerOf(f.registry)!.request({ action: "untrust", name: "busy", reason: "Worktree boundary" }, { kind: "home", id: f.home.sessionId }, `worktree-request-${++command}`)).rejects.toThrow(/worktree/i);
  });

  it("pins new exact roots under an enclosing repository and default-always trust", async () => {
    const f = await fixture();
    await maintainerChange(f.service, phone, "settings.change", { commandId: `default-trust-${++command}`, target: { kind: "global" },
      changes: [{ key: "permissions.defaultProjectTrust", layer: "global", op: "set", value: "always" }] });
    await exec("git", ["-C", f.workspace, "init", "--initial-branch=main"]);
    const ancestor = await f.trust.inspect(f.workspace);
    const pending = await f.create("nested");
    expect(await readdir(f.workspace)).not.toContain("nested");
    await f.decide(pending);
    expect((await f.trust.inspect(f.path("nested"))).projectDir).toBe(f.path("nested"));
    expect((await f.trust.inspect(f.workspace)).savedDecision).toBe(ancestor.savedDecision);
    const slot = await f.registry.create(f.path("nested"));
    expect(slot.cwd).toBe(f.path("nested"));
  });

  it("identity replacement supersedes approval and workspace symlinks refuse", async () => {
    const f = await fixture();
    await f.decide(await f.create("replaced"));
    const pending = (await f.request({ action: "trust", name: "replaced" })).details;
    await rename(f.path("replaced"), join(f.root, "retained-source"));
    await mkdir(join(f.root, "outside"));
    await symlink(join(f.root, "outside"), f.path("replaced"));
    await expect(f.decide(pending)).rejects.toThrow(/superseded|symlink/i);
    expect((await f.trust.inspect(join(f.root, "outside"))).savedDecision).toBe(null);
    await rename(f.workspace, join(f.root, "relocated-workspace"));
    await symlink(join(f.root, "relocated-workspace"), f.workspace);
    expect((await f.request({ action: "create", name: "escaped" })).isError).toBe(true);
  });

  it("a busy refusal before reload never reports a nonexistent acquired fence or changes trust", async () => {
    const f = await fixture();
    await f.decide(await f.create("busy-reload"));
    const project = await f.registry.create(f.path("busy-reload"));
    let entered = false;
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { entered = true; await held; return fauxAssistantMessage("Released"); }]);
    const prompt = project.prompt("Hold the real runtime");
    try {
      await waitFor(() => entered || undefined, "busy reload runtime entered");
      const error = await f.trust.setAndApply(project.cwd, false,
        inspection => f.registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false),
        inspection => f.registry.commitProjectReload(inspection.projectDir),
        inspection => f.registry.abortProjectReload(inspection.projectDir)).catch(error => error as Error);
      expect(error).toMatchObject({ code: "internal", details: { failure: "Stop active sessions before changing project trust", rollbackFailure: "Stop active sessions before changing project trust" } });
      expect((await f.trust.inspect(project.cwd)).effectiveDecision).toBe(true);
      expect((await f.registry.create(project.cwd)).cwd).toBe(project.cwd);
      expect((error as Error).message).not.toMatch(/remains fenced/);
    } finally { release(); await prompt; }
  });

  it("a failed trust application with successful compensation restores trusted project resources without retiring the session", async () => {
    const f = await fixture();
    await f.decide(await f.create("restored-source"));
    const source = f.path("restored-source");
    await mkdir(join(source, ".pi", "extensions"), { recursive: true });
    await writeFile(join(source, ".pi", "extensions", "restoration-probe.ts"), `export default function(pi) {
  pi.registerTool({ name: "restoration_probe", label: "Restoration", description: "Trusted resource proof",
    parameters: { type: "object", properties: {} },
    execute: async () => ({ content: [{ type: "text", text: "trusted resource" }] }) });
}`);
    const slot = await f.registry.create(source);
    const tools = () => (slot as unknown as { runtime: { session: { getAllTools(): Array<{ name: string }> } } }).runtime.session.getAllTools().map(tool => tool.name);
    expect(tools()).toContain("restoration_probe");
    let applications = 0;
    await expect(f.trust.setAndApply(source, false, async inspection => {
      await f.registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false);
      if (++applications === 1) throw new Error("Fixture failure after the first native reload");
    }, inspection => f.registry.commitProjectReload(inspection.projectDir),
    inspection => f.registry.abortProjectReload(inspection.projectDir))).rejects.toThrow(/first native reload/);
    expect(applications).toBe(2);
    expect((await f.trust.inspect(source)).effectiveDecision).toBe(true);
    expect(slot.isDisposed).toBe(false);
    expect(tools()).toContain("restoration_probe");
    expect((await f.registry.create(source)).cwd).toBe(source);
  });

  it("failed application and compensation retire uncertain runtimes and release native project admission", async () => {
    const f = await fixture();
    await f.decide(await f.create("aborted-reload"));
    const source = f.path("aborted-reload");
    const slot = await f.registry.create(source);
    const start = f.events.length;
    try {
      await expect(f.trust.setAndApply(source, false, async inspection => {
        await f.registry.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false);
        throw new Error("Fixture failure after native reload, including compensation");
      }, inspection => f.registry.commitProjectReload(inspection.projectDir),
      inspection => f.registry.abortProjectReload(inspection.projectDir))).rejects.toMatchObject({ code: "internal" });
      expect((await f.registry.create(source)).cwd).toBe(source);
      expect(slot.isDisposed).toBe(true);
      await expect(slot.prompt("An aborted frame must not execute")).rejects.toMatchObject({ code: "conflict" });
      expect(f.events.slice(start).filter(event => event.topic === "session.resourcesChanged")).toEqual([]);
      expect((await f.trust.inspect(source)).effectiveDecision).toBe(true);
    } finally {
      // Fault-injection cleanup on the known-bad base, not production recovery.
      if (!slot.isDisposed) await f.registry.commitProjectReload(source);
    }
  });


});
