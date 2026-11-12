import { TEST_SETTINGS_SCHEMA } from "./settings-schema.js";
import { chmod, cp, mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SettingsStoreAdapter } from "../src/admin/settings-model.js";
import { SettingsChangePath } from "../src/kernel/settings/settings-change.js";
import { SettingsModel } from "../src/kernel/settings/settings-model.js";
import { SettingsChangeRecord } from "../src/kernel/settings/settings-record.js";
import { TrustService } from "../src/kernel/resources/trust-service.js";
import { SwiftAppStore } from "../src/modules/apps/swift-app-store.js";
import { AutomationStore } from "../src/automations/automation-store.js";
import { HomeOwner } from "../src/modules/home/home-owner.js";
import { homeTaskPolicy } from "../src/modules/home/home-task-worker-choice.js";
import { HomeProfileItems, readHomeProfile } from "../src/modules/home/home-profile.js";
import { HomeTaskStore, taskIntentDigest } from "../src/modules/home/home-task-store.js";
import { DisplayArtifactStore } from "../src/display/display-artifact-store.js";
import { EPISODIC_DEFAULTS } from "../src/episodic/episodic-contract.js";
import { EpisodicMemory } from "../src/episodic/episodic-memory.js";
import { EpisodicStore } from "../src/episodic/episodic-store.js";

import { episodicHostAssigned, singleChapterSource } from "./episodic-chapter-source.js";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { ProfileStore } from "../src/modules/home/profile-store.js";
import { UploadStore } from "../src/machine/upload-store.js";
import { NotificationGrantStore } from "../src/notifications/grant-store.js";
import { RecentModelStore } from "../src/providers/recent-models.js";
import { DeviceStore } from "../src/security/device-store.js";
import { MacTerminalService } from "../src/security/mac-terminal-service.js";
import { RunMarkerStore } from "../src/kernel/run/run-markers.js";
import { SessionArchiveStore } from "../src/sessions/session-archive-store.js";
import { SessionAttentionStore } from "../src/kernel/projection/session-attention-store.js";
import { CommandReceiptStore } from "../src/transport/command-receipts.js";
import { TronWorkspace } from "../src/workspace/tron-workspace.js";

const MACHINE = "corpus-machine";
const IDENTITY = "device:corpus-phone";

export const CORPUS_IDS = {
  session: "01a00000-0000-7000-8000-00000000c0a1",
  otherSession: "01a00000-0000-7000-8000-00000000c0a2",
  automation: "corpus-reminder",
  task: "corpus-task",
  note: "corpus-note",
  source: "corpus-source",
  app: "corpus-counter",
};

export interface StoreSpec {
  readonly module: string;
  readonly name: string;
  readonly paths: readonly string[];
  readonly live?: string;
  readonly renewed?: readonly string[];
  readonly reproducible?: true | ((path: string, text: string) => string);
  record(home: string): Promise<void>;
  read(home: string): Promise<unknown>;
}

async function withWorkspace<T>(home: string, use: (workspace: TronWorkspace) => Promise<T>): Promise<T> {
  const value = new TronWorkspace(home);
  await value.initialize();
  try { return await use(value); } finally { await value.dispose(); }
}

async function settingsPath(home: string, knowledge?: ProfileStore) {
  const agentDir = join(home, "agent");
  await mkdir(agentDir, { recursive: true });
  const trust = new TrustService(agentDir);
  const modelRuntime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
  const model = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome: home, trust, modelRuntime, macTerminalKeys: new MacTerminalService(home, { launchAgentDirectory: join(home, "agents") }) }));
  const record = new SettingsChangeRecord(home);
  const path: SettingsChangePath = new SettingsChangePath(model, record, {
    setTrust: async () => { throw new Error("The settings corpus sets no trust"); },
    ...(knowledge ? { undoSubject: (entry, context) => new HomeProfileItems(() => knowledge).undo(path, entry, context) } : {}),
  });
  return { model, record, path };
}

