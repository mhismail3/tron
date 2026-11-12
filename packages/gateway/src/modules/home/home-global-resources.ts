import { watch, type FSWatcher } from "node:fs";
import { stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import type { HomeDiagnostic } from "./home-diagnostic.js";

interface HomeResourceSlot {
  readonly id: string;
  reload(): Promise<void>;
}

const AGENT_DIR_INPUTS = new Set(["settings.json", "prompts", "skills", "npm"]);
const SETTLE_MS = 150;

export class HomeGlobalResources {
  private readonly watchers = new Map<string, FSWatcher>();
  private settle: NodeJS.Timeout | undefined;
  private wanted = 0;
  private applied = 0;
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
    const armedAt = Date.now();
    try {
      watcher = watch(path, { recursive, persistent: false }, (_event, name) => {
        const entry = name === null ? null : String(name);
        if (!relevant(entry)) return;
        if (entry === null) return this.changed();
        void changedSince(join(path, entry), armedAt).then(changed => { if (changed) this.changed(); });
      });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") this.options.diagnostic?.({ outcome: "resources-reload", reason: "watch-failed" });
      return;
    }
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
      if (!slot) return void (this.applied = target);
      const idles = this.idles;
      try {
        await slot.reload();
      } catch (error) {
        if (error instanceof GatewayError && error.code === "busy") {
          if (idles === this.idles) return;
          continue;
        }
        this.options.diagnostic?.({ outcome: "resources-reload", reason: error instanceof GatewayError ? error.code : "failed" });
        return;
      }
      this.applied = target;
      this.options.diagnostic?.({ outcome: "resources-reload", reason: "completed" });
    }
  }
}

async function changedSince(path: string, since: number): Promise<boolean> {
  try {
    return (await stat(path)).ctimeMs >= since;
  } catch {
    return true;
  }
}
