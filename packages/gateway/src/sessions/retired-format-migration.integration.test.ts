import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, readdir, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { ProfileStore } from "../modules/home/profile-store.js";
import { readProfileFile } from "../modules/home/profile-file.js";
import { legacyProfileFixture } from "../../test-support/profile-v1-fixture.js";
import type { SessionEntry } from "../kernel/pi/coding-agent.js";
import { readSessionFixedSettings, readSessionRequestPins, SESSION_SETTINGS_ENTRY } from "./session-settings.js";
import { applyRetiredFormatMigration, planRetiredFormatMigration, restoreRetiredFormatMigration } from "./retired-format-migration.js";

const roots: string[] = [], workspaces: TronWorkspace[] = [];
afterEach(async () => { for (const workspace of workspaces.splice(0)) await workspace.dispose(); for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });

const snapshot = (from: string) => ({ value: "anthropic/fixture", from, at: "2026-10-01T00:00:00.000Z", ref: `ref-${from}` });
const settings = (id: string, fixed: Record<string, unknown>, requestPins?: Record<string, unknown>) => ({ type: "custom", customType: SESSION_SETTINGS_ENTRY, id, parentId: null, timestamp: "2026-10-01T00:00:00.000Z",
  data: { settings: {}, fixed, ...(requestPins ? { requestPins } : {}) } });
const jsonl = (entries: readonly unknown[]) => entries.map(entry => JSON.stringify(entry)).join("\n") + "\n";
const entries = async (path: string) => (await readFile(path, "utf8")).trim().split("\n").map(line => JSON.parse(line) as SessionEntry);

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-retired-formats-")); roots.push(root);
  const home = join(root, "home"), sessions = join(home, "agent", "sessions", "--fixture--");
  const workspace = new TronWorkspace(home); workspaces.push(workspace); await workspace.initialize();
  await mkdir(sessions, { recursive: true });
  const header = { type: "session", version: 3, id: "fixture", timestamp: "2026-10-01T00:00:00.000Z", cwd: "/fixture" };
  const message = { type: "message", id: "m1", parentId: null, timestamp: "2026-10-01T00:00:00.000Z", message: { role: "toolResult", details: { keys: [{ fixedAt: { from: "chat" } }] } } };
  const old = join(sessions, "old.jsonl"), current = join(sessions, "current.jsonl"), recent = join(sessions, "recent.jsonl");
  await writeFile(old, jsonl([header, settings("s1", { "model.default": snapshot("mac") }), message, settings("s2", { "model.default": snapshot("chat"), "tools.active": snapshot("session") }, { thinking: snapshot("builtin") })]));
  await writeFile(current, jsonl([header, settings("s1", { "model.default": snapshot("global") })]));
  await writeFile(recent, jsonl([header, settings("s1", { "model.default": snapshot("profile") })]));
  const past = new Date(Date.now() - 3_600_000);
  for (const path of [old, current]) await utimes(path, past, past);
  const note = (title: string, tags: string[], retired = false) => legacyProfileFixture(workspace, title, { kind: "note", scope: "personal", provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
    content: { title, role: "decision", confirmed: true, ...(retired ? { retired: true } : {}), tags } });
  const scoped = await note("A retired scoped original.", ["home-profile", "kind-standing-decision", "home-file-scopes-tron", "fixture-last"], true);
  const prior = await note("An unplaced Prior original.", ["home-file-home", "home-profile", "kind-fact"]);
  const plain = await note("An unlabelled Prior original.", ["home-profile", "kind-fact"]);
  const sorted = await note("A labelled original sorted before the migration.", ["home-profile", "kind-fact", "home-file-core"]);
  await new ProfileStore(workspace).partitionProfile({ commandId: "fixture-partition-command", mode: "reorganize", assignments: [{ id: sorted.id, expectedRevision: sorted.revisionId, path: "engineering" }] });
  // While the label path existed, sorting a note removed its label and its
  // committed receipt named the label the note left.
  const profilePath = join(home, "workspace", "files", "Profile.json");
  const profile = JSON.parse(await readFile(profilePath, "utf8"), (key, value: unknown) =>
    key === "tags" && Array.isArray(value) ? value.filter(tag => tag !== "home-file-core") : value) as { control: { commands: Record<string, { operation?: string; result?: { value?: { changes?: Array<Record<string, unknown>> } } }> } };
  Object.values(profile.control.commands).find(command => command.operation === "knowledge.profile.partition")!.result!.value!.changes![0]!.beforeFile = "core";
  await writeFile(profilePath, JSON.stringify(profile, null, 2) + "\n", { mode: 0o600 });
  return { root, home, workspace, old, current, recent, scoped, prior, plain, profile: join(home, "workspace", "files", "Profile.json") };
}

