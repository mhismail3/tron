import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SettingsChangePath, SettingsModel } from "../src/admin/settings-model.js";
import { SettingsChangeRecord } from "../src/admin/settings-record.js";
import { SettingsApprovals } from "../src/admin/settings-approvals.js";
import { TrustService } from "../src/admin/trust-service.js";
import { SwiftAppStore } from "../src/apps/swift-app-store.js";
import { AutomationStore } from "../src/automations/automation-store.js";
import { HomeOwner } from "../src/home/home-owner.js";
import { HomeProfileItems, readHomeProfile } from "../src/home/home-profile.js";
import { HomeTaskStore, taskIntentDigest } from "../src/home/home-task-store.js";
import { DisplayArtifactStore } from "../src/display/display-artifact-store.js";
import { EPISODIC_DEFAULTS } from "../src/episodic/episodic-contract.js";
import { EpisodicMemory } from "../src/episodic/episodic-memory.js";
import { EpisodicStore } from "../src/episodic/episodic-store.js";
import { KnowledgeService } from "../src/knowledge/knowledge-service.js";
import type { RuntimeRegistry } from "../src/sessions/runtime-registry.js";
import { singleChapterSource } from "./episodic-chapter-source.js";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { KnowledgeStore } from "../src/knowledge/knowledge-store.js";
import { UploadStore } from "../src/machine/upload-store.js";
import { NotificationGrantStore } from "../src/notifications/grant-store.js";
import { RecentModelStore } from "../src/providers/recent-models.js";
import { DeviceStore } from "../src/security/device-store.js";
import { MacTerminalKeys } from "../src/security/mac-terminal.js";
import { RunMarkerStore } from "../src/sessions/run-markers.js";
import { SessionArchiveStore } from "../src/sessions/session-archive-store.js";
import { SessionAttentionStore } from "../src/sessions/session-attention-store.js";
import { CommandReceiptStore } from "../src/transport/command-receipts.js";
import { TronWorkspace } from "../src/workspace/tron-workspace.js";

/**
 * The stores the persisted-store corpus holds (restructure plan §6.5, V4): for each,
 * how its real owner records representative synthetic data and how the current
 * owner reads it back. `tron-store-corpus.ts` stages, records and compares them.
 */
const MACHINE = "corpus-machine";
const IDENTITY = "device:corpus-phone";

/** Fixed identities the recorder chooses, kept verbatim by normalization. */
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
  /** Module id owning the store and its golden. */
  readonly module: string;
  /** Lock name: `locks/<name>.golden.json` beside the module's lock test. */
  readonly name: string;
  /** Home-relative paths (prefixes) the store owns, recorded in the lock. */
  readonly paths: readonly string[];
  /** A store that cannot be committed as bytes, recorded live by each lock run instead.
   * The lock then also pins the persisted files' normalized content, so a format
   * change still appears as a golden diff. */
  readonly live?: string;
  /** Files an owner deliberately renews on open, excluded from the no-write check:
   * only time-bounded operational state qualifies, never user data. */
  readonly renewed?: readonly string[];
  /** Recording it again (`recordFixed`) writes the committed bytes; its lock proves that.
   * Not episodic memory: its cursor pins the source file's device, inode and ctime. */
  readonly reproducible?: true;
  /** Write representative data with the real owner (recording only). */
  record(home: string): Promise<void>;
  /** Open the store with the current owner and return its public projection. */
  read(home: string): Promise<unknown>;
}

/** Run with the home's workspace, which one process may own at a time, then release it. */
async function withWorkspace<T>(home: string, use: (workspace: TronWorkspace) => Promise<T>): Promise<T> {
  const value = new TronWorkspace(home);
  await value.initialize();
  try { return await use(value); } finally { await value.dispose(); }
}

