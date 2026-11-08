import { watch } from "node:fs";
import { opendir, open, readdir, stat } from "node:fs/promises";
import { dirname, basename, join, resolve } from "node:path";
import { tmpdir } from "node:os";
/** How one offer of a `status.json` to its owner ended, for the caller deciding
 * whether these exact bytes may be recorded as dealt with. `accepted` means a
 * lifecycle was projected; `rejected` means no later offer of the same bytes can
 * decide differently (shape, run identity, directory, timestamps or a terminal
 * latch outranks them); `transient` means current state could not decide — a
 * losing read, unavailable receipt claim, I/O error or attribution comparison a
 * later pass may resolve — so the same artifact must be offered again. */
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

// MaximumLiveRuntimes is 16 and each slot retains at most 64 owned activity
// bindings, so this covers every exact drain owner before ambient work. An
// ambient pass spends the read budget only on artifacts whose status.json
// identity changed; an artifact past the budget is read by the next pass.
const MAX_EXTENSION_DISCOVERY_WORK = 1_024;
const MAX_EXTENSION_DISCOVERY_ROOTS = 64;
const MAX_EXTENSION_TEMP_ENTRIES = 1_024;
// The status.json stats one pass spends across its roots. Entries a pass does
// not reach stay queued in order, so a root of any size is fully examined.
const MAX_EXTENSION_ROOT_ENTRIES = 4_096;
/** A lasting stop is reported when its episode starts and then at most hourly:
 * the counts move slowly and the pass runs every 750 ms, so an undeduplicated
 * record would repeat 80 times a minute. */
const EXTENSION_DISCOVERY_TRUNCATION_REPORT_MS = 60 * 60 * 1_000;
/** The attributed, not yet accepted runs each live slot has stat'd every pass,
 * the same bound as its exact owned bindings. */
const MAX_ATTRIBUTED_RETRIES_PER_SLOT = 64;
/** The backstop for every change the root watcher cannot see (an event the
 * platform coalesced or dropped): every listed directory's status.json is
 * stat'd again this often. Active artifacts and new directories never wait for
 * it; they are checked on every pass. */
const EXTENSION_DISCOVERY_FULL_SWEEP_MS = 5 * 60_000;
/** How soon a root whose watcher could not start or failed is watched again.
 * Until then each finished sweep starts the next, so the root is polled. */
const EXTENSION_DISCOVERY_WATCH_RETRY_MS = 5_000;
/** A directory that appears after the root was first listed usually gets its
 * status.json moments later; it is stat'd on every pass for this long so the
 * first artifact does not depend on a watcher event. */
const EXTENSION_DISCOVERY_NEW_ENTRY_MS = 60_000;

/** What one discovery pass spent before it stopped. `entries` is root entries
 * examined, `statusReads` the artifacts it read because their status.json
 * identity changed, `work` the exact refreshes and routed candidates, and
 * `dropped` the candidates its per-root routing budget cut off. */
export interface ExtensionArtifactDiscoveryCounts {
  entries: number;
  statusReads: number;
  work: number;
  dropped: number;
}

/** One artifact root's change feed. `onEvent` names the changed path relative
 * to the root (null when the platform did not say); `onReset` means the
 * watcher stopped observing, so changes from then on are unseen. */
export interface ExtensionArtifactRootWatchRequest {
  root: string;
  onEvent(filename: string | null): void;
  onReset(): void;
}

interface ExtensionArtifactRootWatchHandle {
  close(): void;
}

/** Production watches the root recursively (FSEvents on macOS): one stream per
 * root, no threadpool work while nothing changes. */
function watchArtifactRoot(request: ExtensionArtifactRootWatchRequest): ExtensionArtifactRootWatchHandle {
  const watcher = watch(request.root, { recursive: true, persistent: false }, (_event, filename) => {
    request.onEvent(typeof filename === "string" ? filename : null);
  });
  watcher.on("error", () => request.onReset());
  return { close: () => watcher.close() };
}

/** The live-slot members ambient discovery reads. RuntimeSlot satisfies it
 * structurally; discovery takes no other slot state. */
