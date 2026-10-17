import { opendir, open, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import type { ExtensionArtifactDiscoveryOutcome } from "./runtime-slot.js";
import {
  MAX_EXTENSION_ARTIFACT_BYTES,
  MAX_EXTENSION_LIFECYCLE_HEADER_BYTES,
  admitExtensionLifecycleArtifact,
  hasExtensionLifecycleProjectionProperty,
  inspectExtensionLifecycleProjection,
  lifecycleProjectionArtifact,
  observedPausedProcessTerminalAt,
  parseExtensionLifecycleProjectionHeader,
} from "./extension-run-projection.js";

// MaximumLiveRuntimes is 16 and each slot retains at most 64 owned activity
// bindings, so this covers every exact drain owner before ambient work. An
// ambient pass spends the read budget only on artifacts whose status.json
// identity changed, so unchanged directories are still walked and an artifact
// past the budget is read by the next pass.
const MAX_EXTENSION_DISCOVERY_WORK = 1_024;
const MAX_EXTENSION_DISCOVERY_ROOTS = 64;
const MAX_EXTENSION_TEMP_ENTRIES = 1_024;
// Ambient enumeration shares these global pass bounds. Exact-owned artifact
// reconciliation above is intentionally outside this ambient budget.
const MAX_EXTENSION_ROOT_ENTRIES = 4_096;
/** A lasting stop is reported when its episode starts and then at most hourly:
 * the counts move slowly and the pass runs every 750 ms, so an undeduplicated
 * record would repeat 80 times a minute. */
const EXTENSION_DISCOVERY_TRUNCATION_REPORT_MS = 60 * 60 * 1_000;
/** An ambient decision keeps its entry for this many passes after it was last
 * seen. A pass that stops at a budget still ages the entries it did not reach,
 * so a deleted run leaves the cache while the root stays over the cap. */
const AMBIENT_ARTIFACT_FACT_PASSES = 4;

/** What one discovery pass spent before it stopped. `entries` is root entries
 * walked, `statusReads` the artifacts it read because their status.json
 * identity changed, `work` the exact refreshes and routed candidates, and
 * `dropped` the candidates its per-root routing budget cut off. */
export interface ExtensionArtifactDiscoveryCounts {
  entries: number;
  statusReads: number;
  work: number;
  dropped: number;
}

/** The live-slot members ambient discovery reads. RuntimeSlot satisfies it
 * structurally; discovery takes no other slot state. */
interface ExtensionArtifactDiscoverySlot {
  readonly id: string;
  readonly cwd: string;
  ownedExtensionArtifactDirectories(): string[];
  discoverExtensionArtifact(asyncDir: string): Promise<ExtensionArtifactDiscoveryOutcome>;
  extensionAmbientArtifactAttribution(): ReadonlySet<string>;
}

/** Gateway-scoped bounded ambient extension-artifact discovery. RuntimeRegistry
 * keeps the timer, the in-flight guard and shutdown admission, and calls
 * `runPass` then `recordPassOutcome` once per admitted pass. */
export class ExtensionArtifactDiscovery {
  private pass = 0;
  /** When the current run of stopped passes began (0 after a pass reached the
   * end of its roots), when the current run of passes that dropped candidates
   * began, and when a stop was last reported. */
  private stoppedSince = 0;
  private droppedSince = 0;
  private stopReportedAt = 0;
  /** The status.json identity each live slot last dealt with for one run
   * directory: a slot that accepted this exact artifact has its projection, and
   * one that rejected it can only reject the same bytes again. Only those two
   * outcomes are recorded, so an offer that failed temporarily is offered again
   * on the next pass; a run the slot still holds an exact binding for is
   * refreshed by the exact-binding lane every pass. */
  private readonly ambientArtifactRoutes = new Map<string, Map<string, { identity: string; pass: number }>>();
  /** Ambient artifact decisions keyed by run directory. The identity is the stat
   * of the same status.json a read would have opened, so an unchanged artifact
   * costs one stat and no open, read or parse; `pass` lets a complete pass drop
   * the entries whose directories are gone. */
  private readonly ambientArtifactFacts = new Map<string, {
    identity: string;
    active: boolean;
    timestamp: number;
    pass: number;
  }>();

  constructor(
    private readonly slots: ReadonlyMap<string, ExtensionArtifactDiscoverySlot>,
    private readonly options: {
      delegatedArtifactRoot?: string;
      artifactDiscoveryTruncated?: (counts: ExtensionArtifactDiscoveryCounts) => void;
    },
  ) {}

  /** Records one finished pass: a stop that reached a budget opens or continues
   * an episode and is reported once per episode; a pass that reached the end of
   * its roots closes both episodes. */
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
   * budget rather than at the end of its roots, so the stop is reported instead
   * of silent. The next pass walks from the start again, and because an
   * unchanged artifact spends no read budget it reaches the entries this pass
   * did not examine. */
  async runPass(): Promise<ExtensionArtifactDiscoveryCounts | undefined> {
    const counts: ExtensionArtifactDiscoveryCounts = { entries: 0, statusReads: 0, work: 0, dropped: 0 };
    const slots = [...this.slots.values()];
    const exact = new Set<string>();
    for (const slot of slots) {
      for (const asyncDir of slot.ownedExtensionArtifactDirectories()) {
        const key = `${slot.id}\0${asyncDir}`;
        if (!exact.add(key)) continue;
        if (counts.work >= MAX_EXTENSION_DISCOVERY_WORK) return counts;
        counts.work += 1;
        await slot.discoverExtensionArtifact(asyncDir);
      }
    }

    const roots = new Set<string>();
    if (this.options.delegatedArtifactRoot) {
      const providerRunsRoot = join(this.options.delegatedArtifactRoot, "async-subagent-runs");
      try { if ((await stat(providerRunsRoot)).isDirectory()) roots.add(providerRunsRoot); } catch { /* provider root is created on first admitted run */ }
    } else for (const slot of slots) {
      if (roots.size >= MAX_EXTENSION_DISCOVERY_ROOTS) break;
      const projectRoot = join(resolve(slot.cwd), ".pi", "subagents", "async-subagent-runs");
      try { if ((await stat(projectRoot)).isDirectory()) roots.add(projectRoot); } catch { /* isolated pre-cutover fixture */ }
    }
    try {
      let examined = 0;
      // A configured provider root is the sole ambient source after the
      // cutover. Temporary/project roots are only scanned by test fixtures
      // that omit the explicit production root.
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
        try { if ((await stat(root)).isDirectory()) roots.add(root); } catch { /* disappearing runtime root */ }
      }
      }
    } catch { /* an unavailable artifact root leaves exact bindings authoritative */ }

    const rootList = [...roots];
    this.pass += 1;
    const pass = this.pass;
    // `walkStopped` ends the walk at a budget and `routedOut` ends this pass's
    // routing at the work budget; the entries this pass already read are still
    // routed before it returns.
    let walkStopped = false;
    let routedOut = false;
    let dropped = 0;
    const attributed = new Map<string, ReadonlySet<string>>();
    for (const slot of slots) {
      attributed.set(slot.id, slot.extensionAmbientArtifactAttribution());
    }
    for (let rootIndex = 0; rootIndex < rootList.length; rootIndex += 1) {
      if (counts.work >= MAX_EXTENSION_DISCOVERY_WORK
        || counts.entries >= MAX_EXTENSION_ROOT_ENTRIES
        || counts.statusReads >= MAX_EXTENSION_DISCOVERY_WORK) {
        walkStopped = true;
        break;
      }
      const root = rootList[rootIndex]!;
      const rootsRemaining = rootList.length - rootIndex;
      const routedSlots = Math.max(1, slots.length);
      const rootBudget = Math.max(1, Math.floor(
        (MAX_EXTENSION_DISCOVERY_WORK - counts.work) / (rootsRemaining * routedSlots),
      ));
      const candidates: Array<{ asyncDir: string; runId: string; identity: string; active: boolean; timestamp: number }> = [];
      try {
        const entries = await opendir(root);
        for await (const entry of entries) {
          counts.entries += 1;
          if (counts.entries > MAX_EXTENSION_ROOT_ENTRIES) {
            walkStopped = true;
            break;
          }
          if (!entry.isDirectory()) continue;
          const asyncDir = join(root, entry.name);
          let fact: { identity: string; active: boolean; timestamp: number } | "budget" | undefined;
          try {
            const metadata = await stat(join(asyncDir, "status.json"));
            if (metadata.isFile()) fact = await this.ambientArtifactFact(asyncDir, metadata, pass, counts);
          } catch { /* a replaced or malformed artifact belongs to the next pass */ }
          if (fact === "budget") {
            walkStopped = true;
            break;
          }
          if (fact) candidates.push({ asyncDir, runId: entry.name, ...fact });
        }
      } catch { continue; }
      // Terminal evidence releases accepted work; live exact bindings were
      // already refreshed above and do not outrank it in ambient discovery.
      candidates.sort((left, right) => Number(right.active) - Number(left.active)
        || right.timestamp - left.timestamp || left.asyncDir.localeCompare(right.asyncDir));
      // A candidate is pending offerable work only when a live slot can still
      // attribute the run and has not already dealt with this exact artifact
      // identity: the exact-binding lane keeps a live run current (G-8d), an
      // unattributable directory can only be rejected, and a decision already
      // recorded for these bytes cannot change. Filtering before the per-root
      // budget slice keeps an unchanged root from spending that budget on
      // candidates nobody would accept, which used to starve the same
      // attributed run on every pass.
      const waiting = new Map<string, ExtensionArtifactDiscoverySlot[]>();
      for (const candidate of candidates) {
        const owed: ExtensionArtifactDiscoverySlot[] = [];
        for (const slot of slots) {
          const known = attributed.get(slot.id);
          if (!known || (!known.has(candidate.runId) && !known.has(candidate.asyncDir))) continue;
          const record = this.ambientArtifactRoutes.get(slot.id)?.get(candidate.asyncDir);
          if (record?.identity === candidate.identity) {
            // Seen again this pass: keep the decision alive while the root holds it.
            record.pass = pass;
            continue;
          }
          owed.push(slot);
        }
        if (owed.length > 0) waiting.set(candidate.asyncDir, owed);
      }
      const pending = candidates.filter((candidate) => waiting.has(candidate.asyncDir));
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
          counts.work += 1;
          // An offer the slot could not decide leaves no record, so the next
          // pass offers the same artifact again; only an accepted or
          // permanently rejected artifact is dealt with (G-8a).
          const outcome = await slot.discoverExtensionArtifact(candidate.asyncDir);
          if (outcome === "transient") continue;
          let routed = this.ambientArtifactRoutes.get(slot.id);
          if (!routed) {
            routed = new Map();
            this.ambientArtifactRoutes.set(slot.id, routed);
          }
          routed.set(candidate.asyncDir, { identity: candidate.identity, pass });
        }
        if (routedOut) break;
      }
      if (walkStopped || routedOut) break;
    }
    counts.dropped = dropped;
    this.pruneAmbientArtifactFacts(pass);
    this.pruneAmbientArtifactRoutes(pass);
    if (walkStopped || routedOut || dropped > 0) return counts;
    return undefined;
  }

  /** The ambient decision for one run directory, re-read only when the identity
   * of its status.json changed. `"budget"` means this pass spent its read budget
   * on changed artifacts, so the walk stops there instead of skipping the entry
   * and calling the directory examined. */
  private async ambientArtifactFact(
    asyncDir: string,
    metadata: { dev: number; ino: number; size: number; mtimeMs: number },
    pass: number,
    counts: ExtensionArtifactDiscoveryCounts,
  ): Promise<{ identity: string; active: boolean; timestamp: number } | "budget" | undefined> {
    const identity = `${metadata.dev}:${metadata.ino}:${metadata.size}:${metadata.mtimeMs}`;
    const known = this.ambientArtifactFacts.get(asyncDir);
    if (known && known.identity === identity) {
      known.pass = pass;
      return known;
    }
    if (counts.statusReads >= MAX_EXTENSION_DISCOVERY_WORK) return "budget";
    counts.statusReads += 1;
    const decision = await this.readAmbientExtensionArtifact(asyncDir, metadata);
    if (!decision) {
      // A replacement that raced the read or a malformed artifact is not
      // cached, so the next pass decides again.
      this.ambientArtifactFacts.delete(asyncDir);
      return undefined;
    }
    const fact = { identity, active: decision.active, timestamp: decision.timestamp, pass };
    this.ambientArtifactFacts.set(asyncDir, fact);
    return fact;
  }

  /** Read one ambient artifact's bounded lifecycle decision, verifying that the
   * inode the read opened is the one the caller's stat identity named: a replace
   * that raced the read waits for the next pass instead of being projected. */
  private async readAmbientExtensionArtifact(
    asyncDir: string,
    expected: { dev: number; ino: number },
  ): Promise<{ active: boolean; timestamp: number } | undefined> {
    const handle = await open(join(asyncDir, "status.json"), "r");
    try {
      const metadata = await handle.stat();
      if (!metadata.isFile() || metadata.dev !== expected.dev || metadata.ino !== expected.ino) return undefined;
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
        parsed = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
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

  /** Drop the decisions of directories no pass saw within the last few passes,
   * so the cache follows the artifact root instead of growing with every run it
   * ever held. A pass that stopped at a budget ages the entries past its stop
   * too; dropping one early costs a single re-read. */
  private pruneAmbientArtifactFacts(pass: number): void {
    for (const [asyncDir, fact] of this.ambientArtifactFacts) {
      if (pass - fact.pass >= AMBIENT_ARTIFACT_FACT_PASSES) this.ambientArtifactFacts.delete(asyncDir);
    }
  }

  /** Drop the routing records of closed slots and of directories no pass offered
   * within the last few passes, so the records follow the live slots. */
  private pruneAmbientArtifactRoutes(pass: number): void {
    for (const [slotId, routed] of this.ambientArtifactRoutes) {
      if (!this.slots.has(slotId)) {
        this.ambientArtifactRoutes.delete(slotId);
        continue;
      }
      for (const [asyncDir, record] of routed) {
        if (pass - record.pass >= AMBIENT_ARTIFACT_FACT_PASSES) routed.delete(asyncDir);
      }
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
