import { existsSync, statSync } from "node:fs";
import { GatewayError } from "../../errors.js";
import type { CanonicalAppendContext, CanonicalAppendPolicy } from "../../kernel/host/canonical-append.js";
import type { SessionManager } from "../../kernel/pi/coding-agent.js";
import { HOME_HARD_BYTES, HOME_HARD_ENTRIES, assertChapterWritable, SealedChapterMutationError, type HomeChapterState } from "./home-chapter-state.js";
import type { HomeDiagnostic, HomeHardBoundary } from "./home-diagnostic.js";

export type HomeMaterializationAuthority = Readonly<{
  homeId: string;
  ordinal: number;
  sessionId: string;
  attemptId: string;
  expectedPath: string;
}>;

export interface HomeAppendGuardServices {
  state(sessionId: string): HomeChapterState;
  admission(sessionId: string, metrics: { bytes: number; entries: number }): void;
  committed(sessionId: string): void;
  diagnostic: HomeDiagnostic;
}

/** One fence belongs to one slot across runtime rebuilds and rekeys. Weak
 * binding releases the guard with that slot; no second lifecycle map is needed. */
export function homeAppendGuardHook(services: () => HomeAppendGuardServices): (context: CanonicalAppendContext) => CanonicalAppendPolicy {
  const guards = new WeakMap<object, HomeAppendGuard>();
  return context => {
    let guard = guards.get(context.owner);
    if (!guard) {
      guard = new HomeAppendGuard(context, services);
      guards.set(context.owner, guard);
    }
    return guard;
  };
}

class HomeAppendGuard implements CanonicalAppendPolicy {
  private limitStop?: { operationId: string; boundary: HomeHardBoundary; crossingBytes: number; crossingEntries: number };

  constructor(private readonly context: CanonicalAppendContext, private readonly services: () => HomeAppendGuardServices) {}

  append(manager: SessionManager, append: () => void): void {
    if (this.context.guardedProfile(manager)) {
      const path = manager.getSessionFile();
      const fileExists = path ? existsSync(path) : false;
      if (this.context.activeOperationId() !== undefined || fileExists) this.assertWritable(manager);
    }
    append();
    if (manager === this.context.manager()) this.observeGrowth();
  }

  assertWritable(manager: SessionManager): void {
    const state = this.services().state(manager.getSessionId());
    const authority = this.context.writeAuthority as HomeMaterializationAuthority | undefined;
    const ownsMaterialization = Boolean(authority
      && state.materializing
      && state.homeId === authority.homeId
      && state.ordinal === authority.ordinal
      && state.sessionId === authority.sessionId
      && state.attemptId === authority.attemptId
      && state.expectedPath === authority.expectedPath
      && manager.getSessionId() === authority.sessionId
      && manager.getSessionFile() === authority.expectedPath);
    try { assertChapterWritable(state, ownsMaterialization); }
    catch (error) {
      if (error instanceof SealedChapterMutationError) this.services().diagnostic({ outcome: "chapter-refused", reason: "sealed-write" });
      throw error;
    }
  }

  admission(): void {
    if (this.limitStop) throw new GatewayError("conflict", "Home stopped this activation at its chapter limit", true, {
      reason: "chapter-limit-stop",
    });
    this.assertWritable(this.context.manager());
    if (!this.services().state(this.context.sessionId()).homeId) return;
    const path = this.context.sessionFile();
    let bytes = 0;
    if (path) {
      try { bytes = statSync(path).size; }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    }
    this.services().admission(this.context.sessionId(), { bytes, entries: this.context.entryCount() });
  }

  committed(): void {
    this.services().committed(this.context.sessionId());
  }

  isPreAppendRefusal(error: unknown): boolean {
    return error instanceof SealedChapterMutationError;
  }

  private observeGrowth(): void {
    if (!this.context.guardedProfile(this.context.manager()) || this.limitStop) return;
    const operationId = this.context.activeOperationId();
    if (!operationId) return;
    const path = this.context.manager().getSessionFile();
    let bytes = 0;
    if (path) {
      try { bytes = statSync(path).size; } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") return;
      }
    }
    const entries = this.context.entryCount();
    const boundary = bytes >= HOME_HARD_BYTES ? "hard-bytes"
      : entries >= HOME_HARD_ENTRIES ? "hard-entries" : undefined;
    if (!boundary) return;
    const crossing = { operationId, boundary, crossingBytes: bytes, crossingEntries: entries } as const;
    this.limitStop = crossing;
    void this.context.abort(operationId, "chapter-limit").then(() => {
      try {
        const settledBytes = path ? statSync(path).size : 0;
        const settledEntries = this.context.entryCount();
        this.services().diagnostic({
          outcome: "chapter-limit-stop",
          chapterOrdinal: this.services().state(this.context.sessionId()).ordinal ?? 0,
          boundary,
          crossingBytes: crossing.crossingBytes,
          crossingEntries: crossing.crossingEntries,
          settledBytes,
          settledEntries,
        });
      } finally {
        // The Stop settled, so release its fence even if reading the crossing failed.
        if (this.limitStop === crossing) delete this.limitStop;
      }
    }, error => {
      // An unjoined Stop keeps the admission fence, as the writer still owns work.
      this.context.diagnostic({ code: "home-chapter-limit-stop-failed", message: String(error).slice(0, 256) });
    }).catch(error => {
      this.context.diagnostic({ code: "home-chapter-limit-stop-failed", message: String(error).slice(0, 256) });
    });
  }
}
