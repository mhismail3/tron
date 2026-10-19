import { createHash } from "node:crypto";
import { chmod, cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SettingsChangePath, SettingsModel } from "../src/admin/settings-model.js";
import { SettingsChangeRecord } from "../src/admin/settings-record.js";
import { SettingsApprovals } from "../src/admin/settings-approvals.js";
import { TrustService } from "../src/admin/trust-service.js";
import { SwiftAppStore } from "../src/apps/swift-app-store.js";
import { AutomationStore } from "../src/automations/automation-store.js";
import { HomeTaskStore, taskIntentDigest } from "../src/home/home-task-store.js";
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
import { expect } from "vitest";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceNormalization, type TraceValue } from "./scenario-lock.js";

/**
 * The persisted-store corpus (restructure plan §6.5, V4).
 *
 * `test-fixtures/tron-corpus/home` is a Tron home written by the real store owners
 * (`record-tron-corpus.integration.test.ts`, `npm run record:tron-corpus`): synthetic,
 * privacy-clean data in every store this file lists. Each store lock stages a copy,
 * opens it with the current owner, reads it through that owner's public read path,
 * and compares the normalized projection with the owning module's golden. It also
 * proves reading changed no byte anywhere in the staged home, so an owner can never
 * silently migrate user data on open (§4.1 B3).
 *
 * Pi's canonical session JSONL and agent configuration are locked by the Pi
 * persisted-state corpus (`pi-persisted-state-corpus.integration.test.ts`).
 */

export const TRON_CORPUS_HOME = resolve(import.meta.dirname, "..", "test-fixtures", "tron-corpus", "home");
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
  /**
   * A store that cannot be committed as bytes, recorded live by each lock run instead.
   * The lock then also pins the persisted files' normalized content, so a format
   * change still appears as a golden diff.
   */
  readonly live?: string;
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

async function settingsPath(home: string) {
  const agentDir = join(home, "agent");
  await mkdir(agentDir, { recursive: true });
  const trust = new TrustService(agentDir);
  const modelRuntime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
  const model = new SettingsModel({ agentDir, tronHome: home, trust, modelRuntime, macTerminalKeys: new MacTerminalKeys(join(home, "ssh")) });
  const record = new SettingsChangeRecord(home);
  const path = new SettingsChangePath(model, record, new SettingsApprovals(home), {
    setTrust: async () => { throw new Error("The settings corpus sets no trust"); },
  }, agentDir);
  return { model, record, path };
}

export const STORES: readonly StoreSpec[] = [
  {
    module: "gateway/admin", name: "store-settings",
    paths: ["agent/settings.json", "gateway/settings"],
    async record(home) {
      const { path } = await settingsPath(home);
      await path.change({ kind: "mac" }, [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 6 }],
        { actor: { kind: "ui", id: IDENTITY }, reason: "Corpus: retry longer" });
      await path.change({ kind: "mac" }, [{ key: "context.images.block", layer: "mac", op: "set", value: true }],
        { actor: { kind: "ui", id: IDENTITY }, reason: "Corpus: block images" });
    },
    async read(home) {
      const { model, record } = await settingsPath(home);
      return {
        history: (await record.page({ limit: 50 })).entries,
        resolved: await model.resolve({ kind: "mac" }, undefined, ["run.retry.maxRetries", "context.images.block"]),
      };
    },
  },
  {
    module: "gateway/security", name: "store-devices",
    paths: ["gateway/devices.json", "gateway/local-auth.json", "gateway/enrollment.json"],
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
    paths: ["gateway/home", "workspace/state/home"],
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
];

/** Every file below `root` with its SHA-256, sorted by path. */
export async function fileDigests(root: string): Promise<Record<string, string>> {
  const entries = await readdir(root, { recursive: true, withFileTypes: true });
  const digests: Record<string, string> = {};
  for (const entry of entries.filter((item) => item.isFile()).sort((a, b) => join(a.parentPath, a.name).localeCompare(join(b.parentPath, b.name)))) {
    const path = join(entry.parentPath, entry.name);
    digests[relative(root, path)] = createHash("sha256").update(await readFile(path)).digest("hex");
  }
  return digests;
}

/**
 * A fresh Tron home as the Gateway prepares one (config.ts creates `gateway/`
 * owner-only before any owner opens it).
 */
export async function prepareHome(home: string): Promise<void> {
  await mkdir(join(home, "gateway"), { recursive: true, mode: 0o700 });
  await chmod(home, 0o700);
}

