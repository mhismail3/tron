import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, mkdtemp, open, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { KEYS, schemaKey } from "./settings-schema.js";
import { foldHomeChapter, migrateApprovals, migrateAuditEntry, migrateObserved, migrateSessionSettings, migrationObject,
  migrationRefusal, migrationSetPath, parseMigrationObject, type MigrationDefaults } from "./settings-migration-state.js";

type Document = Record<string, unknown>;
type FileKind = "json" | "audit" | "session";
export interface MigrationCapture {
  runtimeDirectories: string[];
  inputs: Array<{ path: string; hash: string | null }>;
  replacements: Array<{ path: string; before: string | null; after: string; index: number; staged: string }>;
  notes: Array<{ file: string; key: string; reason: string }>;
  dispose(): Promise<void>;
}
export async function migrationFileHash(path: string): Promise<string | null> {
  try {
    const stat = await lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink()) return migrationRefusal(path, "expected a regular non-symlink file");
    const hash = createHash("sha256");
    for await (const chunk of createReadStream(path)) hash.update(chunk);
    return hash.digest("hex");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    return migrationRefusal(path, "file could not be read safely");
  }
}
async function document(path: string, limit = 1024 * 1024): Promise<Document> {
  if (await migrationFileHash(path) === null) return {};
  if ((await lstat(path)).size > limit) return migrationRefusal(path, "JSON input exceeds its owner limit");
  return parseMigrationObject(await readFile(path, "utf8"), path);
}
export async function settingsMigrationInventory(tronHome: string, agentDir: string): Promise<{
  paths: string[]; kinds: Map<string, FileKind>; runtimeDirectories: string[]; profile: Document; home: Document;
}> {
  tronHome = resolve(tronHome); agentDir = resolve(agentDir);
  const profilePath = join(tronHome, "gateway", "home", "profile.json");
  // Validate the Profile first: a malformed copied Profile must refuse before
  // any SDK store or runtime lock owner, including an unrelated busy owner.
  const profile = await document(profilePath, 256 * 1024);
  const home = await document(join(tronHome, "gateway", "home", "home.json"));
  if (Object.keys(home).length && (home.version !== 2 || !Array.isArray(home.chapters))) migrationRefusal(join(tronHome, "gateway", "home", "home.json"), "invalid Home record");
  const global = await document(join(agentDir, "settings.json"));
  if (global.sessionDir !== undefined && (typeof global.sessionDir !== "string" || !global.sessionDir.trim())) migrationRefusal(join(agentDir, "settings.json"), "invalid canonical session directory");
  const configured = typeof global.sessionDir === "string" ? resolve(global.sessionDir) : undefined;
  const runtimeDirectories = [...new Set([agentDir, ...(configured ? [configured] : [])])];
  const kinds = new Map<string, FileKind>([
    ...["settings.json", "trust.json", "mcp.json", "models.json"].map(name => [join(agentDir, name), "json"] as const),
    ...["profile.json", "home.json"].map(name => [join(tronHome, "gateway", "home", name), "json"] as const),
    ...["gateway.json", "floors.json", "approvals.json", "observed.json"].map(name => [join(tronHome, "gateway", "settings", name), "json"] as const),
  ]);
  const scan = async (path: string, kind: "audit" | "session"): Promise<void> => {
    let entries;
    try {
      const stat = await lstat(path);
      if (stat.isSymbolicLink() || !stat.isDirectory()) return migrationRefusal(path, "input root is not a regular directory");
      entries = await readdir(path, { withFileTypes: true });
    } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; return migrationRefusal(path, "input directory could not be read"); }
    for (const entry of entries) {
      const child = join(path, entry.name);
      if (entry.isSymbolicLink()) migrationRefusal(child, "symbolic links are not migration inputs");
      if (entry.isDirectory()) await scan(child, kind);
      else if (entry.name.endsWith(".jsonl")) kinds.set(child, kind);
      else if (kind === "audit" && entry.name.endsWith(".json")) kinds.set(child, "json");
    }
  };
  await scan(join(tronHome, "gateway", "settings", "changes"), "audit");
  await scan(configured ?? join(agentDir, "sessions"), "session");
  return { paths: [...kinds.keys()].sort(), kinds, runtimeDirectories, profile, home };
}

/** Preflight writes only a disposable private plan. No SDK SessionManager is
 * opened and no canonical file changes until the backup transaction commits. */