interface ExtensionArtifactDiscoverySlot {
  readonly id: string;
  readonly cwd: string;
  /** The frame's actual producer authority, not Slot forwarding methods or an adapter. */
  readonly ownedTurns: {
    ownedExtensionArtifactDirectories(): string[];
    discoverExtensionArtifact(asyncDir: string): Promise<ExtensionArtifactDiscoveryOutcome>;
    extensionAmbientArtifactAttribution(): ReadonlySet<string>;
  };
}

/** The ambient decision for one run directory. The identity is the stat
 * (including ctime) of the same status.json a read would have opened, so an
 * unchanged artifact is never read again and any write is seen by a stat. */
interface AmbientArtifactFact {
  asyncDir: string;
  identity: string;
  active: boolean;
  timestamp: number;
}

/** Everything discovery knows about one artifact root. Only directories that
 * may have changed are stat'd: `changed` holds watcher-reported, newly listed,
 * active, live-slot-attributed and retried names; `sweep` holds the rest of the current full sweep.
 * Both are ordered and drained across passes within the per-pass budgets. */
interface AmbientArtifactRoot {
  readonly root: string;
  /** dev:ino of the root this state describes; a replaced root starts over. */
  rootIdentity?: string;
  /** The root's stat when it was last listed: a different one means a run
   * directory was added or removed. */
  listing?: string | undefined;
  names: Set<string>;
  facts: Map<string, AmbientArtifactFact>;
  changed: Set<string>;
  sweep: Set<string>;
  /** Directories listed after the first listing that have no fact yet, with
   * when they were first listed. */
  fresh: Map<string, number>;
  sweepRequested: boolean;
  sweepStartedAt: number;
  watcher?: ExtensionArtifactRootWatchHandle | undefined;
  watchRetryAt: number;
}

/** Gateway-scoped bounded ambient extension-artifact discovery. RuntimeRegistry
 * keeps the timer, the in-flight guard and shutdown admission, and calls
 * `runPass` then `recordPassOutcome` once per admitted pass, and `close` once
 * with no pass left in flight. */
export class ExtensionArtifactDiscovery {
  private closed = false;
  /** When the current run of stopped passes began (0 after a pass reached the
   * end of its changed work), when the current run of passes that dropped
   * candidates began, and when a stop was last reported. */
  private stoppedSince = 0;
  private droppedSince = 0;
  private stopReportedAt = 0;
  private readonly roots = new Map<string, AmbientArtifactRoot>();
  /** The status.json identity each live slot last dealt with for one run
   * directory: a slot that accepted this exact artifact has its projection, and
   * one that rejected it can only reject the same bytes again. Only those two
   * outcomes are recorded, so an offer that failed temporarily is offered again
   * on the next pass; a run the slot still holds an exact binding for is
   * refreshed by the exact-binding lane every pass. */
  private readonly ambientArtifactRoutes = new Map<string, Map<string, { identity: string; accepted: boolean }>>();
  private readonly watchRoot: (request: ExtensionArtifactRootWatchRequest) => ExtensionArtifactRootWatchHandle;
  private readonly fullSweepMs: number;

  constructor(
    private readonly slots: ReadonlyMap<string, ExtensionArtifactDiscoverySlot>,
    private readonly options: {
      delegatedArtifactRoot?: string;
      artifactDiscoveryTruncated?: (counts: ExtensionArtifactDiscoveryCounts) => void;
      /** Test-only: a watcher backend that can drop events or fail, and the
       * backstop cadence, for proving the fallbacks. */
      watchArtifactRoot?: (request: ExtensionArtifactRootWatchRequest) => ExtensionArtifactRootWatchHandle;
      fullSweepMs?: number;
    },
  ) {
    this.watchRoot = options.watchArtifactRoot ?? watchArtifactRoot;
    this.fullSweepMs = options.fullSweepMs ?? EXTENSION_DISCOVERY_FULL_SWEEP_MS;
  }

  /** Stops every root watcher. The registry calls it after joining the last
   * pass; a pass that still runs returns without attaching another watcher. */
  close(): void {
    this.closed = true;
    for (const state of this.roots.values()) this.stopWatching(state);
    this.roots.clear();
  }

