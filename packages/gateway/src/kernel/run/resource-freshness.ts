import { watch, type FSWatcher } from "node:fs";
import { readFile, readdir, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { DefaultPackageManager, loadProjectContextFiles, loadSkills, SettingsManager } from "../pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import { requestLayers } from "./request-record.js";
import type { RuntimeSlot } from "./runtime-slot.js";

export interface ResourceFreshnessRecord {
  sessionId?: string;
  reason: "completed" | "unchanged" | "failed" | "watch-failed";
}

interface PendingResource {
  digest: string;
  wanted: number;
  applied: number;
  idles: number;
  lastAttemptIdle: number;
  paths: Set<string>;
  ready: boolean;
  draining?: Promise<void> | undefined;
}

const AGENT_INPUTS = new Set(["settings.json", "prompts", "skills", "npm", "extensions", "AGENTS.md", "SYSTEM.md", "APPEND_SYSTEM.md"]);
const CONTEXT_FILES = ["AGENTS.md", "SYSTEM.md", "APPEND_SYSTEM.md"];

export class ResourceFreshness {
  private readonly watchers = new Map<string, { watcher: FSWatcher; recursive: boolean }>();
  private watchInputs = new Map<string, { relevant: (name: string) => boolean; recursive: boolean }>();
  private readonly states = new Map<RuntimeSlot, PendingResource>();
  private settle?: NodeJS.Timeout;
  private closed = false;

  constructor(private readonly options: {
    agentDir: string;
    diagnostic?: ((record: ResourceFreshnessRecord) => void) | undefined;
  }) {}

  start(): void { this.arm(); }

  async attach(slot: RuntimeSlot): Promise<void> {
    if (this.closed) return;
    const state: PendingResource = { digest: "", wanted: 0, applied: 0, idles: 0, lastAttemptIdle: 0, paths: new Set(), ready: false };
    this.states.set(slot, state);
    this.arm();
    try { state.digest = await this.digest(slot, state); this.arm(); }
    catch { state.wanted += 1; this.record(slot, "failed"); }
    finally { state.ready = true; }
  }

  detach(retired: string | RuntimeSlot): void {
    for (const slot of this.states.keys()) if (typeof retired === "string" ? slot.id === retired : slot === retired) this.states.delete(slot);
    this.arm();
  }

  idle(slot: RuntimeSlot): void {
    const state = this.states.get(slot);
    if (!state) return;
    state.idles += 1;
    this.apply(slot, state);
  }

  stale(projectDir?: string): void {
    if (this.closed) return;
    for (const [slot, state] of this.states) {
      if (projectDir !== undefined && slot.projectDir !== projectDir) continue;
      state.wanted += 1;
      this.apply(slot, state);
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    clearTimeout(this.settle);
    for (const { watcher } of this.watchers.values()) watcher.close();
    this.watchers.clear();
    await Promise.all([...this.states.values()].map(state => state.draining));
    this.states.clear();
  }

  private arm(): void {
    if (this.closed) return;
    const roots = new Map<string, { relevant: (name: string) => boolean; recursive: boolean }>();
    const add = (root: string, relevant: (name: string) => boolean, recursive = true): void => {
      const previous = roots.get(root);
      roots.set(root, { relevant: previous ? name => previous.relevant(name) || relevant(name) : relevant, recursive: recursive || previous?.recursive === true });
    };
    add(homedir(), name => name === ".agents", false);
    add(this.options.agentDir, name => AGENT_INPUTS.has(name.split(/[\\/]/)[0]!) || (!name.includes("/") && /\.md$/i.test(name)));
    add(join(homedir(), ".agents"), name => name.split(/[\\/]/)[0] === "skills");
    for (const [slot, state] of this.states) {
      add(slot.projectDir, name => name.split(/[\\/]/)[0] === ".pi" || (!name.includes("/") && /\.md$/i.test(name)));
      if (!slot.liveProfile().resources.noContextFiles) for (const directory of ancestors(slot.cwd)) add(directory, name => /\.md$/i.test(name), false);
      for (const path of state.paths) {
        if ([...roots].some(([root, { relevant }]) => path.startsWith(`${root}/`) && relevant(path.slice(root.length + 1)))) continue;
        add(path, () => true);
      }
    }
    this.watchInputs = roots;
    for (const [root, { watcher, recursive }] of this.watchers) {
      if (!roots.has(root) || roots.get(root)!.recursive !== recursive) { watcher.close(); this.watchers.delete(root); }
    }
    for (const [root, { recursive }] of roots) {
      if (this.watchers.has(root)) continue;
      const armedAt = Date.now();
      try {
        const watcher = watch(root, { recursive, persistent: false }, (_event, name) => {
          if (name !== null && !this.watchInputs.get(root)?.relevant(String(name))) return;
          void (name === null ? Promise.resolve(true) : stat(join(root, String(name))).then(info => info.ctimeMs >= armedAt, () => true))
            .then(changed => { if (changed) this.changed(); });
        });
        watcher.on("error", () => { watcher.close(); this.watchers.delete(root); this.options.diagnostic?.({ reason: "watch-failed" }); this.changed(); });
        this.watchers.set(root, { watcher, recursive });
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") this.options.diagnostic?.({ reason: "watch-failed" });
      }
    }
  }

  private changed(): void {
    if (this.closed) return;
    clearTimeout(this.settle);
    this.settle = setTimeout(() => { this.arm(); this.stale(); }, 150);
    this.settle.unref();
  }

  private apply(slot: RuntimeSlot, state: PendingResource): void {
    if (state.applied >= state.wanted || state.draining || !state.ready || this.closed || slot.isDisposed) return;
    state.draining = this.drain(slot, state).finally(() => {
      state.draining = undefined;
      if (state.applied < state.wanted && state.idles > state.lastAttemptIdle) this.apply(slot, state);
    });
  }

  private async drain(slot: RuntimeSlot, state: PendingResource): Promise<void> {
    while (!this.closed && this.states.get(slot) === state && state.applied < state.wanted) {
      const target = state.wanted;
      const idles = state.idles;
      state.lastAttemptIdle = idles;
      try {
        const digest = await this.digest(slot, state);
        this.arm();
        if (this.closed || this.states.get(slot) !== state) return;
        if (digest !== state.digest) {
          await slot.reload();
          if (this.closed || this.states.get(slot) !== state) return;
          state.digest = digest;
          this.record(slot, "completed");
        } else this.record(slot, "unchanged");
        state.applied = target;
      } catch (error) {
        if (error instanceof GatewayError && error.code === "busy") {
          if (idles !== state.idles) continue;
        } else this.record(slot, "failed");
        return;
      }
    }
  }

  private record(slot: RuntimeSlot, reason: ResourceFreshnessRecord["reason"]): void {
    this.options.diagnostic?.({ sessionId: slot.id, reason });
  }

  private async digest(slot: RuntimeSlot, state: PendingResource): Promise<string> {
    const inputs: Array<[string, unknown]> = [];
    const { agentDir } = this.options;
    const profile = slot.liveProfile();
    const global = await json(join(agentDir, "settings.json"));
    const project = profile.projectSettings ? await json(join(slot.projectDir, ".pi", "settings.json")) : {};
    const settings = SettingsManager.fromStorage({ withLock: (scope, read) => { read(JSON.stringify(scope === "global" ? global : project)); } },
      { projectTrusted: slot.runtime.session.settingsManager.isProjectTrusted() });
    const manager = new DefaultPackageManager({ cwd: slot.cwd, projectDir: slot.projectDir, agentDir, settingsManager: settings });
    const resolved = await manager.resolve(async () => "skip");
    const paths = new Set<string>();
    const packages = new Set<string>();
    const watchPath = async (path: string): Promise<void> => {
      if (path.startsWith("builtin:")) return;
      for (const candidate of new Set([path, await realpath(path).catch(() => path)])) {
        const directory = await stat(candidate).then(info => info.isDirectory(), () => false);
        paths.add(directory ? candidate : dirname(candidate));
      }
    };
    for (const kind of ["skills", "prompts", "extensions"] as const) {
      if (kind === "extensions" && profile.resources.noExtensions) continue;
      const enabled = resolved[kind].filter(entry => entry.enabled);
      if (kind !== "skills") inputs.push([kind, enabled.map(entry => entry.path).sort()]);
      for (const entry of enabled) {
        await watchPath(entry.path);
        if (entry.metadata.packageRoot) packages.add(entry.metadata.packageRoot);
        if (kind !== "skills" && !entry.path.startsWith("builtin:")) await files(entry.path, inputs, paths);
      }
    }
    const skills = loadSkills({ cwd: slot.cwd, agentDir, skillPaths: resolved.skills.filter(entry => entry.enabled).map(entry => entry.path), includeDefaults: true });
    inputs.push(["skills", skills.skills]);
    for (const root of packages) await file(join(root, "package.json"), inputs);
    inputs.push(["packages", settings.getPackages()]);
    if (!profile.resources.noContextFiles) {
      for (const context of loadProjectContextFiles({ cwd: slot.cwd, agentDir })) { inputs.push([context.path, context.content]); await watchPath(context.path); }
      for (const root of [agentDir, slot.projectDir, join(slot.projectDir, ".pi")]) for (const name of CONTEXT_FILES) await file(join(root, name), inputs);
    }
    state.paths = paths;
    return requestLayers({ system: [...new Map(inputs)].sort(([a], [b]) => a.localeCompare(b)) }).request.hash;
  }
}

function ancestors(directory: string): string[] {
  const paths = [directory];
  while (dirname(directory) !== directory) {
    directory = dirname(directory);
    paths.push(directory);
  }
  return paths;
}

async function json(path: string): Promise<Record<string, unknown>> {
  try { return JSON.parse(await readFile(path, "utf8")) as Record<string, unknown>; }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return {}; throw error; }
}

async function file(path: string, inputs: Array<[string, unknown]>): Promise<void> {
  try { inputs.push([path, await readFile(path, "utf8")]); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
}

async function files(root: string, inputs: Array<[string, unknown]>, watched: Set<string>, seen = new Set<string>()): Promise<void> {
  const canonical = await realpath(root).catch(() => root);
  if (seen.has(canonical)) return;
  seen.add(canonical);
  let entries;
  try { entries = await readdir(root, { withFileTypes: true }); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    if ((error as NodeJS.ErrnoException).code === "ENOTDIR") return file(root, inputs);
    throw error;
  }
  for (const entry of entries) {
    if (entry.name === ".git" || entry.name === "node_modules" || entry.name === ".cache") continue;
    const path = join(root, entry.name);
    const target = entry.isSymbolicLink() ? await realpath(path).catch(() => undefined) : path;
    if (!target) continue;
    const info = entry.isSymbolicLink() ? await stat(target).catch(() => undefined) : entry;
    if (!info) continue;
    if (entry.isSymbolicLink()) watched.add(info.isDirectory() ? target : dirname(target));
    if (info.isDirectory()) await files(path, inputs, watched, seen);
    else if (info.isFile()) await file(path, inputs);
  }
}