function homeOwner(home: string, workspace: TronWorkspace): HomeOwner {
  return new HomeOwner({
    tronHome: home,
    trust: new TrustService(join(home, "agent")),
    workspace,
    taskPolicy: homeTaskPolicy({ settings: () => undefined, modelQueueOf: async () => [], modelRuntime: () => undefined }, { inspect: async () => { throw new Error("unused task target"); } }),
    runtimes: {
      sessionFile: async () => undefined,
      sessionPresent: async (id: string) => id === CORPUS_IDS.session,
      serializeSessionMutation: async <T>(_id: string, commit: () => Promise<T>) => commit(),
      replaceRuntimeForProfile: async (_sessionId: string, commit: () => Promise<void>) => commit(),
      noteSessionListChanged: () => {},
      liveRuntime: () => undefined,
    } as never, agentDir: "/nonexistent-agent-dir",
    sessions: {
      createHomeSession: async () => CORPUS_IDS.session,
      chapterMetrics: async () => ({ bytes: 2_048, entries: 4, quiescent: true }), hasConversation: async () => false,
      homeModel: async () => undefined, chooseHomeModel: async () => {}, retireHomeRuntimes: async () => {},
      wakeHome: () => async () => { throw new Error("The corpus Home is never woken"); },
    },
    memoryModels: async () => [],
    memorySummarizer: () => async () => { throw new Error("The corpus Home summarizes nothing"); },
    knowledge: () => undefined,
  });
}

