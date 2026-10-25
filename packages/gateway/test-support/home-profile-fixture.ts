import { createTestRegistry } from "./gateway-registry.js";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { setHomeMemoryModels } from "./settings-dependencies.js";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentSystemPrompt, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, vi } from "vitest";
import { waitFor } from "./wait-for.js";
import { TrustService } from "../src/admin/trust-service.js";
import { HomeTaskStore, type HomeTaskRecord } from "../src/home/home-task-store.js";
import type { KnowledgeRecord } from "../src/knowledge/knowledge-contract.js";
import { KnowledgeService } from "../src/knowledge/knowledge-service.js";
import { KnowledgeStore } from "../src/knowledge/knowledge-store.js";
import { RuntimeRegistry } from "../src/sessions/runtime-registry.js";
import { SettingsChangePath, SettingsModel } from "../src/admin/settings-model.js";
import { SettingsChangeRecord } from "../src/admin/settings-record.js";
import { SettingsApprovals } from "../src/admin/settings-approvals.js";
import { HomeProfileItems } from "../src/home/home-profile.js";
import { CommandReceiptStore } from "../src/transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../src/transport/gateway-service.js";

export const PROVIDER = "tron-home-profile";
export const MODEL_ID = "chat";
const MEMORY_PROVIDER = "tron-home-profile-memory";
const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: "compactor" };
export const MODEL = { provider: PROVIDER, id: MODEL_ID };
let REPORT_PATH = "test-results/home-profile/report.json";
export function profileReportFile(name: string): void { REPORT_PATH = `test-results/home-profile/${name}`; }
/** The instruction head every Home request carries; a worker's request never does. */
const HOME_MARKER = "## Tron Home";
export const PROFILE_HEADING = "## Learned profile";

export const report: { generatedAt: string; cases: Array<Record<string, unknown>> } = { generatedAt: new Date().toISOString(), cases: [] };
const roots: string[] = [];
const registries: RuntimeRegistry[] = [];

afterEach(async () => {
  vi.restoreAllMocks();
  await retireFixtures();
});

/** Disposes every registry, then removes every root this file created. Each registry settles its work
 * first, in gateway-main's shutdown order (cancel, settle, dispose): a delegated Home task's terminal
 * write is work the registry owns, and disposing first closes the stores it writes through (#1020).
 * A failed disposal may leave work live under a root, so every root is kept as the diagnostic. */
export async function retireFixtures(): Promise<void> {
  const disposals = await Promise.allSettled(registries.splice(0).map(async (registry) => {
    await registry.administrativeWorkRegistry.requestCancellation();
    await registry.administrativeWorkRegistry.waitUntilSettled();
    await registry.dispose();
  }));
  const kept = roots.splice(0);
  const failures = disposals.flatMap((result) => result.status === "rejected" ? [result.reason] : []);
  if (failures.length > 0) throw new Error(`home-profile teardown failed; kept ${kept.join(", ")} for diagnosis`, { cause: new AggregateError(failures, "registry disposal failed") });
  await Promise.all(kept.map((root) => rm(root, { recursive: true, force: true })));
}

interface HeldTerminalWrite {
  /** Resolves once the task's terminal write has been requested and is held. */
  requested: Promise<void>;
  /** Resolves once teardown has begun waiting on the registry's work to settle. An observed barrier, not a timer. */
  settling: Promise<void>;
  /** `held` until the write settles; then whether the store accepted or refused it. */
  outcome(): "held" | "accepted" | "refused";
  /** Lets the held write proceed. Idempotent. */
  release(): void;
  /** Resolves once a requested write has settled; immediately when none was requested. */
  finished(): Promise<void>;
}

/** Holds the delegated task's terminal write at the Home task store boundary, before the store applies
 * it, so the write is live when teardown starts (#1020). Only the update that transitions the task to
 * terminal is held; once released it runs through the store's own mutex and publication. The registry's
 * `waitUntilSettled` is observed, not replaced: it is the real settle step teardown must wait on. */