/**
 * Git keeps no directory modes and checkouts differ in file modes, so a staged
 * copy gets the owner-only modes the Gateway itself creates.
 */
async function ownerOnly(root: string): Promise<void> {
  await chmod(root, 0o700);
  for (const entry of await readdir(root, { recursive: true, withFileTypes: true })) {
    await chmod(join(entry.parentPath, entry.name), entry.isDirectory() ? 0o700 : 0o600);
  }
}

/** A disposable copy of the committed corpus home, and its normalization. */
export async function stageCorpus(): Promise<{ home: string; normalization: TraceNormalization; dispose(): Promise<void> }> {
  await stat(TRON_CORPUS_HOME);
  const root = await mkdtemp(join(tmpdir(), "tron-store-corpus-"));
  const home = join(root, "home");
  await cp(TRON_CORPUS_HOME, home, { recursive: true });
  await ownerOnly(home);
  return {
    home,
    normalization: { roots: [root, await realpath(root)], stableIds: Object.values(CORPUS_IDS) },
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

/**
 * A store projection with only the staged root replaced. The corpus is committed
 * bytes, so its ids, timestamps and counters are fixed: unlike a live scenario,
 * a store lock keeps them, because reading them back exactly is the contract.
 */
export function normalizeStoreValue(value: unknown, normalization: TraceNormalization): TraceValue {
  const roots = [...normalization.roots].sort((left, right) => right.length - left.length);
  return JSON.parse(JSON.stringify(value ?? null, (_key, item: unknown) => {
    if (typeof item !== "string") return item;
    let text = item;
    for (const root of roots) text = text.split(root).join("<tmp>");
    return text;
  })) as TraceValue;
}

/**
 * One store lock: stage the corpus (or record a live store), read it with the
 * current owner, and compare the projection — plus, for a live store, its
 * persisted files — with the module's golden. Reading must change no byte.
 */
export async function runStoreLock(name: string, testFileUrl: string): Promise<void> {
  const spec = STORES.find((store) => store.name === name);
  if (!spec) throw new Error(`No store spec named ${name}`);
  const staged = spec.live ? await freshHome() : await stageCorpus();
  try {
    if (spec.live) {
      await prepareHome(staged.home);
      await spec.record(staged.home);
    }
    const before = await fileDigests(staged.home);
    const projection = await spec.read(staged.home);
    const after = await fileDigests(staged.home);
    const owned = Object.keys(before).filter((path) => spec.paths.some((prefix) => path === prefix || path.startsWith(`${prefix}/`)));
    const trace = {
      store: spec.name,
      module: spec.module,
      ...(spec.live ? { live: spec.live, files: await liveFiles(staged.home, owned, staged.normalization) } : { files: owned }),
      projection: spec.live ? normalizeTraceValue(JSON.parse(JSON.stringify(projection)), staged.normalization)
        : normalizeStoreValue(projection, staged.normalization),
    };
    await compareWithGolden({
      module: spec.module, ...lockPaths(testFileUrl, spec.name), trace, update: lockUpdateRequested(spec.module),
      validate: () => {
        expect(after, "reading the store must not change, add or remove a byte").toEqual(before);
        expect(owned.length, "the store has persisted files").toBeGreaterThan(0);
        expect(JSON.stringify(projection).length).toBeGreaterThan(2);
      },
    });
  } finally {
    await staged.dispose();
  }
}

async function freshHome(): Promise<{ home: string; normalization: TraceNormalization; dispose(): Promise<void> }> {
  const root = await mkdtemp(join(tmpdir(), "tron-store-live-"));
  return {
    home: join(root, "home"),
    normalization: { roots: [root, await realpath(root)], stableIds: Object.values(CORPUS_IDS) },
    dispose: () => rm(root, { recursive: true, force: true }),
  };
}

/** A live store's persisted files: JSON normalized, other files by size. */
async function liveFiles(home: string, paths: readonly string[], normalization: TraceNormalization): Promise<TraceValue[]> {
  const files: TraceValue[] = [];
  for (const path of paths) {
    const bytes = await readFile(join(home, path));
    let content: TraceValue;
    try { content = normalizeTraceValue(JSON.parse(bytes.toString("utf8")), normalization); }
    catch { content = `<${bytes.length} bytes>`; }
    files.push({ path: normalizeTraceValue(path, normalization), content });
  }
  return files;
}