export const STORES: readonly StoreSpec[] = [
  {
    module: "gateway/admin", name: "store-settings",
    paths: ["agent/settings.json", "gateway/settings"],
    reproducible: true,
    async record(home) {
      const { path } = await settingsPath(home);
      const ui = { kind: "ui" as const, id: IDENTITY };
      const agent = { kind: "agent" as const, id: CORPUS_IDS.session, sessionId: CORPUS_IDS.session };
      await path.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 6 }], { actor: ui, reason: "Corpus: retry longer" });
      await path.change({ kind: "global" }, [{ key: "context.images.block", layer: "global", op: "set", value: true }], { actor: ui, reason: "Corpus: block images" });
      await path.change({ kind: "global" }, [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 2 }], { actor: agent, reason: "Corpus: retry less" });
      await path.change({ kind: "global" }, [{ key: "context.images.block", layer: "global", op: "set", value: false }], { actor: agent, reason: "Corpus: allow images" });
    },
    async read(home) {
      const { model, record } = await settingsPath(home);
      return { history: (await record.page({ limit: 50 })).entries,
        resolved: await model.resolve({ kind: "global" }, undefined, ["run.retry.maxRetries", "context.images.block"]) };
    },
  },
  {
    module: "gateway/security", name: "store-devices",
    paths: ["gateway/devices.json", "gateway/local-auth.json"],
    renewed: ["gateway/enrollment.json"],
    async record(home) {
      const devices = new DeviceStore(home, MACHINE);
      await devices.initialize();
      await devices.pair((await devices.ensureEnrollment()).code, "Corpus phone");
      const [paired] = await devices.listDevices();
      await devices.setCustomLabel(paired!.id, "Corpus labelled phone");
    },
    async read(home) {
      const devices = new DeviceStore(home, MACHINE);
      await devices.initialize();
      return { devices: await devices.listDevices() };
    },
  },
  {
    module: "gateway/transport", name: "store-command-receipts",
    paths: ["gateway/command-receipts"],
    async record(home) {
      const receipts = new CommandReceiptStore(home);
      await receipts.execute(IDENTITY, "session.rename", "corpus-rename-0001", async () => ({ updated: true }));
      await receipts.execute(IDENTITY, "settings.change", "corpus-settings-0001", async () => ({ status: "applied", tier: "quiet" }));
      await receipts.dispose();
    },
    async read(home) {
      const receipts = new CommandReceiptStore(home);
      try {
        return {
          rename: await receipts.status(IDENTITY, "session.rename", "corpus-rename-0001"),
          settings: await receipts.status(IDENTITY, "settings.change", "corpus-settings-0001"),
          missing: await receipts.status(IDENTITY, "session.rename", "corpus-missing-0001"),
        };
      } finally {
        await receipts.dispose();
      }
    },
  },
  {
    module: "gateway/session-catalog", name: "store-session-archive-attention",
    paths: ["gateway/session-archive.json", "gateway/session-attention.json"],
    async record(home) {
      const archive = new SessionArchiveStore(home);
      await archive.initialize();
      await archive.archive(CORPUS_IDS.otherSession);
      const attention = new SessionAttentionStore(home);
      await attention.initialize();
      await attention.complete(CORPUS_IDS.session, "corpus-completion-1");
      await attention.complete(CORPUS_IDS.otherSession, "corpus-completion-2");
      await attention.set(CORPUS_IDS.otherSession, false);
    },
    async read(home) {
      const archive = new SessionArchiveStore(home);
      await archive.initialize();
      const attention = new SessionAttentionStore(home);
      await attention.initialize();
      return Object.fromEntries([CORPUS_IDS.session, CORPUS_IDS.otherSession].map((id) => [id, {
        archivedAt: archive.archivedAt(id) ?? null,
        attention: attention.projection(id),
        unacknowledged: attention.hasUnacknowledgedCompletion(id),
      }]));
    },
  },
  {
    module: "gateway/run", name: "store-run-markers",
    paths: ["gateway/runtime-markers"],
    async record(home) {
      const markers = new RunMarkerStore(home);
      await markers.mark(CORPUS_IDS.session, "corpus-operation-1");
    },
    async read(home) {
      const markers = new RunMarkerStore(home);
      return { evidence: Object.fromEntries(await markers.evidence()), interrupted: [...await markers.interruptedSessionIds()] };
    },
  },
  {
    module: "gateway/notifications", name: "store-notifications",
    paths: ["gateway/notifications.json"],
    async record(home) {
      const grants = new NotificationGrantStore(home);
      await grants.initialize();
    },
    async read(home) {
      const grants = new NotificationGrantStore(home);
      await grants.initialize();
      return { document: await grants.snapshot() };
    },
  },
  {
    module: "gateway/providers", name: "store-model-recents",
    paths: ["gateway/model-recents.json"],
    async record(home) {
      const recents = new RecentModelStore(home);
      await recents.initialize();
      await recents.record("corpus-provider", "corpus-model-a");
      await recents.record("corpus-provider", "corpus-model-b");
      await recents.dispose();
    },
    async read(home) {
      const recents = new RecentModelStore(home);
      await recents.initialize();
      try { return { entries: recents.entries() }; } finally { await recents.dispose(); }
    },
  },
  {
    module: "gateway/automations", name: "store-automations",
    paths: ["gateway/automations"],
    async record(home) {
      const automations = new AutomationStore(home);
      await automations.initialize();
      await automations.create({
        name: "Corpus reminder", activation: "enabled",
        target: { kind: "existingSession", sessionId: CORPUS_IDS.session },
        trigger: { kind: "once", at: "2099-01-01T09:00:00.000Z" },
        action: { kind: "notification", message: "Corpus reminder text" },
        provenance: { kind: "local" },
      });
    },
    async read(home) {
      const automations = new AutomationStore(home);
      await automations.initialize();
      return { status: automations.status(), list: automations.list(), records: automations.snapshot() };
    },
  },
  {
    module: "gateway/machine", name: "store-uploads",
    paths: ["gateway/uploads", "gateway/upload-bodies", "gateway/upload-objects", "gateway/upload-imports"],
    live: "absolute body paths and hard-linked objects",
    async record(home) {
      const uploads = new UploadStore(home, 1_048_576);
      const saved = await uploads.save("corpus-note.txt", "text/plain", Buffer.from("corpus upload body\n"));
      await uploads.materialize([saved.id], CORPUS_IDS.session);
    },
    async read(home) {
      const uploads = new UploadStore(home, 1_048_576);
      const ids = (await readdir(join(home, "gateway", "uploads"), { withFileTypes: true }))
        .filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
      const leases = [];
      for (const id of ids) {
        const lease = await uploads.acquire(id);
        const chunks: Buffer[] = [];
        for await (const chunk of lease.stream) chunks.push(chunk as Buffer);
        await lease.release();
        leases.push({ name: lease.name, mimeType: lease.mimeType, size: lease.size, body: Buffer.concat(chunks).toString("utf8") });
      }
      if (leases.length === 0) throw new Error("The upload store read no upload");
      return { uploads: leases };
    },
  },
  {
    module: "gateway/home", name: "store-home-tasks",
    paths: ["gateway/home/tasks", "workspace/state/home"],
    record: (home) => withWorkspace(home, async (workspace) => {
      const tasks = new HomeTaskStore(home, workspace);
      await tasks.initialize();
      const intent = { text: "Corpus finite task" };
      await tasks.put({ version: 1, taskId: CORPUS_IDS.task, revision: 1, homeId: "corpus-home", generation: 1, routeGeneration: 1,
        intent, intentDigest: taskIntentDigest(intent.text), target: "/corpus/project",
        grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null, stopIntent: null,
        spend: null, reportRef: null, terminalEvidence: null, wake: null } as never, null);
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const tasks = new HomeTaskStore(home, workspace);
      await tasks.initialize();
      return { task: await tasks.read(CORPUS_IDS.task), page: await tasks.page({ limit: 10 }) };
    }),
  },
  {
    module: "gateway/apps", name: "store-swift-apps",
    paths: ["workspace/state/apps"],
    record: (home) => withWorkspace(home, async (workspace) => {
      const destination = join((await workspace.describe()).root, "state/apps");
      await cp(join(import.meta.dirname, "../test-fixtures/tron-corpus/home/workspace/state/apps"), destination, { recursive: true });
      await chmod(destination, 0o700);
      const directory = join(destination, CORPUS_IDS.app); await chmod(directory, 0o700);
      for (const name of ["app.json", "App.swift", "data.sqlite"]) await chmod(join(directory, name), 0o600);
      await workspace.markFeatureInitialized("apps");
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const apps = new SwiftAppStore(workspace, () => { throw new Error("The v1 corpus has no display offers"); });
      return { list: await apps.list(), app: await apps.get(CORPUS_IDS.app), state: await apps.state(CORPUS_IDS.app) };
    }),
  },
  {
    module: "gateway/home", name: "store-home-designation",
    paths: ["gateway/home/home.json", "gateway/home/workspace"],
    record: (home) => withWorkspace(home, async (workspace) => {
      const owner = homeOwner(home, workspace);
      await owner.initialize();
      await owner.designate({ model: { provider: "corpus-provider", id: "corpus-model" } }, () => ({ provider: "corpus-provider", id: "corpus-default" }));
      await rm(join(home, "agent", "trust.json"), { force: true });
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const owner = homeOwner(home, workspace);
      await owner.initialize();
      const status = await owner.status();
      return {
        status: { ...status, taskRecovery: undefined, hostPressure: undefined, workers: undefined },
        chapters: await owner.chapterList(),
        designation: Object.fromEntries([CORPUS_IDS.session, CORPUS_IDS.otherSession].map((id) => [id, { homeChapter: owner.isHomeChapter(id) }])),
      };
    }),
  },
  {
    module: "gateway/episodic", name: "store-episodic",
    paths: ["workspace/state/episodic", "gateway/workspace-state/episodic-initialized.json"],
    reproducible: episodicHostAssigned,
    record: (home) => withWorkspace(home, async (workspace) => {
      const root = await mkdtemp(join(tmpdir(), "tron-corpus-episodic-"));
      try {
        const manager = SessionManager.create("/corpus/project", join(root, "sessions"), { id: CORPUS_IDS.session });
        for (let index = 0; index < 6; index += 1) {
          manager.appendMessage({ role: "user", content: `Corpus question ${index}: ${"q".repeat(400)}`, timestamp: 1_767_225_600_000 + index } satisfies Message);
          manager.appendMessage(fauxAssistantMessage([{ type: "text", text: `Corpus answer ${index}: ${"a".repeat(400)}` }]));
        }
        const sessionId = manager.getSessionId();
        const memory = await EpisodicMemory.open({
          workspace, sessionId, sessionSource: singleChapterSource(sessionId, manager.getSessionFile()!),
          summarizer: async (request) => {
            const stretch = /<stretch>\n([\s\S]*)\n<\/stretch>/u.exec(request.turns[0]!.text)![1]!;
            return fauxAssistantMessage(`Corpus summary: ${stretch.replace(/\s+/gu, " ").trim().slice(-120)}`);
          },
          limits: { viewBytes: 4_096, jobs: 1, retryMs: 0 },
        });
        try { await memory.entriesCommitted(sessionId); } finally { await memory.dispose(); }
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const sessions = await readdir(join(home, "workspace", "state", "episodic"));
      const stores = [];
      for (const sessionId of sessions.sort()) {
        const snapshot = await new EpisodicStore(workspace, sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes).read();
        stores.push({ ...snapshot, messages: [...snapshot.messages.values()], nodes: [...snapshot.nodes.entries()] });
      }
      if (stores.length === 0) throw new Error("The episodic store read no session");
      return { stores };
    }),
  },
  {
    module: "gateway/home", name: "store-home-profile",
    paths: ["workspace/files/Profile.json", "gateway/settings"],
    live: "current-format Profile notes and their Changes entries recorded by their owning stores",
    record: (home) => withWorkspace(home, async (workspace) => {
      const knowledge = new ProfileStore(workspace);
      const { path } = await settingsPath(home, knowledge);
      const profile = new HomeProfileItems(() => knowledge);
      const context = (commandId: string) => ({ actor: { kind: "ui" as const, id: IDENTITY }, author: { kind: "maintainer" as const }, commandId, reason: "Corpus profile" });
      const learned = await profile.change(path, [
        { action: "learn", kind: "preference", text: "Prefers concise answers" },
        { action: "learn", kind: "standing-decision", text: "Lands with plain Git" },
        { action: "learn", kind: "fact", text: "Works from an iPhone" },
      ], { actor: { kind: "home", id: CORPUS_IDS.session }, author: { kind: "home", sessionId: CORPUS_IDS.session, entryId: "corpus-entry-0001" },
        commandId: "corpus-profile-0001", reason: "Corpus profile" });
      const [preference, decision, fact] = learned.saved.map((saved) => (saved as { id: string }).id);
      await profile.change(path, [{ action: "confirm", id: preference! }], context("corpus-profile-0002"));
      await profile.change(path, [{ action: "supersede", id: decision!, kind: "standing-decision", text: "Lands with plain Git after tests" }], context("corpus-profile-0003"));
      await profile.change(path, [{ action: "retire", id: fact!, reason: "No longer true" }], context("corpus-profile-0004"));
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const knowledge = new ProfileStore(workspace);
      const profile = await readHomeProfile(knowledge);
      return { items: profile.items.map(({ record: _record, ...item }) => item), unclassified: profile.unclassified };
    }),
  },
  {
    module: "gateway/display", name: "store-display-artifacts",
    paths: ["gateway/display-artifacts"],
    live: "hard-linked content objects",
    async record(home) {
      const workspace = join(home, "..", "display-workspace");
      await mkdir(workspace, { recursive: true });
      await writeFile(join(workspace, "corpus-report.md"), "# Corpus report\n\nSynthetic display artifact.\n");
      await writeFile(join(workspace, "corpus-copy.md"), "# Corpus report\n\nSynthetic display artifact.\n");
      let next = 0;
      const store = new DisplayArtifactStore(home, { minimumFreeBytes: 0, uuid: () => `00000000-0000-4000-8000-${String(++next).padStart(12, "0")}` });
      await store.initialize();
      const report = await store.ingest(workspace, "corpus-report.md", CORPUS_IDS.session);
      await store.ingest(workspace, "corpus-copy.md", CORPUS_IDS.session);
      await store.grant(report.id, CORPUS_IDS.otherSession, CORPUS_IDS.session);
    },
    async read(home) {
      const store = new DisplayArtifactStore(home, { minimumFreeBytes: 0 });
      await store.initialize();
      const ids = (await readdir(join(home, "gateway", "display-artifacts", "artifacts"))).sort();
      const artifacts = [];
      for (const id of ids) {
        const lease = await store.acquire(id, CORPUS_IDS.session);
        const chunks: Buffer[] = [];
        for await (const chunk of lease.stream) chunks.push(chunk as Buffer);
        await lease.release();
        artifacts.push({ id, mimeType: lease.mimeType, size: lease.size, body: Buffer.concat(chunks).toString("utf8"),
          owners: [CORPUS_IDS.session, CORPUS_IDS.otherSession].filter((session) => store.hasOwner(id, session)) });
      }
      if (artifacts.length === 0) throw new Error("The display store read no artifact");
      return { artifacts };
    },
  },
];