  /** Records one finished pass: a stop that reached a budget opens or continues
   * an episode and is reported once per episode; a pass that reached the end of
   * its changed work closes both episodes. */
  recordPassOutcome(truncated: ExtensionArtifactDiscoveryCounts | undefined): void {
    if (truncated) {
      const now = Date.now();
      // Two episodes are tracked so a pass that only drops candidates the
      // routing budget cut off still reports once: the end of either episode is
      // not a record of its own, and a lasting one repeats hourly.
      if (this.stoppedSince === 0) this.stoppedSince = now;
      if (truncated.dropped === 0) this.droppedSince = 0;
      else if (this.droppedSince === 0) this.droppedSince = now;
      this.reportArtifactDiscoveryTruncation(truncated);
    } else {
      this.stoppedSince = 0;
      this.droppedSince = 0;
    }
  }

  /** One discovery pass. It returns this pass's counts when it stopped at a
   * budget with changed work left (an unread changed artifact, an unstat'd
   * changed directory, or a candidate it could not offer), so the stop is
   * reported instead of silent. A full sweep that continues into the next pass
   * is not a stop: its remaining directories stay queued. */
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
      } catch { /* provider root is created on first admitted run */ }
    } else for (const slot of slots) {
      if (roots.size >= MAX_EXTENSION_DISCOVERY_ROOTS) break;
      const projectRoot = join(resolve(slot.cwd), ".pi", "subagents", "async-subagent-runs");
      try {
        const metadata = await stat(projectRoot);
        if (metadata.isDirectory()) roots.set(projectRoot, metadata);
      } catch { /* a fixture without a project artifact root */ }
    }
    try {
      let examined = 0;
      // A configured provider root is the sole ambient source. Temporary and
      // project roots are only scanned by test fixtures that omit the explicit
      // production root.
      if (this.options.delegatedArtifactRoot) {
        // The exact root was admitted above; do not inspect unrelated temp
        // trees that could become a second delegated authority.
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
        } catch { /* disappearing runtime root */ }
      }
      }
    } catch { /* an unavailable artifact root leaves exact bindings authoritative */ }
    if (this.closed) return undefined;

    // A root no longer admitted takes its watcher and decisions with it.
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
    // `walkStopped` means changed work was left for the next pass and
    // `routedOut` ends this pass's routing at the work budget.
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
      // A candidate is pending offerable work only when a live slot can still
      // attribute the run and has not already dealt with this exact artifact
      // identity: the exact-binding lane keeps a live run current (G-8d), an
      // unattributable directory can only be rejected, and a decision already
      // recorded for these bytes cannot change. Filtering before the per-root
      // budget slice keeps an unchanged root from spending that budget on
      // candidates nobody would accept. Every known fact is considered, so a
      // slot that newly attributes an unchanged run is offered it without I/O.
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
      // Terminal evidence releases accepted work; live exact bindings were
      // already refreshed above and do not outrank it in ambient discovery.
      pending.sort((left, right) => Number(right.active) - Number(left.active)
        || right.timestamp - left.timestamp || left.asyncDir.localeCompare(right.asyncDir));
      // Offer only the amount this pass can safely project to live slots; a
      // pending candidate cut off here is reported instead of silently lost.
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
          // An offer the slot could not decide leaves no record, so the next
          // pass offers the same artifact again; only an accepted or
          // permanently rejected artifact is dealt with (G-8a).
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

  /** Bring one root's facts up to date, statting only directories that may have
   * changed. Returns true when changed work was left for the next pass. */
  private async refreshRoot(
    state: AmbientArtifactRoot,
    metadata: { dev: number; ino: number; mtimeMs: number; ctimeMs: number },
    attributed: ReadonlyMap<string, ReadonlySet<string>>,
    counts: ExtensionArtifactDiscoveryCounts,
  ): Promise<boolean> {
    const now = Date.now();
    const rootIdentity = `${metadata.dev}:${metadata.ino}`;
    if (state.rootIdentity !== rootIdentity) {
      // A replaced root is a different tree: its old watcher and decisions
      // describe nothing in it.
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
    // The watcher is attached before the sweep reads the tree, so a change after
    // the attach is either in the sweep's reads or in a later event.
    if (!state.watcher && now >= state.watchRetryAt) this.startWatching(state, now);
    // An unwatched root sees no events, so it is polled by back-to-back sweeps
    // until a watcher attaches.
    if (!state.watcher && state.sweep.size === 0) state.sweepRequested = true;
    if (now - state.sweepStartedAt >= this.fullSweepMs) state.sweepRequested = true;

    const listing = `${rootIdentity}:${metadata.mtimeMs}:${metadata.ctimeMs}`;
    if (state.sweepRequested || state.listing !== listing) {
      // Taken before the read: a reset that arrives while it is in flight asks
      // for another sweep instead of being absorbed by this one.
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
    // Routing can offer only a run a live slot attributes. Until that slot has
    // accepted the current artifact (it is pending, transient or rejected), the
    // directory is stat'd every pass, so a rewrite reaches the slot on the next
    // pass without waiting for the watcher. Attribution includes every run in a
    // slot's canonical history, so each slot retries only its newest
    // `MAX_ATTRIBUTED_RETRIES_PER_SLOT` such runs; older ones, accepted runs and
    // unattributed directories rely on the watcher and the sweep.
    for (const [slotId, known] of attributed) {
      const routed = this.ambientArtifactRoutes.get(slotId);
      const owed: Array<{ name: string; timestamp: number }> = [];
      for (const reference of known) {
        const name = dirname(reference) === state.root ? basename(reference) : reference;
        if (!state.names.has(name)) continue;
        const fact = state.facts.get(name);
        const record = routed?.get(join(state.root, name));
        if (record?.accepted && record.identity === fact?.identity) continue;
        // An artifact with no decision yet is the newest work there is.
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
        // Dequeued before the stat, so an event for this name during the stat
        // queues it again instead of being absorbed by a read that preceded it.
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

  /** Re-stat one directory's status.json and re-read it only when its identity
   * changed. `budget` means this pass spent its read budget; `retry` means the
   * file could not be decided now (a replace raced the read, an I/O error). */
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
    // ctime is set by the kernel on every write and cannot be set back by a
    // writer, so a same-size in-place rewrite that kept mtime still changes it.
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
      // A malformed artifact has no decision; it is read again when it changes.
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
          // A nameless event (the root itself, or the platform reporting that
          // it lost track) can hide any change, so the whole root is swept.
          if (!name || name === ".") state.sweepRequested = true;
          else state.changed.add(name);
        },
        // Tied to this handle: a reset from a watcher already replaced must not
        // stop its successor.
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
    // Nothing was observed before this attach, so the tree is read whole once.
    state.sweepRequested = true;
  }

  private stopWatching(state: AmbientArtifactRoot): void {
    const handle = state.watcher;
    state.watcher = undefined;
    try { handle?.close(); } catch { /* an already-failed watcher has nothing left to close */ }
  }

  /** Drop the routing records of closed slots and of directories whose artifact
   * no root holds any more, so the records follow the live slots and roots. */
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

  /** Read one ambient artifact's bounded lifecycle decision, verifying that the
   * inode the read opened is the one the caller's stat identity named: a replace
   * that raced the read (`replaced`) waits for the next pass instead of being
   * projected. Unparseable bytes are no decision (undefined), not an error: the
   * same bytes can only fail again. I/O errors propagate to the caller. */
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
        // Legacy artifacts still require the old whole-document cap.
        // The bounded modern first property is the only permitted
        // route through a report-bearing file larger than that cap.
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
      // A settled paused artifact owns no live work: it must not outrank
      // live artifacts for the bounded discovery budget. Without the
      // proof (or a run identity to bind it) the artifact stays active.
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
    // A stop already reported within the running episode repeats at most hourly.
    const episodeStart = Math.max(this.stoppedSince, this.droppedSince);
    if (this.stopReportedAt >= episodeStart
      && now - this.stopReportedAt < EXTENSION_DISCOVERY_TRUNCATION_REPORT_MS) return;
    this.stopReportedAt = now;
    this.options.artifactDiscoveryTruncated(counts);
  }
}