export function holdTerminalWrite(registry: RuntimeRegistry): HeldTerminalWrite {
  const update = HomeTaskStore.prototype.update;
  const work = registry.administrativeWorkRegistry;
  const settle = work.waitUntilSettled.bind(work);
  const requested = deferred();
  const settling = deferred();
  const released = deferred();
  const settled = deferred();
  let requestedWrite = false;
  let outcome: "held" | "accepted" | "refused" = "held";
  vi.spyOn(work, "waitUntilSettled").mockImplementation(() => {
    settling.resolve();
    return settle();
  });
  vi.spyOn(HomeTaskStore.prototype, "update").mockImplementation(async function (this: HomeTaskStore, taskId, change) {
    if (!(await setsTerminal(this, taskId, change)) || requestedWrite) return update.call(this, taskId, change);
    requestedWrite = true;
    requested.resolve();
    await released.promise;
    try {
      const record = await update.call(this, taskId, change);
      outcome = "accepted";
      return record;
    } catch (error) {
      outcome = "refused";
      throw error;
    } finally {
      settled.resolve();
    }
  });
  return {
    requested: requested.promise,
    settling: settling.promise,
    outcome: () => outcome,
    release: () => released.resolve(),
    finished: () => requestedWrite ? settled.promise : Promise.resolve(),
  };
}

/** Whether `change` transitions the task to terminal. The store applies `change` under its own mutex, so
 * it is evaluated here on a copy first. A change that refuses the record is left to the store to refuse. */
async function setsTerminal(store: HomeTaskStore, taskId: string, change: (current: HomeTaskRecord) => HomeTaskRecord): Promise<boolean> {
  const current = await store.read(taskId);
  if (!current || current.lifecycle === "terminal") return false;
  try {
    return change(structuredClone(current)).lifecycle === "terminal";
  } catch {
    return false;
  }
}

function deferred<T = void>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "home-profile"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`home-profile: ${report.cases.length} cases -> ${REPORT_PATH}\n`);
});

export function recordCase(name: string, data: Record<string, unknown>): void {
  report.cases.push({ name, ...data });
}

// ---- fixture --------------------------------------------------------------------

type HomeSlot = Awaited<ReturnType<RuntimeRegistry["acquire"]>>;
interface Captured { home: boolean; systemPrompt: string; messages: Array<Record<string, unknown>>; blob: string }
interface Context { systemPrompt: string; messages: Array<Record<string, unknown>> }
export type Step = (context: Context) => ReturnType<typeof fauxAssistantMessage>;

interface Fixture {
  registry: RuntimeRegistry;
  knowledge: KnowledgeService;
  store: KnowledgeStore;
  project: string;
  sessionId: string;
  slot: HomeSlot;
  /** Scripted replies, consumed in order per side (Home or worker). */
  home: Step[];
  worker: Step[];
  captured: Captured[];
  /** The Gateway the maintainer's iPhone talks to, over the same registry and change path. */
  service: GatewayService;
  record: SettingsChangeRecord;
  broadcasts: Array<{ topic: string; payload: unknown }>;
  pushes: Array<{ title: string; message: string }>;
}

