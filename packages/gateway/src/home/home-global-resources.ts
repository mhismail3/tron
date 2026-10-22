import { watch, type FSWatcher } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import type { HomeDiagnostic } from "./home-diagnostic.js";

/** The live Home runtime, reloaded through the same `RuntimeSlot.reload` an
 * ordinary chat's resource reload uses. */
export interface HomeResourceSlot {
  readonly id: string;
  reload(): Promise<void>;
}

/** Entries of the agent directory itself whose change can alter Home's global
 * prompts, skills or package resources; every other write there (sessions,
 * auth, run history) is ignored. */
const AGENT_DIR_INPUTS = new Set(["settings.json", "prompts", "skills"]);
/** Coalesces an editor's burst of writes into one reload. */
const SETTLE_MS = 150;

/**
 * Keeps Home's global (user-level) skills and prompt templates current.
 *
 * Ordinary chats pick up global resources whenever a runtime is built (a new
 * chat, a cold open); Home is one long-lived runtime, so it follows the same
 * inputs Pi's package manager discovers — the agent directory's `settings.json`,
 * `prompts/` and `skills/`, and `~/.agents/skills` — and reloads when they
 * change. A change that arrives while Home runs waits for Home to settle. The
 * reload publishes `session.resourcesChanged`, so clients refetch commands.
 * The agent directory is watched recursively from start, so `prompts/` and
 * `skills/` created, deleted or replaced later need no watcher of their own:
 * `fs.watch` has no readiness signal, and a watcher armed only once such a
 * directory appeared missed the edits made before its stream started (#1664).
 * `~/.agents/skills` created later is seen after the next agent-directory change.
 */
export class HomeGlobalResources {
  private readonly watchers = new Map<string, FSWatcher>();
  private settle: NodeJS.Timeout | undefined;
  /** Changes seen and changes a completed reload covers. */
  private wanted = 0;
  private applied = 0;
  /** Home settlements seen, so a refusal that raced one retries at once. */
  private idles = 0;
  private draining: Promise<void> | undefined;
  private closed = false;

  constructor(private readonly options: {
    agentDir: string;
    homeSlot: () => HomeResourceSlot | undefined;
    diagnostic?: HomeDiagnostic;
  }) {}

  start(): void {
    this.arm();
  }

  /** Home's session settled; apply a change that arrived while it ran. */
  idle(sessionId: string): void {
    if (this.options.homeSlot()?.id !== sessionId) return;
    this.idles += 1;
    if (this.applied < this.wanted) this.apply();
  }

  close(): void {
    this.closed = true;
    clearTimeout(this.settle);
    for (const watcher of this.watchers.values()) watcher.close();
    this.watchers.clear();
  }

  private arm(): void {
    const { agentDir } = this.options;
    this.watch(agentDir, true, name => name === null || AGENT_DIR_INPUTS.has(name.split(/[\\/]/)[0]!));
    this.watch(join(homedir(), ".agents", "skills"), true, () => true);
  }

  private watch(path: string, recursive: boolean, relevant: (name: string | null) => boolean): void {
    if (this.closed || this.watchers.has(path)) return;
    let watcher: FSWatcher;
    try {
      watcher = watch(path, { recursive, persistent: false }, (_event, name) => {
        if (relevant(name === null ? null : String(name))) this.changed();
      });
    } catch (error) {
      // Absent: armed when the agent directory reports its creation.
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") this.options.diagnostic?.({ outcome: "resources-reload", reason: "watch-failed" });
      return;
    }
    // macOS watchers follow a deleted and recreated directory by path; one that errors instead
    // is dropped here and re-armed by its parent's event.
    watcher.on("error", () => {
      watcher.close();
      if (this.watchers.get(path) === watcher) this.watchers.delete(path);
      this.changed();
    });
    this.watchers.set(path, watcher);
  }

  private changed(): void {
    if (this.closed) return;
    clearTimeout(this.settle);
    this.settle = setTimeout(() => {
      this.arm();
      this.wanted += 1;
      this.apply();
    }, SETTLE_MS);
    this.settle.unref();
  }

  private apply(): void {
    this.draining ??= this.drain().catch(() => {}).finally(() => { this.draining = undefined; });
  }

  private async drain(): Promise<void> {
    while (!this.closed && this.applied < this.wanted) {
      const slot = this.options.homeSlot();
      const target = this.wanted;
      // No live Home: its next runtime loads the current resources.
      if (!slot) return void (this.applied = target);
      const idles = this.idles;
      try {
        await slot.reload();
      } catch (error) {
        // A running Home retries when it settles (`idle`), or now if it already did.
        if (error instanceof GatewayError && error.code === "busy") {
          if (idles === this.idles) return;
          continue;
        }
        this.options.diagnostic?.({ outcome: "resources-reload", reason: error instanceof GatewayError ? error.code : "failed" });
      }
      this.applied = target;
    }
  }
}
