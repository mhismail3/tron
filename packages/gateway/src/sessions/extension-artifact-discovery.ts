import { watch } from "node:fs";
import { opendir, open, readdir, stat } from "node:fs/promises";
import { dirname, basename, join, resolve } from "node:path";
import { tmpdir } from "node:os";
export type ExtensionArtifactDiscoveryOutcome = "accepted" | "rejected" | "transient";
import {
  MAX_EXTENSION_ARTIFACT_BYTES,
  MAX_EXTENSION_LIFECYCLE_HEADER_BYTES,
  admitExtensionLifecycleArtifact,
  hasExtensionLifecycleProjectionProperty,
  inspectExtensionLifecycleProjection,
  lifecycleProjectionArtifact,
  observedPausedProcessTerminalAt,
  parseExtensionLifecycleProjectionHeader,
} from "../kernel/projection/extension-run-projection.js";

const MAX_EXTENSION_DISCOVERY_WORK = 1_024;
const MAX_EXTENSION_DISCOVERY_ROOTS = 64;
const MAX_EXTENSION_TEMP_ENTRIES = 1_024;
const MAX_EXTENSION_ROOT_ENTRIES = 4_096;
const EXTENSION_DISCOVERY_TRUNCATION_REPORT_MS = 60 * 60 * 1_000;
const MAX_ATTRIBUTED_RETRIES_PER_SLOT = 64;
const EXTENSION_DISCOVERY_FULL_SWEEP_MS = 5 * 60_000;
const EXTENSION_DISCOVERY_WATCH_RETRY_MS = 5_000;
const EXTENSION_DISCOVERY_NEW_ENTRY_MS = 60_000;

export interface ExtensionArtifactDiscoveryCounts {
  entries: number;
  statusReads: number;
  work: number;
  dropped: number;
}

export interface ExtensionArtifactRootWatchRequest {
  root: string;
  onEvent(filename: string | null): void;
  onReset(): void;
}

interface ExtensionArtifactRootWatchHandle {
  close(): void;
}

function watchArtifactRoot(request: ExtensionArtifactRootWatchRequest): ExtensionArtifactRootWatchHandle {
  const watcher = watch(request.root, { recursive: true, persistent: false }, (_event, filename) => {
    request.onEvent(typeof filename === "string" ? filename : null);
  });
  watcher.on("error", () => request.onReset());
  return { close: () => watcher.close() };
}

interface ExtensionArtifactDiscoverySlot {
  readonly id: string;
  readonly cwd: string;
  readonly ownedTurns: {
    ownedExtensionArtifactDirectories(): string[];
    discoverExtensionArtifact(asyncDir: string): Promise<ExtensionArtifactDiscoveryOutcome>;
    extensionAmbientArtifactAttribution(): ReadonlySet<string>;
  };
}

interface AmbientArtifactFact {
  asyncDir: string;
  identity: string;
  active: boolean;
  timestamp: number;
}

interface AmbientArtifactRoot {
  readonly root: string;
  rootIdentity?: string;
  listing?: string | undefined;
  names: Set<string>;
  facts: Map<string, AmbientArtifactFact>;
  changed: Set<string>;
  sweep: Set<string>;
  fresh: Map<string, number>;
  sweepRequested: boolean;
  sweepStartedAt: number;
  watcher?: ExtensionArtifactRootWatchHandle | undefined;
  watchRetryAt: number;
}

export class ExtensionArtifactDiscovery {
  private closed = false;
  private stoppedSince = 0;
  private droppedSince = 0;
  private stopReportedAt = 0;
  private readonly roots = new Map<string, AmbientArtifactRoot>();
  private readonly ambientArtifactRoutes = new Map<string, Map<string, { identity: string; accepted: boolean }>>();
  private readonly watchRoot: (request: ExtensionArtifactRootWatchRequest) => ExtensionArtifactRootWatchHandle;
  private readonly fullSweepMs: number;