it("backs up, rewrites only retired forms, defers recent sessions, is idempotent and restores exactly", async () => {
  const f = await fixture();
  const originals = { old: await readFile(f.old), current: await readFile(f.current), profile: await readFile(f.profile) };
  // The current readers refuse the retired names; after the migration they read
  // exactly what each retired name meant.
  const readBefore = await entries(f.old);
  expect(() => readSessionFixedSettings(readBefore)).toThrow(/provenance is invalid/);
  const fixedBefore = { "model.default": { ...snapshot("chat"), from: "session" }, "tools.active": snapshot("session") };
  const pinsBefore = { thinking: { ...snapshot("builtin"), from: "global" } };

  const plan = await planRetiredFormatMigration(f.home, 600);
  expect({ sessions: plan.sessions, profile: plan.profile }).toEqual({ sessions: { scanned: 3, files: 1, entries: 2, values: 3, deferred: [f.recent] }, profile: { notes: 2, labels: 2, receipts: 1 } });
  const backup = join(f.root, "backup");
  expect(await applyRetiredFormatMigration(f.home, backup, plan)).toEqual({ published: 2, failed: [] });

  // The backup holds byte-exact originals and the digests of both sides.
  const manifest = JSON.parse(await readFile(join(backup, "manifest.json"), "utf8")) as { files: Array<{ path: string; kind: string; changes: number }> };
  expect(manifest.files.map(file => [file.kind, file.path, file.changes])).toEqual([["session", "agent/sessions/--fixture--/old.jsonl", 2], ["profile", "workspace/files/Profile.json", 3]]);
  expect(await readFile(join(backup, "files", "agent/sessions/--fixture--/old.jsonl"))).toEqual(originals.old);
  expect(await readFile(join(backup, "files", "workspace/files/Profile.json"))).toEqual(originals.profile);

  // Only settings provenance changes; every other line keeps its exact bytes,
  // and the current reader yields what it read before.
  const before = originals.old.toString("utf8").split("\n"), after = (await readFile(f.old, "utf8")).split("\n");
  expect(after.map((line, index) => line === before[index])).toEqual([true, false, true, false, true]);
  expect(after.join("\n")).not.toMatch(/"from":"(mac|builtin|chat|profile)","at"/);
  expect(after[2]).toContain('"fixedAt":{"from":"chat"}');
  const readAfter = await entries(f.old);
  expect(readSessionFixedSettings(readAfter)).toEqual(fixedBefore);
  expect(readSessionRequestPins(readAfter)).toEqual(pinsBefore);
  expect(await readFile(f.current)).toEqual(originals.current);

  // Profile: labels removed in place; identity, revision, order of other tags and validity stay.
  const store = new ProfileStore(f.workspace);
  expect(await store.read(f.scoped.id)).toEqual({ ...f.scoped, content: { ...f.scoped.content, tags: ["home-profile", "kind-standing-decision", "fixture-last"] } });
  expect(await store.read(f.prior.id)).toEqual({ ...f.prior, content: { ...f.prior.content, tags: ["home-profile", "kind-fact"] } });
  expect(await store.read(f.plain.id)).toEqual(f.plain);
  const migrated = (await readProfileFile(f.workspace))!;
  expect(migrated.stateRevision).toBe(JSON.parse(originals.profile.toString("utf8")).stateRevision + 1);
  const receipt = Object.values(migrated.control.commands).find(command => command.operation === "knowledge.profile.partition")!;
  expect(receipt.result).toEqual({ kind: "value", value: { changes: [{ id: expect.any(String), beforeRevision: expect.any(String), revisionId: expect.any(String) }] } });

  // Second run: only the deferred session remains; after it, nothing is planned.
  const second = await planRetiredFormatMigration(f.home, 0);
  expect({ files: second.files.map(file => file.path), sessions: second.sessions.files, profile: second.profile }).toEqual({ files: [f.recent], sessions: 1, profile: { notes: 0, labels: 0, receipts: 0 } });
  expect(await applyRetiredFormatMigration(f.home, join(f.root, "backup-2"), second)).toEqual({ published: 1, failed: [] });
  const third = await planRetiredFormatMigration(f.home, 0);
  expect(third.files).toEqual([]);
  expect(await applyRetiredFormatMigration(f.home, join(f.root, "backup-3"), third)).toEqual({ published: 0, failed: [] });
  await expect(readdir(join(f.root, "backup-3"))).rejects.toMatchObject({ code: "ENOENT" });

  // Rollback restores this run's originals byte-for-byte.
  expect(await restoreRetiredFormatMigration(f.home, backup)).toEqual({ restored: 2, skipped: [] });
  expect(await readFile(f.old)).toEqual(originals.old);
  expect(await readFile(f.profile)).toEqual(originals.profile);
});

