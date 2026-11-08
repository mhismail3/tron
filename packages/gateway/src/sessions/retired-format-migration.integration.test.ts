import { mkdir, mkdtemp, readFile, readdir, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
  const receipt = await new ProfileStore(workspace).partitionProfile({ commandId: "fixture-partition-command", mode: "reorganize", assignments: [{ id: sorted.id, expectedRevision: sorted.revisionId, path: "engineering" }] });
  expect(receipt.changes).toEqual([expect.objectContaining({ beforeFile: "core" })]);
  return { root, home, workspace, old, current, recent, scoped, prior, plain, profile: join(home, "workspace", "files", "Profile.json") };
}

it("backs up, rewrites only retired forms, defers recent sessions, is idempotent and restores exactly", async () => {
  const f = await fixture();
  const originals = { old: await readFile(f.old), current: await readFile(f.current), profile: await readFile(f.profile) };
  const readBefore = await entries(f.old);
  const fixedBefore = readSessionFixedSettings(readBefore), pinsBefore = readSessionRequestPins(readBefore);

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
  expect(await restoreRetiredFormatMigration(backup)).toEqual({ restored: 2, skipped: [] });
  expect(await readFile(f.old)).toEqual(originals.old);
  expect(await readFile(f.profile)).toEqual(originals.profile);
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
  expect(await restoreRetiredFormatMigration(backup)).toEqual({ restored: 2, skipped: [expect.stringMatching(/^workspace\/files\/Profile\.json: changed after the migration/)] });
  expect(await readFile(f.old, "utf8")).toBe(later);
  expect(await readFile(f.profile, "utf8")).toBe(edited);
});