export async function fixture(label: string): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-profile-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const project = join(root, "project");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(project, { recursive: true })]);
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  const faux = fauxProvider({ provider: PROVIDER, models: [{ id: MODEL_ID }], tokensPerSecond: 1_000_000, tokenSize: { min: 10, max: 10 } });
  const memoryFaux = fauxProvider({ provider: MEMORY_PROVIDER, models: [{ id: MEMORY_MODEL.id, reasoning: false }] });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  runtime.registerNativeProvider(memoryFaux.provider);
  const trust = new TrustService(agentDir);
  await trust.set(project, true);
  const broadcasts: Array<{ topic: string; payload: unknown }> = [];
  const registry = await createTestRegistry({ agentDir,
    tronHome,
    idleRuntimeMs: 60_000,
    gatewayModelRuntime: runtime,
    modelRuntimeFactory: async () => runtime,
    trust,
    broadcast: (_sessionId, topic, payload) => broadcasts.push({ topic, payload }),
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => async () => fauxAssistantMessage("HOME-PROFILE-LINE"),
  });
  registries.push(registry);
  await registry.initialize();
  await waitFor(() => (registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut() || undefined, "catalog cut", { boundMs: 30_000 });
  await registry.catalog("all");

  const store = new KnowledgeStore(registry.knowledgeWorkspace(), () => {});
  const knowledge = new KnowledgeService(store);
  registry.setKnowledgeService(knowledge);
  // The one settings change path, wired as gateway-main wires it: Home's profile tool
  // and the maintainer's home.profileChange share its profile applier and record.
  const settingsModel = new SettingsModel({ agentDir, tronHome, trust, modelRuntime: runtime });
  const record = new SettingsChangeRecord(tronHome);
  const settingsChanges = new SettingsChangePath(settingsModel, record, new SettingsApprovals(tronHome), {
    setTrust: async () => { throw new Error("trust is not changed here"); },
    profile: new HomeProfileItems(() => knowledge),
  }, agentDir);
  registry.setSettings(settingsModel, settingsChanges);
  const pushes: Array<{ title: string; message: string }> = [];
  const service = new GatewayService({
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime: runtime, trust, settingsModel, settingsChanges, sessions: registry, receipts: new CommandReceiptStore(tronHome),
    notifications: { enqueue: async (push: { title: string; message: string }) => { pushes.push(push); } },
    broadcast: (topic: string, payload: unknown) => broadcasts.push({ topic, payload }),
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
    knowledge, home: registry.homeOwner(),
  } as unknown as GatewayServiceDependencies);

  // Task recovery runs after listen, as in gateway-main; delegation is refused before it.
  await registry.recoverHomeTasks();
  const designation = await registry.homeOwner().designate({ model: MODEL }, () => MODEL);
  await setHomeMemoryModels(registry, [MEMORY_MODEL]);
  const slot = await registry.acquire(designation.sessionId);
  const state: Fixture = { registry, knowledge, store, project, sessionId: designation.sessionId, slot, home: [], worker: [], captured: [], service, record, broadcasts, pushes };
  // One route answers every provider request. Home and worker requests are told
  // apart by the Home instruction head, so each script is independent of interleaving.
  faux.setResponses(Array.from({ length: 256 }, () => async (context: TranscriptContext) => {
    // The provider's transcript carries the request's system prompt as its head message.
    const systemPrompt = getCurrentSystemPrompt(context.messages);
    const messages = context.messages as unknown as Array<Record<string, unknown>>;
    const home = systemPrompt.includes(HOME_MARKER);
    state.captured.push({
      home, systemPrompt, messages,
      blob: JSON.stringify(context.messages, (key, value) => key === "timestamp" ? 0 : value),
    });
    const step = (home ? state.home : state.worker).shift();
    if (!step) throw new Error(`no scripted ${home ? "Home" : "worker"} reply for this request`);
    return step({ systemPrompt, messages });
  }));
  return state;
}

/** One Home activation driven by `steps`. Returns the first Home request it made
 * (the prompt it carried) and its last one (the transcript it closed with). */
export async function homeActivation(f: Fixture, input: string, steps: Step[]): Promise<{ first: Captured; last: Captured }> {
  f.home.push(...steps);
  const before = f.captured.length;
  await f.slot.prompt(input);
  await waitFor(() => (f.slot.snapshot().configurationBlocker === null && f.home.length === 0) || undefined, "Home activation settled", { boundMs: 30_000 });
  const homeRequests = f.captured.slice(before).filter((request) => request.home);
  const first = homeRequests[0];
  const last = homeRequests.at(-1);
  if (!first || !last) throw new Error("the activation made no Home request");
  return { first, last };
}

type ProfileDetails =
  | { status: "saved"; action: "learn" | "refine" | "supersede" | "retire"; id: string; revisionId: string; kind?: string; reason?: string }
  | { status: "refused"; action: string; reason: string };

/** The `profile` tool results a request carries, oldest first. */
export function profileResults(messages: Array<Record<string, unknown>>): ProfileDetails[] {
  return messages
    .filter((message) => message.role === "toolResult" && message.toolName === "profile")
    .map((message) => message.details as ProfileDetails);
}