/** A Home whose first chapter is sealed and holds retired names in two settings
 * entries around a message; the active chapter holds the same. */
async function homeChapters(f: Awaited<ReturnType<typeof fixture>>) {
  const sessions = join(f.home, "agent", "sessions", "--home--");
  await mkdir(sessions, { recursive: true });
  const chapter = (id: string) => jsonl([{ type: "session", version: 3, id, timestamp: "2026-10-01T00:00:00.000Z", cwd: "/home" },
    settings("s1", { "model.default": snapshot("mac") }, { "context.images.block": snapshot("builtin") }),
    { type: "message", id: "m1", parentId: "s1", timestamp: "2026-10-01T00:00:00.000Z", message: { role: "user", content: "a sealed fact", timestamp: 0 } },
    settings("s2", {}, { thinking: snapshot("profile") })]);
  const sealed = join(sessions, "sealed.jsonl"), active = join(sessions, "active.jsonl");
  await writeFile(sealed, chapter("chapter-1"));
  await writeFile(active, chapter("chapter-2"));
  const past = new Date(Date.now() - 3_600_000);
  for (const path of [sealed, active]) await utimes(path, past, past);
  await mkdir(join(f.home, "gateway", "home"), { recursive: true });
  await writeFile(join(f.home, "gateway", "home", "home.json"), JSON.stringify({ version: 2, chapters: [{ sessionId: "chapter-1", state: "sealed" }, { sessionId: "chapter-2", state: "active" }] }));
  return { sessions, sealed, active, ledger: join(f.home, "gateway", "home", "chapter-reseals.jsonl") };
}
const sha256 = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const reseals = async (path: string) => (await readFile(path, "utf8").catch(() => "")).split("\n").filter(Boolean).map(line => JSON.parse(line) as Record<string, unknown>);
/** The original with each retired name in a settings provenance replaced, every other byte kept. */
const migratedText = (original: Buffer) => original.toString("utf8").replace('"from":"mac"', '"from":"global"')
  .replace('"from":"builtin"', '"from":"global"').replace('"from":"profile"', '"from":"session"');

it("re-seals a sealed Home chapter: only retired names change, the ledger records both digests, a rerun plans nothing and a restore is bit-identical", async () => {
  const f = await fixture();
  const h = await homeChapters(f);
  const original = await readFile(h.sealed);

  const plan = await planRetiredFormatMigration(f.home, 600);
  expect(plan.files.map(file => file.path).sort()).toEqual([f.old, h.sealed, h.active, f.profile].sort());
  const backup = join(f.root, "backup");
  expect(await applyRetiredFormatMigration(f.home, backup, plan)).toEqual({ published: 4, failed: [] });
  const migrated = await readFile(h.sealed);
  expect(migrated.toString("utf8")).toBe(migratedText(original));
  expect(await readFile(join(backup, "files", "agent/sessions/--home--/sealed.jsonl"))).toEqual(original);
  const values = [
    { line: 1, field: "fixed", key: "model.default", from: "mac", to: "global" },
    { line: 1, field: "requestPins", key: "context.images.block", from: "builtin", to: "global" },
    { line: 3, field: "requestPins", key: "thinking", from: "profile", to: "session" },
  ];
  // Only the sealed chapter is recorded; the active one is rewritten as any session.
  expect(await reseals(h.ledger)).toEqual([{ version: 1, sessionId: "chapter-1", path: "agent/sessions/--home--/sealed.jsonl", at: expect.any(String),
    before: { sha256: sha256(original), size: original.length }, after: { sha256: sha256(migrated), size: migrated.length }, values }]);
  expect((await planRetiredFormatMigration(f.home, 600)).files).toEqual([]);

  expect(await restoreRetiredFormatMigration(f.home, backup)).toEqual({ restored: 4, skipped: [] });
  expect(await readFile(h.sealed)).toEqual(original);
  expect((await reseals(h.ledger)).slice(1)).toEqual([{ version: 1, sessionId: "chapter-1", path: "agent/sessions/--home--/sealed.jsonl", at: expect.any(String),
    before: { sha256: sha256(migrated), size: migrated.length }, after: { sha256: sha256(original), size: original.length },
    values: values.map(value => ({ ...value, from: value.to, to: value.from })) }]);
  expect(await restoreRetiredFormatMigration(f.home, backup)).toEqual({ restored: 0, skipped: [] });
  expect(await readdir(h.sessions)).toEqual(["active.jsonl", "sealed.jsonl"]);

  await writeFile(join(f.home, "gateway", "home", "home.json"), JSON.stringify({ version: 1, chapters: [] }));
  await expect(planRetiredFormatMigration(f.home, 600)).rejects.toThrow(/Unsupported Home ledger/);
});

