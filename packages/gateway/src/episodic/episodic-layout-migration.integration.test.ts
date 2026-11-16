import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readdir, readFile, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, expect, it } from "vitest";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { applyLayoutMigration, planLayoutMigration } from "./episodic-layout-migration.js";
import type { EpisodicSummarizer } from "./episodic-contract.js";
import { awaitsWithin } from "../../test-support/wait-for.js";
import { singleChapterSource } from "../../test-support/episodic-chapter-source.js";

const MIGRATION_MODULE = fileURLToPath(new URL("./episodic-layout-migration.ts", import.meta.url));
const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

const summarizer: EpisodicSummarizer = async request => fauxAssistantMessage(request.turns.at(-1)!.text.replace(/\s+/gu, " ").trim().slice(-200));

interface Base { root: string; home: string; homeId: string; sessionFile: string; storeRoot: string; pristine: string }

async function base(label: string): Promise<Base> {
  const root = await mkdtemp(join(tmpdir(), `tron-layout-migration-${label}-`));
  roots.push(root);
  const home = join(root, "home");
  await mkdir(join(root, "project"), { recursive: true });
  const manager = SessionManager.create(join(root, "project"), join(root, "sessions"));
  for (let index = 0; index < 12; index += 1) {
    manager.appendMessage({ role: "user", content: `migration prompt ${index} ${"p".repeat(700)}`, timestamp: Date.now() } satisfies Message);
    manager.appendMessage(fauxAssistantMessage([{ type: "text", text: `migration reply ${index} ${"q".repeat(700)}` }]));
  }
  const homeId = manager.getSessionId();
  const sessionFile = manager.getSessionFile()!;
  const workspace = new TronWorkspace(home);
  const memory = await EpisodicMemory.open({ workspace, sessionId: homeId, sessionSource: singleChapterSource(homeId, sessionFile), summarizer, limits: { viewBytes: 4_096, jobs: 4, retryMs: 0 } });
  try { await memory.entriesCommitted(homeId); } finally { await memory.dispose(); await workspace.dispose(); }
  const storeRoot = join(home, "workspace", "state", "episodic", homeId);
  const pristine = join(root, "pristine");
  await cp(storeRoot, pristine, { recursive: true, preserveTimestamps: true });
  return { root, home, homeId, sessionFile, storeRoot, pristine };
}

async function digests(directory: string): Promise<Record<string, string>> {
  const result: Record<string, string> = {};
  const walk = async (path: string): Promise<void> => {
    for (const name of await readdir(path)) {
      const child = join(path, name);
      if ((await stat(child)).isDirectory()) await walk(child);
      else result[relative(directory, child)] = createHash("sha256").update(await readFile(child)).digest("hex");
    }
  };
  await walk(directory);
  return result;
}

async function restore(fx: Base): Promise<void> {
  await rm(fx.storeRoot, { recursive: true, force: true });
  await cp(fx.pristine, fx.storeRoot, { recursive: true, preserveTimestamps: true });
  const past = new Date(Date.now() - 120_000);
  await utimes(join(fx.home, "state", "workspace-state.lock"), past, past).catch(() => {});
}

async function migrateInChild(fx: Base, backup: string, killAt: number): Promise<{ output: string; signal: NodeJS.Signals | null; code: number | null }> {
  const program = join(fx.root, "migration-child.mjs");
  const hook = join(fx.root, "hook.mjs");
  await writeFile(hook, `import { registerHooks } from "node:module";\nimport { pathToFileURL } from "node:url";\nregisterHooks({ resolve(specifier, context, nextResolve) { try { return nextResolve(specifier, context); } catch (error) { if (specifier.endsWith(".js")) return nextResolve(specifier.slice(0, -3) + ".ts", context); throw error; } } });\nawait import(pathToFileURL(process.argv[1]).href);\n`, "utf8");
  await writeFile(program, `import { copyFile, lstat, mkdir, open, readdir, rename, rm, writeFile } from "node:fs/promises";
import { syncDurably } from ${JSON.stringify(fileURLToPath(new URL("../foundation/durable-json.ts", import.meta.url)))};
import { applyLayoutMigration, planLayoutMigration } from ${JSON.stringify(MIGRATION_MODULE)};
const [home, homeId, backup, killAt] = process.argv.slice(2);
let operations = 0;
const step = name => async (...args) => {
  operations += 1;
  if (operations === Number(killAt)) { process.stdout.write("killed " + name + "\\n"); process.kill(process.pid, "SIGKILL"); }
  return ({ copyFile, mkdir, open, rename, rm, writeFile, syncDurably })[name](...args);
};
const fileSystem = { lstat, readdir, copyFile: step("copyFile"), mkdir: step("mkdir"), open: step("open"), rename: step("rename"), rm: step("rm"), writeFile: step("writeFile"), syncDurably: step("syncDurably") };
const receipt = await applyLayoutMigration(await planLayoutMigration(home, homeId), backup, process.ppid, fileSystem);
process.stdout.write("operations " + operations + " " + JSON.stringify(receipt) + "\\n");
`, "utf8");
  const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, fx.home, fx.homeId, backup, String(killAt)], { stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  const exit = await awaitsWithin(new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(resolve => child.once("exit", (code, signal) => resolve({ code, signal }))), "migration child to exit");
  return { output, ...exit };
}

