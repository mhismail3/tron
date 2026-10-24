import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import type { SessionEntry } from "../../kernel/pi/coding-agent.js";
import { SessionManager } from "../../kernel/pi/coding-agent.js";
import type { TrustService } from "../../admin/trust-service.js";
import type { RuntimeSlot } from "../../sessions/runtime-slot.js";
import { branchFromSessionEntries } from "../../sessions/session-branch.js";
import { appendChatSettingsSnapshot } from "../../sessions/session-settings.js";
import { appendContextWindowSnapshot } from "../../providers/context-window-policy.js";
import type { LineageRuntimePort } from "../../kernel/host/session-lineage.js";
import type { HomeDiagnostic } from "./home-diagnostic.js";
import type { HomeOwner } from "./home-owner.js";
import { scanReservedHomeSession } from "./home-session-recovery.js";
import { HOME_SESSION_PROFILE_NAME } from "./home-session-profile.js";

/** Home's reserved-successor procedure: claim, recover or create the chapter's
 * session, then publish the observed materialization (k0-kernel.md §5). */
export class HomeChapterMaterializer {
  constructor(
    private readonly owner: HomeOwner,
    private readonly runtimes: LineageRuntimePort<RuntimeSlot>,
    private readonly trust: TrustService,
    private readonly diagnostic: HomeDiagnostic | undefined,
  ) {}

  /**
   * One reservation-scoped materialization promise. Callers await this before
   * dispatching their own input, so joining never consumes or replays a command.
   */
  async materialize(sessionId: string): Promise<RuntimeSlot> {
    const { slot: existingSlot, existing } = await this.runtimes.materializeRuntime(sessionId, () => this.create(sessionId));
    if (!existing) return existingSlot;
    const reservation = this.owner.reservedChapter(sessionId);
    if (reservation?.state === "materializing" && reservation.attemptId && reservation.expectedPath && reservation.expectedPath === existingSlot.sessionFile) {
      await this.owner.assertReservedChapterAttempt(sessionId, reservation.attemptId, reservation.expectedPath);
    } else {
      const path = existingSlot.sessionFile;
      if (!path) throw new GatewayError("conflict", "Live Home chapter has no canonical path", true);
      await this.owner.assertPublishedHomeChapter(sessionId, path);
    }
    return existingSlot;
  }

  async assertAttempt(sessionId: string): Promise<void> {
    const slot = await this.runtimes.orderedRuntime(sessionId);
    if (!slot || slot.isDisposed || !slot.sessionFile) throw new GatewayError("conflict", "No live Home reservation runtime exists", true);
    const chapter = this.owner.reservedChapter(sessionId);
    if (chapter?.state === "materializing" && chapter.attemptId && chapter.expectedPath) {
      if (slot.sessionFile !== chapter.expectedPath) throw new GatewayError("conflict", "Home runtime path differs from its reservation", true);
      await this.owner.assertReservedChapterAttempt(sessionId, chapter.attemptId, chapter.expectedPath);
      return;
    }
    await this.owner.assertPublishedHomeChapter(sessionId, slot.sessionFile);
  }