export async function captureSettingsMigration(tronHome: string, agentDir: string): Promise<MigrationCapture> {
  const inventory = await settingsMigrationInventory(tronHome, agentDir);
  const temporary = await mkdtemp(join(tmpdir(), "tron-settings-migration-plan-"));
  const inputs: MigrationCapture["inputs"] = [];
  const replacements: MigrationCapture["replacements"] = [];
  const notes: MigrationCapture["notes"] = [];
  const dispose = () => rm(temporary, { recursive: true, force: true });
  try {
    const defaults: MigrationDefaults = { global: await document(join(resolve(agentDir), "settings.json")),
      gateway: await document(join(resolve(tronHome), "gateway", "settings", "gateway.json")), floors: {} };
    for (const key of KEYS) {
      const binding = key.layers.home;
      if (binding?.store !== "home") continue;
      let value: unknown = inventory.profile;
      for (const field of binding.path) value = value && typeof value === "object" && Object.hasOwn(value, field) ? (value as Document)[field] : undefined;
      if (value !== undefined) try { await key.type.validate(value, key.id); } catch { migrationRefusal(join(resolve(tronHome), "gateway", "home", "profile.json"), `invalid value for ${key.id}`); }
    }
    const chapters = Array.isArray(inventory.home.chapters) ? inventory.home.chapters : [];
    const active = chapters.findLast(value => migrationObject(value, "Home chapters").state === "active");
    const activeId = active === undefined ? undefined : migrationObject(active, "Home chapters").sessionId;
    let folded = inventory.profile;
    let foundActive = activeId === undefined;
    const stage = async (path: string, before: string | null, text: string) => {
      const after = createHash("sha256").update(text).digest("hex");
      if (after === before) return;
      const index = replacements.length;
      const staged = join(temporary, String(index));
      await writeFile(staged, text, { mode: 0o600 });
      replacements.push({ path, before, after, index, staged });
    };
    for (const path of inventory.paths) {
      const before = await migrationFileHash(path);
      inputs.push({ path, hash: before });
      if (before === null) continue;
      const kind = inventory.kinds.get(path)!;
      if (kind === "json") {
        const original = await document(path);
        let next = original;
        if (path === join(resolve(tronHome), "gateway", "settings", "changes", "index.json")) {
          if (original.version !== 1 || !Array.isArray(original.segments)) migrationRefusal(path, "invalid audit index");
          for (const value of original.segments as unknown[]) {
            const segment = migrationObject(value, path);
            if (typeof segment.name !== "string" || !/^(?:[0-9]{6}|once-[a-f0-9]{64})$/.test(segment.name)
              || !Number.isSafeInteger(segment.count) || (segment.count as number) < 0
              || !inventory.kinds.has(join(resolve(tronHome), "gateway", "settings", "changes", `${segment.name}.jsonl`))) migrationRefusal(path, "invalid audit segment reference");
          }
        }
        if (path === join(resolve(tronHome), "gateway", "settings", "approvals.json")) next = migrateApprovals(original, path);
        else if (path === join(resolve(tronHome), "gateway", "settings", "observed.json")) next = migrateObserved(original, path);
        if (JSON.stringify(next) !== JSON.stringify(original)) await stage(path, before, `${JSON.stringify(next, null, 2)}\n`);
      } else {
        const output = join(temporary, `stream-${replacements.length}`);
        const handle = await open(output, "wx", 0o600);
        type Branch = { settings?: Document; model?: unknown; thinking?: unknown };
        const branches = new Map<string, Branch>();
        let branch: Branch = {};
        let first = true, homeSession = false, canonicalSession = false, changed = false;
        try {
          for await (const line of createInterface({ input: createReadStream(path), crlfDelay: Infinity })) {
            if (!line.trim()) { await handle.write(`${line}\n`); continue; }
            const original = parseMigrationObject(line, path);
            let next = original;
            if (kind === "audit") next = migrateAuditEntry(original, path);
            else {
              if (first) { canonicalSession = original.type === "session"; homeSession = canonicalSession && original.id === activeId; if (homeSession) foundActive = true; }
              if (canonicalSession && original.type === "custom" && original.customType === "tron.settings.v1") next = migrateSessionSettings(original, path, defaults, notes);
              if (homeSession && typeof original.id === "string") {
                const parent = typeof original.parentId === "string" ? branches.get(original.parentId) : undefined;
                if (original.parentId && !parent) migrationRefusal(path, "active Home branch has an unknown parent");
                branch = { ...(parent ?? {}) };
                if (next.type === "custom" && next.customType === "tron.settings.v1") branch.settings = migrationObject(next.data, path);
                if (next.type === "model_change") branch.model = { provider: next.provider, id: next.modelId };
                if (next.type === "thinking_level_change") branch.thinking = next.thinkingLevel;
                branches.set(original.id, branch);
              }
            }
            first = false;
            if (JSON.stringify(next) !== JSON.stringify(original)) { changed = true; await handle.write(`${JSON.stringify(next)}\n`); }
            else await handle.write(`${line}\n`);
          }
        } finally { await handle.close(); }
        if (homeSession) folded = foldHomeChapter(folded, branch.settings, branch.model, branch.thinking, path);
        if (changed) {
          const after = (await migrationFileHash(output))!;
          replacements.push({ path, before, after, index: replacements.length, staged: output });
        } else await rm(output);
      }
      if (await migrationFileHash(path) !== before) migrationRefusal(path, "input changed while preflighting");
    }
    const homePath = join(resolve(tronHome), "gateway", "home", "home.json");
    if (!foundActive) migrationRefusal(homePath, "active chapter is not present in the canonical catalog");
    // The retired record model becomes Home's saved model when none is saved.
    if (Object.hasOwn(inventory.home, "model")) {
      const { model, ...record } = inventory.home;
      const key = schemaKey("model.ref[role=chat]"), path = (key.layers.home as { path: readonly string[] }).path;
      try { await key.type.validate(model, key.id); } catch { migrationRefusal(homePath, "invalid Home record model"); }
      if (path.reduce<unknown>((value, field) => value && typeof value === "object" ? (value as Document)[field] : undefined, folded) === undefined) {
        folded = structuredClone(folded); migrationSetPath(folded, path, model);
      }
      await stage(homePath, inputs.find(input => input.path === homePath)!.hash, `${JSON.stringify(record, null, 2)}\n`);
    }
    if (JSON.stringify(folded) !== JSON.stringify(inventory.profile)) {
      const path = join(resolve(tronHome), "gateway", "home", "profile.json");
      await stage(path, inputs.find(input => input.path === path)!.hash, `${JSON.stringify(folded, null, 2)}\n`);
    }
    return { runtimeDirectories: inventory.runtimeDirectories, inputs, replacements, notes, dispose };
  } catch (error) { await dispose(); throw error; }
}
