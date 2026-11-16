import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, open, readdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readSecureJson } from "../foundation/secure-json.js";
import { syncDurably } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EPISODIC_DEFAULTS } from "./episodic-contract.js";
import { EpisodicStore, type EpisodicStoreFileSystem } from "./episodic-store.js";

export type LayoutMigrationFileSystem = EpisodicStoreFileSystem & { copyFile: typeof copyFile };

const productionFileSystem: LayoutMigrationFileSystem = { copyFile, lstat, mkdir, open, readdir, rename, rm, writeFile, syncDurably };

interface PlannedFile { path: string; bytes: number; sha256: string }

export interface LayoutMigrationPlan {
  home: string;
  homeId: string;
  storeRoot: string;
  directories: string[];
  files: PlannedFile[];
}

const EMPTY_LAYOUT = `${JSON.stringify({ lines: [] })}\n`;

async function sha256(path: string): Promise<string> {
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const hash = createHash("sha256");
    for await (const chunk of handle.createReadStream({ autoClose: false })) hash.update(chunk as Buffer);
    return hash.digest("hex");
  } finally { await handle.close(); }
}

async function inventory(storeRoot: string): Promise<Pick<LayoutMigrationPlan, "directories" | "files">> {
  const directories: string[] = [];
  const files: PlannedFile[] = [];
  const walk = async (relativeDirectory: string): Promise<void> => {
    const absolute = join(storeRoot, relativeDirectory);
    const info = await lstat(absolute);
    if (!info.isDirectory() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) throw new Error(`Unsafe store directory ${relativeDirectory || "."}`);
    if (relativeDirectory) directories.push(relativeDirectory);
    for (const name of (await readdir(absolute)).sort()) {
      const path = relativeDirectory ? join(relativeDirectory, name) : name;
      if (path === "layout.json") throw new Error("The memory store already has a layout; it is migrated");
      const entry = await lstat(join(storeRoot, path));
      if (entry.isDirectory()) { await walk(path); continue; }
      if (!entry.isFile() || entry.uid !== process.getuid?.() || (entry.mode & 0o077) !== 0) throw new Error(`Unsafe store entry ${path}`);
      files.push({ path, bytes: entry.size, sha256: await sha256(join(storeRoot, path)) });
    }
  };
  await walk("");
  return { directories, files };
}

export async function planLayoutMigration(home: string, homeId?: string): Promise<LayoutMigrationPlan> {
  home = resolve(home);
  if (homeId === undefined) {
    const ledger = await readSecureJson<{ homeId?: unknown }>(tronHomePath(home, "state/home/home.json"), 2_097_152);
    if (!ledger.present || typeof ledger.value.homeId !== "string") throw new Error("No Home ledger names this home's memory");
    homeId = ledger.value.homeId;
  }
  if (!/^[A-Za-z0-9._-]{1,160}$/u.test(homeId)) throw new Error("Invalid Home id");
  const storeRoot = join(tronHomePath(home, "workspace"), "state", "episodic", homeId);
  return { home, homeId, storeRoot, ...(await inventory(storeRoot)) };
}

async function syncPath(path: string, fileSystem: LayoutMigrationFileSystem): Promise<void> {
  const handle = await fileSystem.open(path, constants.O_RDONLY);
  try { await fileSystem.syncDurably(handle); } finally { await handle.close(); }
}

export async function applyLayoutMigration(plan: LayoutMigrationPlan, backup: string, leaseOwnerPid: number, fileSystem: LayoutMigrationFileSystem = productionFileSystem): Promise<{ homeId: string; backup: string; files: number; bytes: number }> {
  const assertLeaseOwner = () => {
    if (!Number.isSafeInteger(leaseOwnerPid) || leaseOwnerPid <= 1 || process.ppid !== leaseOwnerPid) throw new Error("Offline migration lease owner was lost");
  };
  assertLeaseOwner();
  backup = resolve(backup);
  const inside = relative(plan.home, backup);
  if (!(inside === ".." || inside.startsWith("../") || isAbsolute(inside))) throw new Error("The backup must lie outside the Tron home");
  const workspace = new TronWorkspace(plan.home);
  await workspace.initialize();
  try {
    if (!(await workspace.describe()).available) throw new Error("Workspace is unavailable or still owned by the Gateway; stop Tron before migrating");
    const copyRoot = join(backup, plan.homeId);
    await fileSystem.mkdir(backup, { mode: 0o700 });
    await fileSystem.mkdir(copyRoot, { mode: 0o700 });
    for (const directory of plan.directories) await fileSystem.mkdir(join(copyRoot, directory), { mode: 0o700 });
    for (const file of plan.files) {
      const copy = join(copyRoot, file.path);
      await fileSystem.copyFile(join(plan.storeRoot, file.path), copy, constants.COPYFILE_EXCL);
      await syncPath(copy, fileSystem);
      if (await sha256(copy) !== file.sha256) throw new Error(`Backup of ${file.path} differs from the store`);
    }
    for (const directory of [...plan.directories].reverse()) await syncPath(join(copyRoot, directory), fileSystem);
    await syncPath(copyRoot, fileSystem);
    const manifest = join(backup, "manifest.json");
    await fileSystem.writeFile(manifest, `${JSON.stringify({ version: 1, home: plan.home, homeId: plan.homeId, store: relative(plan.home, plan.storeRoot), files: plan.files })}\n`, { mode: 0o600, flag: "wx" });
    await syncPath(manifest, fileSystem);
    await syncPath(backup, fileSystem);
    await syncPath(dirname(backup), fileSystem);
    const current = await inventory(plan.storeRoot);
    if (JSON.stringify(current) !== JSON.stringify({ directories: plan.directories, files: plan.files })) throw new Error("Memory store changed during migration; nothing was switched");
    assertLeaseOwner();
    const store = new EpisodicStore(workspace, plan.homeId, EPISODIC_DEFAULTS.maxStoreLineBytes, fileSystem);
    await store.saveLayout(EMPTY_LAYOUT);
    const layout = await store.readLayout();
    if (!Array.isArray(layout) || layout.length !== 0) throw new Error("The switched layout does not read back");
    for (const file of plan.files) {
      if (await sha256(join(plan.storeRoot, file.path)) !== file.sha256) throw new Error(`Store file ${file.path} changed during the switch`);
    }
    return { homeId: plan.homeId, backup, files: plan.files.length, bytes: plan.files.reduce((total, file) => total + file.bytes, 0) };
  } finally { await workspace.dispose(); }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const index = args.indexOf("--home");
  if (index < 0 || !args[index + 1]) throw new Error("Missing --home");
  if (args.includes("--apply")) throw new Error("Apply only through scripts/tron home-layout freeze-memory so the offline leases are held");
  const plan = await planLayoutMigration(args[index + 1]!);
  process.stdout.write(`${JSON.stringify({ homeId: plan.homeId, files: plan.files.length, bytes: plan.files.reduce((total, file) => total + file.bytes, 0), applied: false })}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { process.stderr.write(`${(error as Error).message}\n`); process.exitCode = 1; });
}