  private async create(sessionId: string): Promise<RuntimeSlot> {
    const attemptId = randomUUID();
    const chapter = await this.owner.claimReservedChapter(sessionId, attemptId);
    const cwd = await this.trust.requireResolved(this.owner.homeWorkspacePath());
    const sessionDirectory = this.runtimes.sessionDirectory(cwd.cwd);
    let expectedPath = chapter.expectedPath ?? join(sessionDirectory, `.home-reservation-${sessionId}.jsonl`);
    const scan = await scanReservedHomeSession({ directory: sessionDirectory, expectedPath, sessionId });
    if (scan.action === "blocked") {
      this.diagnostic?.({ outcome: "chapter-refused", reason: "uncertain-session-evidence" });
      throw new GatewayError("conflict", "Home chapter recovery is blocked by uncertain session evidence");
    }
    this.diagnostic?.({ outcome: "chapter-recovery", reason: scan.action });
    // Pi's public newSession API selects a timestamped path but stages setup
    // entries: no file is persisted until the first user or assistant entry.
    // Once a previous attempt durably named a different
    // path, absence is not permission to silently replace that binding: no
    // verified exact-path adapter exists in the pinned SDK, so preserve and
    // block rather than create evidence outside the recorded attempt.
    if (chapter.expectedPath && scan.action === "absent") {
      throw new GatewayError("conflict", "Home recovery is blocked because its recorded chapter path is absent");
    }

    // Resolve the sealed predecessor before reserving a new durable path. A
    // failed read must not strand an otherwise absent materialization attempt.
    const previousId = scan.action === "absent" ? this.owner.settingsPredecessor(sessionId) : undefined;
    // A never-prompted live predecessor can still have SDK-staged choices and
    // no physical file. Its sealed slot is the canonical owner; cold reads must
    // instead prove the exact durable file and may not treat absence as defaults.
    const previous = previousId ? await this.runtimes.canonicalEntries(previousId) : undefined;
    const previousFromLive = previous?.live === true;
    const previousEntries = previous?.entries ?? undefined;
    if (previousId && !previousEntries) throw new GatewayError("conflict", "Home settings predecessor is missing");
    const previousBranch = previousEntries ? branchFromSessionEntries(previousEntries.filter((entry): entry is SessionEntry => entry.type !== "session")) : undefined;
    if (previousId && !previousBranch) throw new GatewayError("conflict", "Home settings predecessor is invalid");
    let manager!: SessionManager;
    return this.runtimes.createRuntimeOver(sessionId, {
      profile: HOME_SESSION_PROFILE_NAME,
      prepare: async () => {
        if (scan.action === "adopt") {
          // The scan adopts only the path it was given, so a mismatch means the
          // durable reservation names a different file.
          if (chapter.expectedPath !== scan.path) {
            throw new GatewayError("conflict", "Home chapter recovery path no longer matches its durable reservation");
          }
          manager = SessionManager.open(scan.path, sessionDirectory, cwd.cwd);
          if (manager.getSessionId() !== sessionId || manager.getSessionFile() !== scan.path) {
            throw new GatewayError("conflict", "Home chapter recovery did not reopen the exact reserved session");
          }
          // The durable path was recorded by the earlier process; this attempt
          // rebinds it before any runtime can submit canonical input.
          await this.owner.recordReservedChapterPath(sessionId, attemptId, scan.path);
        } else {
          manager = SessionManager.create(cwd.cwd, sessionDirectory);
          const createdPath = manager.newSession({ id: sessionId });
          if (!createdPath) throw new GatewayError("internal", "Home chapter creation did not reserve a session path");
          // These metadata-only appends stage in Pi. Validate and stage the
          // inherited policy before committing the new path to the Home ledger.
          if (previousBranch) {
            appendChatSettingsSnapshot(previousBranch, manager);
            appendContextWindowSnapshot(previousBranch, manager);
          }
          await this.owner.recordReservedChapterPath(sessionId, attemptId, createdPath);
          expectedPath = createdPath;
        }
        return manager;
      },
      authority: () => {
        const chapterState = this.owner.chapterStateFor(sessionId);
        if (!chapterState.materializing || !chapterState.homeId || chapterState.ordinal !== chapter.ordinal
          || chapterState.attemptId !== attemptId || chapterState.expectedPath !== expectedPath) {
          throw new GatewayError("conflict", "Home materialization authority no longer matches its durable reservation", true);
        }
        return { homeId: chapterState.homeId, ordinal: chapterState.ordinal, sessionId, attemptId, expectedPath };
      },
      admitted: (slot) => {
        if (slot.id !== sessionId || slot.sessionFile !== manager.getSessionFile()) {
          throw new GatewayError("conflict", "Home chapter runtime identity differs from its reservation");
        }
        if (previousBranch) this.diagnostic?.({ outcome: "chapter-recovery", reason: previousFromLive ? "settings-from-live" : "settings-from-cold" });
      },
      published: async () => { await this.owner.publishObservedMaterialization(sessionId, attemptId, expectedPath); },
      failed: () => { this.diagnostic?.({ outcome: "chapter-refused", reason: "materialization-failed" }); },
    });
  }
}