  constructor(
    private readonly slots: ReadonlyMap<string, ExtensionArtifactDiscoverySlot>,
    private readonly options: {
      delegatedArtifactRoot?: string;
      artifactDiscoveryTruncated?: (counts: ExtensionArtifactDiscoveryCounts) => void;
      watchArtifactRoot?: (request: ExtensionArtifactRootWatchRequest) => ExtensionArtifactRootWatchHandle;
      fullSweepMs?: number;
    },
  ) {
    this.watchRoot = options.watchArtifactRoot ?? watchArtifactRoot;
    this.fullSweepMs = options.fullSweepMs ?? EXTENSION_DISCOVERY_FULL_SWEEP_MS;
  }

  close(): void {
    this.closed = true;
    for (const state of this.roots.values()) this.stopWatching(state);
    this.roots.clear();
  }

  recordPassOutcome(truncated: ExtensionArtifactDiscoveryCounts | undefined): void {
    if (truncated) {
      const now = Date.now();
      if (this.stoppedSince === 0) this.stoppedSince = now;
      if (truncated.dropped === 0) this.droppedSince = 0;
      else if (this.droppedSince === 0) this.droppedSince = now;
      this.reportArtifactDiscoveryTruncation(truncated);
    } else {
      this.stoppedSince = 0;
      this.droppedSince = 0;
    }
  }

  async runPass(): Promise<ExtensionArtifactDiscoveryCounts | undefined> {
    if (this.closed) return undefined;
    const counts: ExtensionArtifactDiscoveryCounts = { entries: 0, statusReads: 0, work: 0, dropped: 0 };
    const slots = [...this.slots.values()];
    const exact = new Set<string>();
    for (const slot of slots) {
      for (const asyncDir of slot.ownedTurns.ownedExtensionArtifactDirectories()) {
        const key = `${slot.id}\0${asyncDir}`;
        if (!exact.add(key)) continue;
        if (counts.work >= MAX_EXTENSION_DISCOVERY_WORK) return counts;
        counts.work += 1;
        await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
      }
    }

    const roots = new Map<string, { dev: number; ino: number; mtimeMs: number; ctimeMs: number }>();
    if (this.options.delegatedArtifactRoot) {
      const providerRunsRoot = join(this.options.delegatedArtifactRoot, "async-subagent-runs");
      try {
        const metadata = await stat(providerRunsRoot);
        if (metadata.isDirectory()) roots.set(providerRunsRoot, metadata);
      } catch { }
    } else for (const slot of slots) {
      if (roots.size >= MAX_EXTENSION_DISCOVERY_ROOTS) break;
      const projectRoot = join(resolve(slot.cwd), ".pi", "subagents", "async-subagent-runs");
      try {
        const metadata = await stat(projectRoot);
        if (metadata.isDirectory()) roots.set(projectRoot, metadata);
      } catch { }
    }
    try {
      let examined = 0;
      if (this.options.delegatedArtifactRoot) {
      } else {
      const entries = await opendir(tmpdir());
      for await (const entry of entries) {
        examined += 1;
        if (examined > MAX_EXTENSION_TEMP_ENTRIES || roots.size >= MAX_EXTENSION_DISCOVERY_ROOTS) break;
        if (!entry.isDirectory() || !entry.name.startsWith("pi-subagents-")) continue;
        const root = join(tmpdir(), entry.name, "async-subagent-runs");
        try {
          const metadata = await stat(root);
          if (metadata.isDirectory()) roots.set(root, metadata);
        } catch { }
      }
      }
    } catch { }
    if (this.closed) return undefined;

    for (const [root, state] of this.roots) {
      if (roots.has(root)) continue;
      this.stopWatching(state);
      this.roots.delete(root);
    }
    const rootList = [...roots.keys()];
    const attributed = new Map<string, ReadonlySet<string>>();
    for (const slot of slots) {
      attributed.set(slot.id, slot.ownedTurns.extensionAmbientArtifactAttribution());
    }
    let walkStopped = false;
    let routedOut = false;
    let dropped = 0;
    for (const root of rootList) {
      if (counts.entries >= MAX_EXTENSION_ROOT_ENTRIES || counts.statusReads >= MAX_EXTENSION_DISCOVERY_WORK) {
        walkStopped ||= this.roots.get(root)?.changed.size !== 0;
        continue;
      }
      let state = this.roots.get(root);
      if (!state) {
        state = {
          root, names: new Set(), facts: new Map(), changed: new Set(), sweep: new Set(), fresh: new Map(),
          sweepRequested: true, sweepStartedAt: 0, watchRetryAt: 0,
        };
        this.roots.set(root, state);
      }
      if (await this.refreshRoot(state, roots.get(root)!, attributed, counts)) walkStopped = true;
      if (this.closed) return undefined;
    }

    for (let rootIndex = 0; rootIndex < rootList.length; rootIndex += 1) {
      if (counts.work >= MAX_EXTENSION_DISCOVERY_WORK) break;
      const state = this.roots.get(rootList[rootIndex]!);
      if (!state) continue;
      const rootsRemaining = rootList.length - rootIndex;
      const routedSlots = Math.max(1, slots.length);
      const rootBudget = Math.max(1, Math.floor(
        (MAX_EXTENSION_DISCOVERY_WORK - counts.work) / (rootsRemaining * routedSlots),
      ));
      const waiting = new Map<string, ExtensionArtifactDiscoverySlot[]>();
      const pending: Array<AmbientArtifactFact & { runId: string }> = [];
      for (const [runId, fact] of state.facts) {
        const owed: ExtensionArtifactDiscoverySlot[] = [];
        for (const slot of slots) {
          const known = attributed.get(slot.id);
          if (!known || (!known.has(runId) && !known.has(fact.asyncDir))) continue;
          if (this.ambientArtifactRoutes.get(slot.id)?.get(fact.asyncDir)?.identity === fact.identity) continue;
          owed.push(slot);
        }
        if (owed.length === 0) continue;
        waiting.set(fact.asyncDir, owed);
        pending.push({ ...fact, runId });
      }
      pending.sort((left, right) => Number(right.active) - Number(left.active)
        || right.timestamp - left.timestamp || left.asyncDir.localeCompare(right.asyncDir));
      const offerable = pending.slice(0, rootBudget);
      dropped += pending.length - offerable.length;
      for (const candidate of offerable) {
        for (const slot of waiting.get(candidate.asyncDir)!) {
          if (counts.work >= MAX_EXTENSION_DISCOVERY_WORK) {
            routedOut = true;
            break;
          }
          if (this.closed) return undefined;
          counts.work += 1;
          const outcome = await slot.ownedTurns.discoverExtensionArtifact(candidate.asyncDir);
          if (outcome === "transient") continue;
          let routed = this.ambientArtifactRoutes.get(slot.id);
          if (!routed) {
            routed = new Map();
            this.ambientArtifactRoutes.set(slot.id, routed);
          }
          routed.set(candidate.asyncDir, { identity: candidate.identity, accepted: outcome === "accepted" });
        }
        if (routedOut) break;
      }
      if (routedOut) break;
    }
    counts.dropped = dropped;
    this.pruneAmbientArtifactRoutes();
    if (walkStopped || routedOut || dropped > 0) return counts;
    return undefined;
  }

