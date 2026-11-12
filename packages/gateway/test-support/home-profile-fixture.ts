import { workspaceModule } from "../src/workspace/workspace-module.js";
import { TEST_SETTINGS_SCHEMA } from "./settings-schema.js";
import { displayOwnerOf, createTestRegistry, homeOwnerOf } from "./gateway-registry.js";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { setHomeMemoryModels } from "./settings-dependencies.js";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentSystemPrompt, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, vi } from "vitest";
import { waitFor } from "./wait-for.js";
import { TrustService } from "../src/kernel/resources/trust-service.js";
import { HomeTaskStore, type HomeTaskRecord } from "../src/modules/home/home-task-store.js";
import type { ProfileNoteRecord } from "../src/modules/home/profile-note-contract.js";

import { ProfileStore } from "../src/modules/home/profile-store.js";
import { RuntimeRegistry } from "../src/kernel/session/runtime-registry.js";
import { SettingsStoreAdapter } from "../src/admin/settings-model.js";
import { SettingsChangePath } from "../src/kernel/settings/settings-change.js";
import { SettingsModel } from "../src/kernel/settings/settings-model.js";
import { SettingsChangeRecord } from "../src/kernel/settings/settings-record.js";
import { HomeProfileItems } from "../src/modules/home/home-profile.js";
import { CommandReceiptStore } from "../src/transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../src/transport/gateway-service.js";

export const PROVIDER = "tron-home-profile";
export const MODEL_ID = "chat";
export const MEMORY_PROVIDER = "tron-home-profile-memory";
export const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: "compactor" };
export const MODEL = { provider: PROVIDER, id: MODEL_ID };
let REPORT_PATH = "test-results/home-profile/report.json";
export function profileReportFile(path: string): void { REPORT_PATH = path; }
export const HOME_MARKER = "## Tron Home";
export const PROFILE_HEADING = "## Learned profile";

export const report: { generatedAt: string; cases: Array<Record<string, unknown>> } = { generatedAt: new Date().toISOString(), cases: [] };
export const roots: string[] = [];
export const registries: RuntimeRegistry[] = [];

afterEach(async () => {
  vi.restoreAllMocks();
  await retireFixtures();
});

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

export interface HeldTerminalWrite {
  requested: Promise<void>;
  settling: Promise<void>;
  outcome(): "held" | "accepted" | "refused";
  release(): void;
  finished(): Promise<void>;
}

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

export async function setsTerminal(store: HomeTaskStore, taskId: string, change: (current: HomeTaskRecord) => HomeTaskRecord): Promise<boolean> {
  const current = await store.read(taskId);
  if (!current || current.lifecycle === "terminal") return false;
  try {
    return change(structuredClone(current)).lifecycle === "terminal";
  } catch {
    return false;
  }
}