it("leaves every retained settings entry, sealed Home chapters included, readable by the current readers", async () => {
  const f = await fixture();
  const h = await homeChapters(f);
  const settingsEntries = async () => {
    const found: Array<{ path: string; entry: SessionEntry }> = [];
    for (const path of [f.old, f.current, f.recent, h.sealed, h.active]) {
      for (const entry of await entries(path)) if (entry.type === "custom" && entry.customType === SESSION_SETTINGS_ENTRY) found.push({ path, entry });
    }
    return found;
  };
  const unreadable = async () => (await settingsEntries()).filter(({ entry }) => {
    try { readSessionFixedSettings([entry]); readSessionRequestPins([entry]); return false; } catch { return true; }
  }).map(({ path, entry }) => `${path}#${entry.id}`);
  const retained = (await settingsEntries()).length;
  expect(await unreadable()).toEqual([`${f.old}#s1`, `${f.old}#s2`, `${f.recent}#s1`, `${h.sealed}#s1`, `${h.sealed}#s2`, `${h.active}#s1`, `${h.active}#s2`]);
  expect(await applyRetiredFormatMigration(f.home, join(f.root, "backup"), await planRetiredFormatMigration(f.home, 0))).toMatchObject({ failed: [] });
  expect(await unreadable()).toEqual([]);
  expect(await settingsEntries()).toHaveLength(retained);
});

it("cuts the torn re-seal record an interrupted append left", async () => {
  const f = await fixture();
  const h = await homeChapters(f);
  // Longer than any record, so only cutting it leaves a ledger of complete lines.
  const torn = '{"version":1,"sessionId":"chapter-1","path":"agent/sessions/--home--/sealed.jsonl","at":"2026-' + "x".repeat(4_096);
  await writeFile(h.ledger, torn, { mode: 0o600 });
  expect(await applyRetiredFormatMigration(f.home, join(f.root, "backup"), await planRetiredFormatMigration(f.home, 600))).toMatchObject({ failed: [] });
  const text = await readFile(h.ledger, "utf8");
  expect(text.endsWith("\n")).toBe(true);
  expect(await reseals(h.ledger)).toEqual([expect.objectContaining({ sessionId: "chapter-1", after: { sha256: sha256(await readFile(h.sealed)), size: (await readFile(h.sealed)).length } })]);
});

it.each(["before its re-seal record is appended", "after its re-seal record is appended"] as const)(
  "leaves a sealed chapter whole when killed %s; a rerun completes it once and a restore undoes it bit-identically", async point => {
  const f = await fixture();
  const h = await homeChapters(f);
  const original = await readFile(h.sealed);
  const patch = point === "before its re-seal record is appended"
    ? "const open = fs.open; fs.open = async function (path, ...rest) { if (String(path).endsWith('chapter-reseals.jsonl')) process.kill(process.pid, 'SIGKILL'); return open.call(this, path, ...rest); };"
    : "fs.rename = async function (from, to) { if (to === sealed && String(from).includes('.migration-')) process.kill(process.pid, 'SIGKILL'); return rename.call(this, from, to); };";
  await killedApply(f, h.sealed, patch);
  // The kill came after the replacement was staged and fsynced, never mid-rename.
  expect(await readFile(h.sealed)).toEqual(original);
  expect(await reseals(h.ledger)).toHaveLength(point === "before its re-seal record is appended" ? 0 : 1);

  const rerun = join(f.root, "rerun-backup");
  expect(await applyRetiredFormatMigration(f.home, rerun, await planRetiredFormatMigration(f.home, 600))).toMatchObject({ failed: [] });
  const migrated = await readFile(h.sealed);
  expect(migrated.toString("utf8")).toBe(migratedText(original));
  expect((await reseals(h.ledger)).map(record => [record.before, record.after])).toEqual([[{ sha256: sha256(original), size: original.length }, { sha256: sha256(migrated), size: migrated.length }]]);
  expect(await readdir(h.sessions)).toEqual(["active.jsonl", "sealed.jsonl"]);
  expect((await planRetiredFormatMigration(f.home, 600)).files).toEqual([]);
  expect(await restoreRetiredFormatMigration(f.home, rerun)).toMatchObject({ skipped: [] });
  expect(await readFile(h.sealed)).toEqual(original);
});