/** A scripted Home reply that calls `profile` with `args`. */
export function profileCall(args: Parameters<typeof fauxToolCall>[1], id: string): Step {
  return () => fauxAssistantMessage(fauxToolCall("profile", args, { id }), { stopReason: "toolUse" });
}
export const say = (text: string): Step => () => fauxAssistantMessage(text);

/** The profile section of a system prompt, from its heading to the end. */
export function profileSection(systemPrompt: string): string {
  const start = systemPrompt.indexOf(PROFILE_HEADING);
  return start < 0 ? "" : systemPrompt.slice(start);
}

/** The entry of the maintainer message that started the latest activation. */
export function latestMaintainerEntryId(f: Fixture): string {
  const entries = f.slot.canonicalSessionEntries() as Array<{ id: string; type: string; message?: { role?: string } }>;
  const user = entries.filter((entry) => entry.type === "message" && entry.message?.role === "user").at(-1);
  if (!user) throw new Error("no maintainer message entry");
  return user.id;
}

export async function profileNotes(f: Fixture): Promise<Array<KnowledgeRecord & { kind: "note" }>> {
  const records = (await f.store.list({ kind: "note", scope: "personal", includeSuppressed: true })).records;
  return records.filter((record): record is KnowledgeRecord & { kind: "note" } => record.kind === "note" && record.content.tags?.includes("home-profile") === true);
}

export async function noteAt(f: Fixture, id: string, revisionId?: string): Promise<KnowledgeRecord & { kind: "note" }> {
  const record = await f.knowledge.invoke({ operation: "knowledge.read", request: { id, ...(revisionId ? { revisionId } : {}), includeSuppressed: true } }) as KnowledgeRecord | null;
  if (!record || record.kind !== "note") throw new Error(`no note ${id}`);
  return record;
}

// ---- maintainer RPC ------------------------------------------------------------

export const maintainer = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => false, isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
let commandSeq = 0;
/** A fresh command ID per request, so no replay is mistaken for a new change. */
export function command(label: string): string {
  commandSeq += 1;
  return `home-profile-${label}-${String(commandSeq).padStart(4, "0")}`;
}
interface ListedItem { id: string; revisionId: string; kind: string; text: string; confirmed: boolean; status: string }
interface ChangeAnswer {
  status: string;
  changes: Array<{ changeId: string; key: string; qualifiers: { note: string }; before: Record<string, unknown> | null; after: Record<string, unknown> | null }>;
  saved: Array<{ id: string; action: string; supersededId?: string; previousText?: string; kind?: string }>;
}
interface HistoryEntry {
  changeId: string;
  key: string;
  actor: { kind: string };
  qualifiers?: { note?: string };
  group?: { id: string; size: number };
  undoOf?: string;
  before?: Record<string, unknown>;
  after?: Record<string, unknown>;
  presentation: { label: string; actor: string; display: { before: string; after: string } };
}

export async function listed(f: Fixture): Promise<ListedItem[]> {
  return (await f.service.invoke(maintainer, "home.profileList", {}) as unknown as { items: ListedItem[] }).items;
}
export async function itemText(f: Fixture, text: string): Promise<ListedItem> {
  const item = (await listed(f)).find(candidate => candidate.text === text);
  if (!item) throw new Error(`no profile item "${text}"`);
  return item;
}
export async function history(f: Fixture): Promise<HistoryEntry[]> {
  return (await f.service.invoke(maintainer, "settings.history", { key: "home.profile.item", limit: 200 }) as unknown as { entries: HistoryEntry[] }).entries;
}
export function change(f: Fixture, changes: Array<Record<string, unknown>>, label: string): Promise<ChangeAnswer> {
  return f.service.invoke(maintainer, "home.profileChange", { commandId: command(label), changes }) as unknown as Promise<ChangeAnswer>;
}
export function undo(f: Fixture, changeId: string, label: string): Promise<{ status: string; changes: ChangeAnswer["changes"] }> {
  return f.service.invoke(maintainer, "settings.undo", { commandId: command(label), changeId }) as unknown as Promise<{ status: string; changes: ChangeAnswer["changes"] }>;
}

// ---- cases ----------------------------------------------------------------------