async function settingsPath(home: string, knowledge?: KnowledgeService) {
  const agentDir = join(home, "agent");
  await mkdir(agentDir, { recursive: true });
  const trust = new TrustService(agentDir);
  const modelRuntime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
  const model = new SettingsModel({ agentDir, tronHome: home, trust, modelRuntime, macTerminalKeys: new MacTerminalKeys(join(home, "ssh")) });
  const record = new SettingsChangeRecord(home);
  const approvals = new SettingsApprovals(home);
  const path = new SettingsChangePath(model, record, approvals, {
    setTrust: async () => { throw new Error("The settings corpus sets no trust"); },
    ...(knowledge ? { profile: new HomeProfileItems(() => knowledge) } : {}),
  }, agentDir);
  return { model, record, path, approvals };
}

/** Tron Home's designation owner over a fixed session port: designation names sessions
 * the run module owns, so the corpus gives it the two corpus session ids. */
function homeOwner(home: string, workspace: TronWorkspace): HomeOwner {
  return new HomeOwner({
    tronHome: home,
    trust: new TrustService(join(home, "agent")),
    workspace,
    // Designation and status never dispatch a task, so the task namespace is never read.
    taskSessions: {} as RuntimeRegistry,
    sessions: {
      createHomeSession: async () => CORPUS_IDS.session, sessionFile: async () => undefined,
      sessionPresent: async (id) => id === CORPUS_IDS.session, hasLiveRuntime: () => false, currentSessionModel: () => null,
      chapterMetrics: async () => ({ bytes: 2_048, entries: 4, quiescent: true }), hasConversation: async () => false,
      serializeSessionMutation: async (_id, commit) => commit(), replaceRuntimeForProfile: async (_sessionId, commit) => commit(),
      applySessionModel: async () => {}, beginHomePublicationReconciliation: () => {}, retireHomeRuntimes: async () => {},
      wakeHome: async () => { throw new Error("The corpus Home is never woken"); },
    },
    memoryModels: async () => [],
    memorySummarizer: () => async () => { throw new Error("The corpus Home summarizes nothing"); },
    knowledge: () => undefined,
  });
}

/** A resolution with only the named keys' floor instances: every other key's floor is its code default. */
function floorsOf<T extends { keys: Array<{ key: string; qualifiers?: Record<string, string> }> }>(resolved: T, keys: readonly string[]): T {
  return { ...resolved, keys: resolved.keys.filter((entry) => entry.key !== "permissions.floor" || keys.includes(entry.qualifiers?.key ?? "")) };
}