it("refuses a run whose input changed after planning, and never restores over a later write", async () => {
  const f = await fixture();
  const stale = await planRetiredFormatMigration(f.home, 600);
  const later = (await readFile(f.old, "utf8")) + JSON.stringify(settings("s3", { "model.default": snapshot("session") })) + "\n";
  await writeFile(f.old, later);
  const profile = await readFile(f.profile);
  await expect(applyRetiredFormatMigration(f.home, join(f.root, "stale-backup"), stale)).rejects.toThrow(/old\.jsonl changed while it was backed up/);
  expect(await readFile(f.old, "utf8")).toBe(later);
  expect(await readFile(f.profile)).toEqual(profile);
  const backup = join(f.root, "backup");
  expect(await applyRetiredFormatMigration(f.home, backup, await planRetiredFormatMigration(f.home, 0))).toEqual({ published: 3, failed: [] });
  const edited = (await readFile(f.profile, "utf8")).replace("An unlabelled Prior original.", "An edited Prior original.");
  await writeFile(f.profile, edited, { mode: 0o600 });
  expect(await restoreRetiredFormatMigration(f.home, backup)).toEqual({ restored: 2, skipped: [expect.stringMatching(/^workspace\/files\/Profile\.json: changed after the migration/)] });
  expect(await readFile(f.old, "utf8")).toBe(later);
  expect(await readFile(f.profile, "utf8")).toBe(edited);
});

/** Applies the real migration in a child process whose `node:fs/promises` calls are
 * wrapped by `patch` to inject the Gateway's own write at an exact publication step. */
async function racingApply(f: Awaited<ReturnType<typeof fixture>>, patch: string, line: string): Promise<{ published: number; failed: string[] }> {
  const hook = join(f.root, "loader.mjs"), program = join(f.root, "racing-apply.mjs");
  await writeFile(hook, `import { registerHooks } from 'node:module';
registerHooks({ resolve(specifier, context, next) { try { return next(specifier, context); } catch (error) { if (specifier.endsWith('.js')) return next(specifier.slice(0,-3)+'.ts',context); throw error; } } });\n`);
  await writeFile(program, `import fs from 'node:fs/promises';
import { appendFileSync, writeFileSync, renameSync } from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
const [home, backup, session, profile, line] = process.argv.slice(2);
const rename = fs.rename, link = fs.link;
${patch}
syncBuiltinESMExports();
const { planRetiredFormatMigration, applyRetiredFormatMigration } = await import(${JSON.stringify(fileURLToPath(new URL("./retired-format-migration.ts", import.meta.url)))});
process.stdout.write(JSON.stringify(await applyRetiredFormatMigration(home, backup, await planRetiredFormatMigration(home, 600))));
`);
  const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, f.home, join(f.root, "backup"), f.old, f.profile, line], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", chunk => { stdout += String(chunk); }); child.stderr.on("data", chunk => { stderr += String(chunk); });
  expect(await once(child, "exit"), stderr).toEqual([0, null]);
  return JSON.parse(stdout);
}
const appended = JSON.stringify(settings("s3", { "model.default": snapshot("session") })) + "\n";
/** Applies the real migration in a child process that `patch` kills with SIGKILL at one exact step. */
async function killedApply(f: Awaited<ReturnType<typeof fixture>>, sealed: string, patch: string): Promise<void> {
  const hook = join(f.root, "loader.mjs"), program = join(f.root, "killed-apply.mjs");
  await writeFile(hook, `import { registerHooks } from 'node:module';
registerHooks({ resolve(specifier, context, next) { try { return next(specifier, context); } catch (error) { if (specifier.endsWith('.js')) return next(specifier.slice(0,-3)+'.ts',context); throw error; } } });\n`);
  await writeFile(program, `import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
const [home, backup, sealed] = process.argv.slice(2);
const rename = fs.rename;
${patch}
syncBuiltinESMExports();
const { planRetiredFormatMigration, applyRetiredFormatMigration } = await import(${JSON.stringify(fileURLToPath(new URL("./retired-format-migration.ts", import.meta.url)))});
await applyRetiredFormatMigration(home, backup, await planRetiredFormatMigration(home, 600));
`);
  const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, f.home, join(f.root, "backup"), sealed], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", chunk => { stderr += String(chunk); });
  expect(await once(child, "exit"), stderr).toEqual([null, "SIGKILL"]);
}