  private async refreshRoot(
    state: AmbientArtifactRoot,
    metadata: { dev: number; ino: number; mtimeMs: number; ctimeMs: number },
    attributed: ReadonlyMap<string, ReadonlySet<string>>,
    counts: ExtensionArtifactDiscoveryCounts,
  ): Promise<boolean> {
    const now = Date.now();
    const rootIdentity = `${metadata.dev}:${metadata.ino}`;
    if (state.rootIdentity !== rootIdentity) {
      this.stopWatching(state);
      state.rootIdentity = rootIdentity;
      state.listing = undefined;
      state.names = new Set();
      state.facts.clear();
      state.changed.clear();
      state.sweep.clear();
      state.fresh.clear();
      state.watchRetryAt = 0;
      state.sweepRequested = true;
    }
    if (!state.watcher && now >= state.watchRetryAt) this.startWatching(state, now);
    if (!state.watcher && state.sweep.size === 0) state.sweepRequested = true;
    if (now - state.sweepStartedAt >= this.fullSweepMs) state.sweepRequested = true;

    const listing = `${rootIdentity}:${metadata.mtimeMs}:${metadata.ctimeMs}`;
    if (state.sweepRequested || state.listing !== listing) {
      const sweeping = state.sweepRequested;
      state.sweepRequested = false;
      let names: Set<string>;
      try {
        names = new Set((await readdir(state.root, { withFileTypes: true }))
          .filter((entry) => entry.isDirectory()).map((entry) => entry.name));
      } catch {
        state.sweepRequested ||= sweeping;
        return state.changed.size > 0;
      }
      if (this.closed) return false;
      const firstListing = state.listing === undefined;
      for (const name of state.facts.keys()) if (!names.has(name)) state.facts.delete(name);
      for (const name of state.fresh.keys()) if (!names.has(name)) state.fresh.delete(name);
      for (const name of state.sweep) if (!names.has(name)) state.sweep.delete(name);
      for (const name of names) {
        if (state.names.has(name) || firstListing) continue;
        state.changed.add(name);
        state.fresh.set(name, now);
      }
      state.names = names;
      state.listing = listing;
      if (sweeping) {
        state.sweep = new Set(names);
        state.sweepStartedAt = now;
      }
    }
    for (const [name, fact] of state.facts) if (fact.active) state.changed.add(name);
    for (const [slotId, known] of attributed) {
      const routed = this.ambientArtifactRoutes.get(slotId);
      const owed: Array<{ name: string; timestamp: number }> = [];
      for (const reference of known) {
        const name = dirname(reference) === state.root ? basename(reference) : reference;
        if (!state.names.has(name)) continue;
        const fact = state.facts.get(name);
        const record = routed?.get(join(state.root, name));
        if (record?.accepted && record.identity === fact?.identity) continue;
        owed.push({ name, timestamp: fact?.timestamp ?? Number.MAX_SAFE_INTEGER });
      }
      owed.sort((left, right) => right.timestamp - left.timestamp || left.name.localeCompare(right.name));
      for (const { name } of owed.slice(0, MAX_ATTRIBUTED_RETRIES_PER_SLOT)) state.changed.add(name);
    }
    for (const [name, since] of state.fresh) {
      if (state.facts.has(name) || now - since >= EXTENSION_DISCOVERY_NEW_ENTRY_MS) state.fresh.delete(name);
      else state.changed.add(name);
    }

    const retry: string[] = [];
    let stopped = false;
    for (const queue of [state.changed, state.sweep]) {
      for (const name of queue) {
        if (counts.entries >= MAX_EXTENSION_ROOT_ENTRIES) {
          stopped = true;
          break;
        }
        counts.entries += 1;
        state.changed.delete(name);
        state.sweep.delete(name);
        const outcome = await this.refreshArtifact(state, name, counts);
        if (this.closed) return false;
        if (outcome === "budget") {
          state.changed.add(name);
          stopped = true;
          break;
        }
        if (outcome === "retry") retry.push(name);
      }
      if (stopped) break;
    }
    for (const name of retry) state.changed.add(name);
    return state.changed.size > 0 && (stopped || counts.statusReads >= MAX_EXTENSION_DISCOVERY_WORK);
  }