export const STORES: readonly StoreSpec[] = [
  {
    module: "gateway/admin", name: "store-settings",
    // Settings values and history, the maintainer's floor overrides (`floors.json`) and the
    // approval requests an agent's change above its floor leaves (`approvals.json`).
    paths: ["agent/settings.json", "gateway/settings"],
    reproducible: true,
    async record(home) {
      const { path } = await settingsPath(home);
      const ui = { kind: "ui" as const, id: IDENTITY };
      const agent = { kind: "agent" as const, id: CORPUS_IDS.session, sessionId: CORPUS_IDS.session };
      await path.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 6 }],
        { actor: ui, reason: "Corpus: retry longer" });
      await path.change({ kind: "mac" }, [{ key: "context.images.block", layer: "mac", op: "set", value: true }],
        { actor: ui, reason: "Corpus: block images" });
      // One single floor raised to approve, one directional floor raised to notify.
      for (const [qualifiers, value] of [[{ key: "run.retry.maxRetries" }, "approve"], [{ key: "context.images.block", direction: "narrow" }, "notify"]] as const) {
        await path.change({ kind: "mac" }, [{ key: "permissions.floor", qualifiers, layer: "mac", op: "set", value }],
          { actor: ui, reason: `Corpus: raise the floor of ${qualifiers.key}` });
      }
      const held = await path.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 2 }],
        { actor: agent, reason: "Corpus: an agent asks to retry less" });
      await path.change({ kind: "mac" }, [{ key: "context.images.block", layer: "mac", op: "set", value: false }],
        { actor: agent, reason: "Corpus: an agent asks to allow images" });
      const approval = (held as { approval?: { requestId: string; digest: string } }).approval;
      if (!approval) throw new Error(`The corpus agent change was not held: ${JSON.stringify(held)}`);
      await path.decide(approval.requestId, { digest: approval.digest, approved: false, decidedBy: ui });
    },
    async read(home) {
      const { model, record, approvals } = await settingsPath(home);
      // `pendingApprovals` expires requests against the wall clock; the store's own reads do not.
      const history = (await record.page({ limit: 50 })).entries;
      const requestIds = [...new Set(history.flatMap((entry) => (entry as { requestId?: string }).requestId ?? []))];
      return {
        history,
        resolved: floorsOf(await model.resolve({ kind: "mac" }, undefined, ["run.retry.maxRetries", "context.images.block", "permissions.floor"]),
          ["run.retry.maxRetries", "context.images.block"]),
        approvals: { pending: await approvals.pending(), requests: await Promise.all(requestIds.map((id) => approvals.get(id) ?? null)) },
      };
    },
  },
  {
    module: "gateway/security", name: "store-devices",
    paths: ["gateway/devices.json", "gateway/local-auth.json"],
    // The pairing invitation expires after ten minutes and opening the store renews it.
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
      await grants.update((current) => ({ ...current, policy: { ...current.policy, notifyWhenAskPresented: false } }));
    },
    async read(home) {
      const grants = new NotificationGrantStore(home);
      await grants.initialize();
      return { document: await grants.snapshot(), migratedLegacyKinds: grants.takeMigratedLegacyKinds() };
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
    // Metadata names the body by absolute path and the logical body must be a hard
    // link of its content object; Git preserves neither.
    live: "absolute body paths and hard-linked objects",
    async record(home) {
      const uploads = new UploadStore(home, 1_048_576);
      const saved = await uploads.save("corpus-note.txt", "text/plain", Buffer.from("corpus upload body\n"));
      // A prompt materializes its attachments into the session that owns them from then on.
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
    module: "gateway/knowledge", name: "store-knowledge",
    paths: ["workspace/state/knowledge"],
    record: (home) => withWorkspace(home, async (workspace) => {
      const store = new KnowledgeStore(workspace, () => {});
      await store.createNote({ commandId: "corpus-note-0001", record: {
        kind: "note", id: CORPUS_IDS.note, scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
        content: { title: "Corpus preference", body: "Prefers concise answers.", role: "preference", confirmed: true },
      } });
      await store.captureSource({ commandId: "corpus-source-0001", record: {
        kind: "source", id: CORPUS_IDS.source, scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
        content: { title: "Corpus source", text: "A synthetic research source.", captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z" },
      } });
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const store = new KnowledgeStore(workspace, () => {});
      return {
        status: await store.status(),
        list: await store.list({ limit: 50 }),
        note: await store.read(CORPUS_IDS.note),
        source: await store.read(CORPUS_IDS.source),
      };
    }),
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
      const apps = new SwiftAppStore(workspace);
      await apps.install({ appId: CORPUS_IDS.app, name: "Corpus counter", source: "import SwiftUI\nstruct CounterApp: View { var body: some View { Text(\"0\") } }\n" });
      await apps.commit({ appId: CORPUS_IDS.app, expectedRevision: 0, set: [{ key: "count", value: 3 }], remove: [] });
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const apps = new SwiftAppStore(workspace);
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
      // Designation also records a trust decision for Home's workspace, keyed by its
      // absolute path: that is the trust store's (machine-specific), not Home's record.
      await rm(join(home, "agent", "trust.json"), { force: true });
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const owner = homeOwner(home, workspace);
      await owner.initialize();
      const status = await owner.status();
      return {
        status: { ...status, taskRecovery: undefined, hostPressure: undefined, workers: undefined },
        chapters: await owner.chapterList(),
        designation: Object.fromEntries([CORPUS_IDS.session, CORPUS_IDS.otherSession].map((id) => [id, {
          model: owner.modelFor(id) ?? null, homeChapter: owner.isHomeChapter(id) }])),
      };
    }),
  },
  {
    module: "gateway/episodic", name: "store-episodic",
    paths: ["workspace/state/episodic", "gateway/workspace-state/episodic-initialized.json"],
    record: (home) => withWorkspace(home, async (workspace) => {
      const root = await mkdtemp(join(tmpdir(), "tron-corpus-episodic-"));
      try {
        const manager = SessionManager.create(join(root, "project"), join(root, "sessions"));
        for (let index = 0; index < 6; index += 1) {
          manager.appendMessage({ role: "user", content: `Corpus question ${index}: ${"q".repeat(400)}`, timestamp: 1_767_225_600_000 + index } satisfies Message);
          manager.appendMessage(fauxAssistantMessage([{ type: "text", text: `Corpus answer ${index}: ${"a".repeat(400)}` }]));
        }
        const sessionId = manager.getSessionId();
        const memory = await EpisodicMemory.open({
          workspace, sessionId, sessionSource: singleChapterSource(sessionId, manager.getSessionFile()!),
          // A deterministic compactor: the last turn's text, never a model provider.
          summarizer: async (request) => fauxAssistantMessage(`Corpus summary: ${request.turns.at(-1)!.text.replace(/\s+/gu, " ").trim().slice(-120)}`),
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
    paths: ["workspace/state/knowledge", "gateway/settings"],
    // The learned profile is personal Knowledge notes (its bytes are the Knowledge
    // corpus's format) plus their settings record entries; recorded live so this
    // lock owns no second copy of the Knowledge store.
    live: "profile notes are Knowledge records; the Knowledge store lock owns their committed bytes",
    record: (home) => withWorkspace(home, async (workspace) => {
      const knowledge = new KnowledgeService(new KnowledgeStore(workspace, () => {}));
      const { path } = await settingsPath(home, knowledge);
      const context = (commandId: string) => ({ actor: { kind: "ui" as const, id: IDENTITY }, author: { kind: "maintainer" as const }, commandId, reason: "Corpus profile" });
      // Home learns unconfirmed items; the maintainer confirms, supersedes and retires them.
      const learned = await path.changeProfile([
        { action: "learn", kind: "preference", text: "Prefers concise answers" },
        { action: "learn", kind: "standing-decision", text: "Lands with plain Git" },
        { action: "learn", kind: "fact", text: "Works from an iPhone" },
      ], { actor: { kind: "home", id: CORPUS_IDS.session }, author: { kind: "home", sessionId: CORPUS_IDS.session, entryId: "corpus-entry-0001" },
        commandId: "corpus-profile-0001", reason: "Corpus profile" });
      const [preference, decision, fact] = learned.saved.map((saved) => (saved as { id: string }).id);
      await path.changeProfile([{ action: "confirm", id: preference! }], context("corpus-profile-0002"));
      await path.changeProfile([{ action: "supersede", id: decision!, kind: "standing-decision", text: "Lands with plain Git after tests" }], context("corpus-profile-0003"));
      await path.changeProfile([{ action: "retire", id: fact!, reason: "No longer true" }], context("corpus-profile-0004"));
    }),
    read: (home) => withWorkspace(home, async (workspace) => {
      const knowledge = new KnowledgeService(new KnowledgeStore(workspace, () => {}));
      const profile = await readHomeProfile(knowledge);
      return { items: profile.items.map(({ record: _record, ...item }) => item), unclassified: profile.unclassified };
    }),
  },
  {
    module: "gateway/display", name: "store-display-artifacts",
    paths: ["gateway/display-artifacts"],
    // An artifact's content is a hard link of its content object; Git preserves no link.
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
      // Identical bytes share one content object.
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