async function openFrozen(fx: Base): Promise<number> {
  const workspace = new TronWorkspace(fx.home);
  const memory = await EpisodicMemory.open({ workspace, sessionId: fx.homeId, sessionSource: singleChapterSource(fx.homeId, fx.sessionFile), summarizer, limits: { viewBytes: 4_096, jobs: 4, retryMs: 0 } });
  try {
    await memory.entriesCommitted(fx.homeId);
    expect(memory.status().blocked).toBeNull();
    expect(memory.status().view.unbuilt).toBe(0);
    return memory.status().messages;
  } finally { await memory.dispose(); await workspace.dispose(); }
}

it("kills the migration before every file-system step and leaves v2 live and untouched, or v3 valid", async () => {
  const fx = await base("kill");
  const v2 = await digests(fx.pristine);
  const counted = await migrateInChild(fx, join(fx.root, "backup-count"), 0);
  const total = Number(/operations (\d+)/u.exec(counted.output)?.[1]);
  expect(counted.code, counted.output).toBe(0);
  expect(total).toBeGreaterThan(10);
  for (let killAt = 1; killAt <= total; killAt += 1) {
    await restore(fx);
    const run = await migrateInChild(fx, join(fx.root, `backup-${killAt}`), killAt);
    expect(run.signal, `step ${killAt}: ${run.output}`).toBe("SIGKILL");
    const after = await digests(fx.storeRoot);
    const layout = after["layout.json"];
    for (const name of Object.keys(after)) if (/^layout\.json\.\d+\.[a-f0-9]{12}\.tmp$/u.test(name)) delete after[name];
    delete after["layout.json"];
    expect(after, `step ${killAt} leaves every v2 file byte-identical`).toEqual(v2);
    const past = new Date(Date.now() - 120_000);
    await utimes(join(fx.home, "state", "workspace-state.lock"), past, past);
    if (layout !== undefined) {
      expect(await readFile(join(fx.storeRoot, "layout.json"), "utf8")).toBe(`${JSON.stringify({ lines: [] })}\n`);
    } else {
      await applyLayoutMigration(await planLayoutMigration(fx.home, fx.homeId), join(fx.root, `rerun-${killAt}`), process.ppid);
    }
    expect(await openFrozen(fx)).toBe(24);
    expect(Object.keys(await digests(fx.storeRoot)).filter(name => name.endsWith(".tmp")), "the next open removes a crashed layout temp").toEqual([]);
  }
}, 600_000);

it("backs up every store file, and refuses a re-run, a changed store and a backup inside the home before any switch", async () => {
  const fx = await base("refusals");
  await expect(applyLayoutMigration(await planLayoutMigration(fx.home, fx.homeId), join(fx.home, "backup"), process.ppid)).rejects.toThrow(/outside the Tron home/u);
  await expect(stat(join(fx.home, "backup"))).rejects.toMatchObject({ code: "ENOENT" });

  const plan = await planLayoutMigration(fx.home, fx.homeId);
  const planned = await digests(fx.storeRoot);
  await writeFile(join(fx.storeRoot, "state.json"), `${(await readFile(join(fx.storeRoot, "state.json"), "utf8")).trimEnd()} \n`, { mode: 0o600 });
  const touched = await digests(fx.storeRoot);
  expect(touched).not.toEqual(planned);
  await expect(applyLayoutMigration(plan, join(fx.root, "backup-changed"), process.ppid)).rejects.toThrow(/differs from the store|changed during migration/u);
  expect(await digests(fx.storeRoot), "a refused migration switches nothing").toEqual(touched);

  const backup = join(fx.root, "backup");
  const fresh = await planLayoutMigration(fx.home, fx.homeId);
  const receipt = await applyLayoutMigration(fresh, backup, process.ppid);
  expect(receipt.files).toBe(fresh.files.length);
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as { files: typeof fresh.files };
  expect(manifest.files).toEqual(fresh.files);
  const copied = await digests(join(backup, fx.homeId));
  expect(copied).toEqual(Object.fromEntries(fresh.files.map(file => [file.path, file.sha256])));
  await expect(planLayoutMigration(fx.home, fx.homeId)).rejects.toThrow(/already has a layout/u);
}, 300_000);