  private async refreshArtifact(
    state: AmbientArtifactRoot,
    name: string,
    counts: ExtensionArtifactDiscoveryCounts,
  ): Promise<"budget" | "retry" | undefined> {
    const asyncDir = join(state.root, name);
    let metadata: Awaited<ReturnType<typeof stat>>;
    try {
      metadata = await stat(join(asyncDir, "status.json"));
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "ENOENT" || code === "ENOTDIR") {
        state.facts.delete(name);
        return undefined;
      }
      return "retry";
    }
    if (!metadata.isFile()) {
      state.facts.delete(name);
      return undefined;
    }
    const identity = `${metadata.dev}:${metadata.ino}:${metadata.size}:${metadata.mtimeMs}:${metadata.ctimeMs}`;
    if (state.facts.get(name)?.identity === identity) return undefined;
    if (counts.statusReads >= MAX_EXTENSION_DISCOVERY_WORK) return "budget";
    counts.statusReads += 1;
    let decision: { active: boolean; timestamp: number } | "replaced" | undefined;
    try {
      decision = await this.readAmbientExtensionArtifact(asyncDir, metadata);
    } catch {
      return "retry";
    }
    if (decision === "replaced") return "retry";
    if (!decision) {
      state.facts.delete(name);
      return undefined;
    }
    state.facts.set(name, { asyncDir, identity, active: decision.active, timestamp: decision.timestamp });
    return undefined;
  }

  private startWatching(state: AmbientArtifactRoot, now: number): void {
    if (this.closed) return;
    const registration: { handle?: ExtensionArtifactRootWatchHandle } = {};
    try {
      registration.handle = this.watchRoot({
        root: state.root,
        onEvent: (filename) => {
          if (state.watcher !== registration.handle || !registration.handle) return;
          const name = filename?.split(/[\\/]/u)[0];
          if (!name || name === ".") state.sweepRequested = true;
          else state.changed.add(name);
        },
        onReset: () => {
          if (state.watcher !== registration.handle || !registration.handle) return;
          this.stopWatching(state);
          state.watchRetryAt = Date.now() + EXTENSION_DISCOVERY_WATCH_RETRY_MS;
          state.sweepRequested = true;
        },
      });
    } catch {
      state.watchRetryAt = now + EXTENSION_DISCOVERY_WATCH_RETRY_MS;
      return;
    }
    state.watcher = registration.handle;
    state.sweepRequested = true;
  }

  private stopWatching(state: AmbientArtifactRoot): void {
    const handle = state.watcher;
    state.watcher = undefined;
    try { handle?.close(); } catch { }
  }

  private pruneAmbientArtifactRoutes(): void {
    for (const [slotId, routed] of this.ambientArtifactRoutes) {
      if (!this.slots.has(slotId)) {
        this.ambientArtifactRoutes.delete(slotId);
        continue;
      }
      for (const asyncDir of routed.keys()) {
        if (!this.roots.get(dirname(asyncDir))?.facts.has(basename(asyncDir))) routed.delete(asyncDir);
      }
    }
  }

  private async readAmbientExtensionArtifact(
    asyncDir: string,
    expected: { dev: number; ino: number },
  ): Promise<{ active: boolean; timestamp: number } | "replaced" | undefined> {
    const handle = await open(join(asyncDir, "status.json"), "r");
    try {
      const metadata = await handle.stat();
      if (!metadata.isFile() || metadata.dev !== expected.dev || metadata.ino !== expected.ino) return "replaced";
      const headerBuffer = Buffer.alloc(MAX_EXTENSION_LIFECYCLE_HEADER_BYTES);
      const { bytesRead: headerBytesRead } = await handle.read(headerBuffer, 0, headerBuffer.length, 0);
      const headerBytes = headerBuffer.subarray(0, headerBytesRead);
      let parsed: unknown;
      if (hasExtensionLifecycleProjectionProperty(headerBytes)) {
        const projection = inspectExtensionLifecycleProjection(
          parseExtensionLifecycleProjectionHeader(headerBytes),
        );
        if (!projection) return undefined;
        parsed = lifecycleProjectionArtifact(projection);
      } else {
        if (metadata.size > MAX_EXTENSION_ARTIFACT_BYTES) return undefined;
        const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
        if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) return undefined;
        try {
          parsed = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
        } catch {
          return undefined;
        }
      }
      const value = admitExtensionLifecycleArtifact(parsed, { exactOwnedLegacy: true });
      if (!value) return undefined;
      const state = value.state ?? value.status;
      const runId = typeof value.runId === "string" ? value.runId : undefined;
      const settledPaused = state === "paused" && runId !== undefined
        && observedPausedProcessTerminalAt(value, runId) !== undefined;
      const active = !settledPaused && (state === "queued" || state === "running" || state === "pending"
        || state === "detached" || state === "paused");
      const timestamps = [value.lastUpdate, value.startedAt, value.endedAt]
        .filter((item): item is number => typeof item === "number" && Number.isSafeInteger(item) && item >= 0);
      return { active, timestamp: Math.max(0, ...timestamps) };
    } finally {
      await handle.close();
    }
  }

  private reportArtifactDiscoveryTruncation(counts: ExtensionArtifactDiscoveryCounts): void {
    if (!this.options.artifactDiscoveryTruncated) return;
    const now = Date.now();
    const episodeStart = Math.max(this.stoppedSince, this.droppedSince);
    if (this.stopReportedAt >= episodeStart
      && now - this.stopReportedAt < EXTENSION_DISCOVERY_TRUNCATION_REPORT_MS) return;
    this.stopReportedAt = now;
    this.options.artifactDiscoveryTruncated(counts);
  }
}
