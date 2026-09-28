import type { KnowledgeChange } from "./knowledge-store.js";

/** One committed change is one notification. An intake item commits several
 * times (capture, provider metadata, quality, admission, remote move), and a
 * client must not replay its first page for each commit. The window coalesces
 * them into one payload carrying the latest state revision and the union of the
 * records the window touched. */
export const KNOWLEDGE_CHANGE_WINDOW_MS = 250;
/** Above this many records the union is omitted, and the client refreshes its
 * first page instead of asking for identities it cannot bound. */
export const KNOWLEDGE_CHANGE_MAX_RECORD_IDS = 64;

export class KnowledgeChangeCoalescer {
  private readonly recordIds = new Set<string>();
  private stateRevision = 0;
  private overflow = false;
  private timer: NodeJS.Timeout | undefined;

  constructor(
    private readonly publish: (change: KnowledgeChange) => void,
    private readonly windowMs: number = KNOWLEDGE_CHANGE_WINDOW_MS,
    private readonly maxRecordIds: number = KNOWLEDGE_CHANGE_MAX_RECORD_IDS,
  ) {}

  record(change: KnowledgeChange): void {
    this.stateRevision = Math.max(this.stateRevision, change.stateRevision);
    const ids = change.recordIds ?? [];
    if (this.recordIds.size + ids.length > this.maxRecordIds) this.overflow = true;
    else for (const id of ids) this.recordIds.add(id);
    if (this.timer) return;
    // A pending window must never keep the process alive past shutdown.
    this.timer = setTimeout(() => { this.timer = undefined; this.fire(); }, this.windowMs);
    this.timer.unref?.();
  }

  private fire(): void {
    const recordIds = [...this.recordIds];
    const overflow = this.overflow;
    this.recordIds.clear(); this.overflow = false;
    const change: KnowledgeChange = { stateRevision: this.stateRevision };
    if (!overflow && recordIds.length > 0) change.recordIds = recordIds;
    this.publish(change);
  }
}