it("puts a session back complete and unmigrated when an append reaches it during publication", async () => {
  const f = await fixture();
  const original = await readFile(f.old, "utf8");
  // Pi appends by path: here after the tool's last check and before its rename lands.
  const result = await racingApply(f, "fs.rename = async function (from, to) { if (to === session && String(from).includes('.migration-')) appendFileSync(session, line); return rename.call(this, from, to); };", appended);
  expect(result).toEqual({ published: 1, failed: [expect.stringMatching(/^agent\/sessions\/--fixture--\/old\.jsonl: was written during publication; its complete original was put back unmigrated; rerun$/)] });
  expect(await readFile(f.old, "utf8")).toBe(original + appended);
  await utimes(f.old, new Date(Date.now() - 3_600_000), new Date(Date.now() - 3_600_000));
  expect((await planRetiredFormatMigration(f.home, 600)).files.map(file => file.path)).toEqual([f.old]);
});

it("keeps an append that lands just after a session's migrated replacement", async () => {
  const f = await fixture();
  const result = await racingApply(f, "fs.rename = async function (from, to) { const done = await rename.call(this, from, to); if (to === session && String(from).includes('.migration-')) appendFileSync(session, line); return done; };", appended);
  expect(result).toEqual({ published: 2, failed: [] });
  const text = await readFile(f.old, "utf8");
  expect(text.endsWith(appended)).toBe(true);
  expect(text).not.toMatch(/"from":"(mac|builtin|chat|profile)","at"/);
});

it("keeps a Profile owner publication that races the migration's replacement", async () => {
  for (const [step, patch, message] of [
    ["before the original moves aside", "fs.rename = async function (from, to) { if (from === profile && String(to).includes('.migration-held-')) { writeFileSync(profile + '.owner', line, { mode: 0o600 }); renameSync(profile + '.owner', profile); } return rename.call(this, from, to); };", /: was replaced during publication; that write was kept; rerun$/],
    ["while the original is aside", "fs.link = async function (from, to) { if (to === profile) writeFileSync(profile, line, { mode: 0o600 }); return link.call(this, from, to); };", /: was written during publication; that write was kept, the original is at .*raced-1; rerun$/],
  ] as const) {
    const f = await fixture();
    const owner = (await readFile(f.profile, "utf8")).replace("An unlabelled Prior original.", `An owner write ${step}.`);
    const result = await racingApply(f, patch, owner);
    expect(result.published, step).toBe(1);
    expect(result.failed, step).toEqual([expect.stringMatching(new RegExp("^workspace/files/Profile\\.json" + message.source))]);
    expect(await readFile(f.profile, "utf8"), step).toBe(owner);
    expect((await readdir(join(f.profile, ".."))).filter(name => name !== "Profile.json"), step).toEqual([]);
  }
});

it("refuses a configured session directory and an unsettled Profile organization", async () => {
  const f = await fixture();
  await writeFile(join(f.home, "agent", "settings.json"), JSON.stringify({ sessionDir: "/elsewhere" }));
  await expect(planRetiredFormatMigration(f.home, 600)).rejects.toThrow(/sets sessionDir/);
  await rm(join(f.home, "agent", "settings.json"));
  const profile = JSON.parse(await readFile(f.profile, "utf8")) as { control: { commands: Record<string, { auditPending?: true }> } };
  Object.values(profile.control.commands).find(command => (command as { operation?: string }).operation === "knowledge.profile.partition")!.auditPending = true;
  await writeFile(f.profile, JSON.stringify(profile, null, 2) + "\n", { mode: 0o600 });
  await expect(planRetiredFormatMigration(f.home, 600)).rejects.toThrow(/uncommitted or unacknowledged/);
});
