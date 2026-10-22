import { chmod, copyFile, lstat, mkdir, mkdtemp, open, readFile, readdir, rename, rm } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { GatewayError } from "../errors.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import { captureSettingsMigration, migrationFileHash, settingsMigrationInventory } from "./settings-migration-plan.js";

/** The caller already holds the canonical runtime lock (gateway-main runs this
 * after acquiring it and binding its listener); this adds no second lock. */
export interface SettingsMigrationOptions {
  tronHome: string;
  agentDir: string;
}
interface Input { path: string; hash: string | null }
interface Replacement { path: string; before: string | null; after: string; index: number }
interface Journal {
  version: 1;
  state: "prepared" | "complete";
  tronHome: string;
  agentDir: string;
  runtimeDirectories: string[];
  inputs: Input[];
  replacements: Replacement[];
  notes: Array<{ file: string; key: string; reason: string }>;
}
const name = "three-layer-v1";
const hashPattern = /^[a-f0-9]{64}$/;
const fail = (path: string, reason: string): never => { throw new GatewayError("conflict", `Settings migration refused ${path}: ${reason}`); };
const directory = (options: SettingsMigrationOptions) => join(resolve(options.tronHome), "gateway", "settings", "migrations", name);
async function syncDirectory(path: string): Promise<void> {
  const handle = await open(path, "r");
  try { await handle.sync(); } finally { await handle.close(); }
}
async function syncFile(path: string): Promise<void> {
  const handle = await open(path, "r+");
  try { await handle.sync(); } finally { await handle.close(); }
}
async function readJournal(path: string, options: SettingsMigrationOptions): Promise<Journal | undefined> {
  let text: string;
  try { text = await readFile(path, "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; return fail(path, "journal could not be read"); }
  let value: Journal;
  try { value = JSON.parse(text) as Journal; } catch { return fail(path, "journal is not valid JSON"); }
  if (value.version !== 1 || !["prepared", "complete"].includes(value.state)
    || value.tronHome !== resolve(options.tronHome) || value.agentDir !== resolve(options.agentDir)
    || !Array.isArray(value.runtimeDirectories) || !value.runtimeDirectories.includes(resolve(options.agentDir))
    || value.runtimeDirectories.some(root => typeof root !== "string" || !isAbsolute(root))
    || !Array.isArray(value.inputs) || !Array.isArray(value.replacements) || !Array.isArray(value.notes)) return fail(path, "journal identity is invalid");
  const roots = [value.tronHome, ...value.runtimeDirectories];
  const inside = (candidate: string) => typeof candidate === "string" && isAbsolute(candidate)
    && roots.some(root => { const child = relative(root, candidate); return child !== "" && child !== ".." && !child.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) && !isAbsolute(child); });
  const paths = new Set<string>();
  for (const input of value.inputs) {
    if (!inside(input.path) || paths.has(input.path) || (input.hash !== null && !hashPattern.test(input.hash))) return fail(path, "input manifest is invalid");
    paths.add(input.path);
  }
  const replacements = new Set<string>();
  for (const replacement of value.replacements) {
    if (!paths.has(replacement.path) || replacements.has(replacement.path) || !Number.isSafeInteger(replacement.index) || replacement.index < 0
      || (replacement.before !== null && !hashPattern.test(replacement.before)) || !hashPattern.test(replacement.after)
      || value.inputs.find(input => input.path === replacement.path)?.hash !== replacement.before) return fail(path, "replacement manifest is invalid");
    replacements.add(replacement.path);
  }
  return value;
}
async function verifyInputs(journal: Journal, recovering: boolean): Promise<void> {
  for (const input of journal.inputs) {
    const current = await migrationFileHash(input.path);
    const replacement = journal.replacements.find(candidate => candidate.path === input.path);
    if (current !== input.hash && !(recovering && replacement && current === replacement.after)) fail(input.path, "input changed outside the migration; no overwrite was attempted");
  }
}
async function verifyPayloads(root: string, journal: Journal): Promise<void> {
  // Validate every backup and staged replacement before publishing even one file.
  for (const [index, input] of journal.inputs.entries()) {
    if (input.hash !== null && await migrationFileHash(join(root, "backup", String(index))) !== input.hash) fail(input.path, "backup hash does not match");
  }
  for (const replacement of journal.replacements) {
    if (await migrationFileHash(join(root, "stage", String(replacement.index))) !== replacement.after) fail(replacement.path, "staged hash does not match");
  }
}

/** One durable transaction over the small shared stores. Prepared intent survives
 * interruption; the next startup resumes this same transaction before their owners load. */
export class SettingsMigration {
  private constructor(private readonly root: string, private readonly journal: Journal, readonly alreadyComplete: boolean) {}

  static async prepare(options: SettingsMigrationOptions): Promise<SettingsMigration> {
    const root = directory(options);
    const journalPath = join(root, "journal.json");
    const saved = await readJournal(journalPath, options);
    if (saved?.state === "complete") return new SettingsMigration(root, saved, true);
    if (saved) {
      await verifyPayloads(root, saved);
      const inventory = await settingsMigrationInventory(options.tronHome, options.agentDir);
      if (JSON.stringify(inventory.paths) !== JSON.stringify(saved.inputs.map(input => input.path))) fail(root, "input inventory changed after preparation");
      await verifyInputs(saved, true);
      return new SettingsMigration(root, saved, false);
    }
    const capture = await captureSettingsMigration(options.tronHome, options.agentDir);
    let temporary: string | undefined;
    try {
      const current = await readJournal(journalPath, options);
      if (current) fail(journalPath, "another startup prepared this migration; restart to resume it");
      const journal: Journal = { version: 1, state: "prepared", tronHome: resolve(options.tronHome), agentDir: resolve(options.agentDir),
        runtimeDirectories: capture.runtimeDirectories, inputs: capture.inputs, replacements: capture.replacements.map(({ path, before, after, index }) => ({ path, before, after, index })), notes: capture.notes };
      const inventory = await settingsMigrationInventory(options.tronHome, options.agentDir);
      if (JSON.stringify(inventory.paths) !== JSON.stringify(capture.inputs.map(input => input.path))) fail(root, "input inventory changed during preflight");
      await verifyInputs(journal, false);
      const parent = dirname(root);
      await mkdir(parent, { recursive: true, mode: 0o700 });
      for (const entry of await readdir(parent)) if (entry.startsWith(`.${name}-staging-`)) await rm(join(parent, entry), { recursive: true, force: true });
      temporary = await mkdtemp(join(parent, `.${name}-staging-`));
      await chmod(temporary, 0o700);
      await mkdir(join(temporary, "backup"), { mode: 0o700 });
      await mkdir(join(temporary, "stage"), { mode: 0o700 });
      // Back up the entire input set, including unchanged policy/audit files,
      // before staging replacements or accepting durable migration intent.
      for (const [index, input] of capture.inputs.entries()) if (input.hash !== null) {
        const destination = join(temporary, "backup", String(index));
        await copyFile(input.path, destination); await chmod(destination, 0o600); await syncFile(destination);
      }
      for (const replacement of capture.replacements) {
        const destination = join(temporary, "stage", String(replacement.index));
        await copyFile(replacement.staged, destination); await chmod(destination, 0o600); await syncFile(destination);
      }
      await verifyInputs(journal, false);
      await verifyPayloads(temporary, journal);
      await durableAtomicWriteJson(join(temporary, "journal.json"), journal);
      await syncDirectory(join(temporary, "backup")); await syncDirectory(join(temporary, "stage")); await syncDirectory(temporary);
      await rename(temporary, root); temporary = undefined; await syncDirectory(parent);
      return new SettingsMigration(root, journal, false);
    } catch (error) {
      if (temporary) await rm(temporary, { recursive: true, force: true });
      throw error;
    } finally { await capture.dispose(); }
  }

  async complete(): Promise<void> {
    if (this.alreadyComplete || this.journal.state === "complete") return;
    await verifyPayloads(this.root, this.journal);
    await verifyInputs(this.journal, true);
    for (const replacement of this.journal.replacements) {
      if (await migrationFileHash(replacement.path) === replacement.after) continue;
      // A private sibling is published atomically, preserving canonical paths
      // and every unrelated byte in the staged document. Never truncate in place.
      await mkdir(dirname(replacement.path), { recursive: true, mode: 0o700 });
      const temporary = `${replacement.path}.settings-three-layer-v1.tmp`;
      try {
        try { if ((await lstat(temporary)).isSymbolicLink()) fail(temporary, "temporary path is a symbolic link"); }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
        await copyFile(join(this.root, "stage", String(replacement.index)), temporary);
        await chmod(temporary, 0o600); await syncFile(temporary);
        if (await migrationFileHash(replacement.path) !== replacement.before) fail(replacement.path, "input changed before publication");
        await rename(temporary, replacement.path); await syncDirectory(dirname(replacement.path));
      } finally { await rm(temporary, { force: true }); }
    }
    await durableAtomicWriteJson(join(this.root, "journal.json"), { ...this.journal, state: "complete" });
    this.journal.state = "complete";
  }

  /** Inputs and published replacements, for the startup record. */
  get counts(): { inputs: number; replaced: number } { return { inputs: this.journal.inputs.length, replaced: this.alreadyComplete ? 0 : this.journal.replacements.length }; }
}

export async function migrateSettings(options: SettingsMigrationOptions): Promise<{ inputs: number; replaced: number; alreadyComplete: boolean }> {
  const migration = await SettingsMigration.prepare(options);
  await migration.complete();
  return { ...migration.counts, alreadyComplete: migration.alreadyComplete };
}