export function deferred<T = void>() {
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

export type HomeSlot = Awaited<ReturnType<RuntimeRegistry["acquire"]>>;
export interface Captured { home: boolean; systemPrompt: string; messages: Array<Record<string, unknown>>; blob: string }
export interface Context { systemPrompt: string; messages: Array<Record<string, unknown>> }
export type Step = (context: Context) => ReturnType<typeof fauxAssistantMessage>;

export interface Fixture {
  registry: RuntimeRegistry;
  knowledge: ProfileStore;
  store: ProfileStore;
  workspace: ConstructorParameters<typeof ProfileStore>[0];
  project: string;
  sessionId: string;
  slot: HomeSlot;
  home: Step[];
  worker: Step[];
  captured: Captured[];
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
  let knowledge: ProfileStore | undefined;
  let settings: { model: SettingsModel; changes: SettingsChangePath } | undefined;
  const registry = await createTestRegistry({ knowledge: () => knowledge, settings: () => settings, agentDir,
    tronHome,
    idleRuntimeMs: 60_000,
    gatewayModelRuntime: runtime,
    modelRuntimeFactory: async () => runtime,
    trust,
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => async () => fauxAssistantMessage("HOME-PROFILE-LINE"),
  });
  registries.push(registry);
  await registry.initialize();
  await waitFor(() => (registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut() || undefined, "catalog cut", { boundMs: 30_000 });
  await registry.catalog("all");

  const store = new ProfileStore(registry.moduleHost.contract(workspaceModule));
  knowledge = store;
  const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome, trust, modelRuntime: runtime }));
  const record = new SettingsChangeRecord(tronHome);
  const settingsChanges: SettingsChangePath = new SettingsChangePath(settingsModel, record, {
    setTrust: async () => { throw new Error("trust is not changed here"); },
    undoSubject: (entry, context) => new HomeProfileItems(() => knowledge).undo(settingsChanges, entry, context),
  });
  settings = { model: settingsModel, changes: settingsChanges };
  registry.setSettings(settingsModel, settingsChanges);
  const broadcasts: Array<{ topic: string; payload: unknown }> = [];
  const pushes: Array<{ title: string; message: string }> = [];
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime: runtime, trust, settingsModel, settingsChanges, sessions: registry, receipts: new CommandReceiptStore(tronHome),
    notifications: { enqueue: async (push: { title: string; message: string }) => { pushes.push(push); } },
    broadcast: (topic: string, payload: unknown) => broadcasts.push({ topic, payload }),
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
    knowledge, home: homeOwnerOf(registry),
  } as unknown as GatewayServiceDependencies);

  await homeOwnerOf(registry).recoverTasks();
  const designation = await homeOwnerOf(registry).designate({ model: MODEL }, () => MODEL);
  await setHomeMemoryModels(registry, [MEMORY_MODEL]);
  const slot = await registry.acquire(designation.sessionId);
  const state: Fixture = { registry, knowledge, store, workspace: registry.moduleHost.contract(workspaceModule), project, sessionId: designation.sessionId, slot, home: [], worker: [], captured: [], service, record, broadcasts, pushes };
  faux.setResponses(Array.from({ length: 256 }, () => async (context: TranscriptContext) => {
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

export type ProfileDetails =
  | { status: "saved"; action: "learn" | "refine" | "supersede" | "retire"; id: string; revisionId: string; kind?: string; reason?: string }
  | { status: "refused"; action: string; reason: string };

export function profileResults(messages: Array<Record<string, unknown>>): ProfileDetails[] {
  return messages
    .filter((message) => message.role === "toolResult" && message.toolName === "profile")
    .map((message) => message.details as ProfileDetails);
}

export function profileCall(args: Parameters<typeof fauxToolCall>[1], id: string): Step {
  return () => fauxAssistantMessage(fauxToolCall("profile", args, { id }), { stopReason: "toolUse" });
}
export const say = (text: string): Step => () => fauxAssistantMessage(text);

export interface ProfilePage {
  status: "read";
  path: string;
  items: Array<ListedItem & { path: string; provenance: ProfileNoteRecord["provenance"]; content: Extract<ProfileNoteRecord, { kind: "note" }>["content"] }>;
  nextCursor?: string;
}
export function profileReadResult(messages: Array<Record<string, unknown>>, callId: string): ProfilePage {
  const result = messages.find(message => message.role === "toolResult" && message.toolCallId === callId)?.details as ProfilePage | undefined;
  if (result?.status !== "read") throw new Error(`Expected an explicit profile read: ${JSON.stringify(result)}`);
  return result;
}
export async function readProfilePage(f: Fixture, path = "inferred", cursor?: string, includeInactive = false): Promise<ProfilePage> {
  const callId = command("read-profile");
  const turn = await homeActivation(f, `Read profile path ${path}.`, [profileCall({ action: "read", path, ...(cursor ? { cursor } : {}), ...(includeInactive ? { includeInactive: true } : {}) }, callId), say("read")]);
  return profileReadResult(turn.last.messages, callId);
}

export function profileSection(request: { systemPrompt: string; messages: ReadonlyArray<Record<string, unknown>> }): string {
  const start = request.systemPrompt.indexOf(PROFILE_HEADING);
  const turn = request.messages.flatMap(message => Array.isArray(message.content) ? message.content as Array<{ text?: unknown }> : [])
    .map(block => block.text).find((text): text is string => typeof text === "string" && text.startsWith("<turn-state>"));
  if (start < 0 || turn === undefined) throw new Error("the Home request carries no profile section and turn state");
  return `${request.systemPrompt.slice(start)}\n${turn}`;
}

export function homeHead(request: { systemPrompt: string; messages: ReadonlyArray<Record<string, unknown>> }): string {
  const start = request.systemPrompt.indexOf(PROFILE_HEADING);
  return `${request.systemPrompt.slice(0, start)}${profileSection(request)}`;
}

export function latestMaintainerEntryId(f: Fixture): string {
  const entries = f.slot.canonicalSessionEntries() as Array<{ id: string; type: string; message?: { role?: string } }>;
  const user = entries.filter((entry) => entry.type === "message" && entry.message?.role === "user").at(-1);
  if (!user) throw new Error("no maintainer message entry");
  return user.id;
}

export async function profileNotes(f: Fixture): Promise<Array<ProfileNoteRecord & { kind: "note" }>> {
  const records = (await f.store.list({ kind: "note", scope: "personal", includeSuppressed: true })).records;
  return records.filter((record): record is ProfileNoteRecord & { kind: "note" } => record.kind === "note" && record.content.tags?.includes("home-profile") === true);
}

export async function noteAt(f: Fixture, id: string, revisionId?: string): Promise<ProfileNoteRecord & { kind: "note" }> {
  const record = await f.knowledge.read(id, revisionId, true) as ProfileNoteRecord | null;
  if (!record || record.kind !== "note") throw new Error(`no note ${id}`);
  return record;
}

export const maintainer = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => false, isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
let commandSeq = 0;
export function command(label: string): string {
  commandSeq += 1;
  return `home-profile-${label}-${String(commandSeq).padStart(4, "0")}`;
}
export interface ListedItem { id: string; revisionId: string; kind: string; text: string; confirmed: boolean; status: string }
export interface ChangeAnswer {
  status: string;
  changes: Array<{ changeId: string; key: string; qualifiers: { note: string }; before: Record<string, unknown> | null; after: Record<string, unknown> | null }>;
  saved: Array<{ id: string; action: string; supersededId?: string; previousText?: string; kind?: string }>;
}
export interface HistoryEntry {
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
  const entries: HistoryEntry[] = [];
  let cursor: string | undefined;
  do {
    const page = await f.service.invoke(maintainer, "settings.history", { key: "home.profile.item", limit: 200, ...(cursor ? { cursor } : {}) }) as unknown as { entries: HistoryEntry[]; nextCursor?: string };
    entries.push(...page.entries);
    cursor = page.nextCursor;
  } while (cursor);
  return entries;
}
export function change(f: Fixture, changes: Array<Record<string, unknown>>, label: string): Promise<ChangeAnswer> {
  return f.service.invoke(maintainer, "home.profileChange", { commandId: command(label), changes }) as unknown as Promise<ChangeAnswer>;
}
export function undo(f: Fixture, changeId: string, label: string): Promise<{ status: string; changes: ChangeAnswer["changes"] }> {
  return f.service.invoke(maintainer, "settings.undo", { commandId: command(label), changeId }) as unknown as Promise<{ status: string; changes: ChangeAnswer["changes"] }>;
}

