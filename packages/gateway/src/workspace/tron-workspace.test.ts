import { afterEach, describe, expect, it, vi } from "vitest";
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, rename, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TronWorkspace } from "./tron-workspace.js";
import * as durableJson from "../util/durable-json.js";

const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-workspace-"));
  roots.push(root);
  return root;
}
function owner(home: string) { const value = new TronWorkspace(home); owners.push(value); return value; }

describe("Tron internal workspace", () => {
  it("initializes once, retains content, and does not create speculative namespaces", async () => {
    const home = join(await fixture(), "home");
    const first = owner(home);
    const descriptions = await Promise.all([first.describe(), first.describe()]);
    expect(descriptions[0]).toEqual(descriptions[1]);
    const path = descriptions[0]!.root;
    expect(descriptions[0]!.available).toBe(true);
    expect((await lstat(path)).mode & 0o777).toBe(0o700);
    expect(await readdir(path)).toEqual([]);
    await writeFile(join(path, "kept.txt"), "user data");
    await first.dispose();
    expect((await owner(home).describe()).available).toBe(true);
    expect(await readFile(join(path, "kept.txt"), "utf8")).toBe("user data");
    expect(JSON.parse(await readFile(join(home, "gateway/workspace-state/initialized.json"), "utf8"))).toEqual({ version: 1 });
  });

  it("never recreates a missing established workspace, even after restart", async () => {
    const home = join(await fixture(), "home");
    const first = owner(home);
    const { root } = await first.describe();
    await rm(root, { recursive: true });
    expect((await first.describe()).available).toBe(false);
    await first.dispose();
    expect((await owner(home).describe()).available).toBe(false);
    await expect(lstat(root)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rejects same-path directory replacement during a live ownership period", async () => {
    const home = join(await fixture(), "home");
    const value = owner(home);
    const { root } = await value.describe();
    await rename(root, `${root}-original`);
    await mkdir(root, { mode: 0o700 });
    expect((await value.describe()).available).toBe(false);
  });

  it.each(["file", "symlink", "permissions", "readOnly"])("preserves an unsafe %s root and does not repair it", async kind => {
    const home = await fixture();
    const path = join(home, "workspace");
    if (kind === "file") await writeFile(path, "keep");
    if (kind === "symlink") await symlink(home, path);
    if (kind === "permissions") await mkdir(path, { mode: 0o777 });
    if (kind === "permissions") await chmod(path, 0o777);
    if (kind === "readOnly") { await mkdir(path); await chmod(path, 0o500); }
    const before = await lstat(path);
    expect((await owner(home).describe()).available).toBe(false);
    expect((await lstat(path)).ino).toBe(before.ino);
    expect((await lstat(path)).mode).toBe(before.mode);
  });

  it.each(['{}', '{"version":2}', '{"version":1,"extra":true}', 'broken', 'x'.repeat(129)])("preserves invalid lifecycle evidence", async contents => {
    const home = await fixture();
    const state = join(home, "gateway/workspace-state");
    await mkdir(state, { recursive: true, mode: 0o700 });
    const path = join(state, "initialized.json");
    await writeFile(path, contents, { mode: 0o600 });
    expect((await owner(home).describe()).available).toBe(false);
    expect(await readFile(path, "utf8")).toBe(contents);
    await expect(lstat(join(home, "workspace"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it.each(["ENOSPC", "EACCES"])("preserves data and releases ownership after %s publication failure", async code => {
    const home = await fixture();
    const root = join(home, "workspace");
    await mkdir(root, { mode: 0o700 });
    await writeFile(join(root, "kept.txt"), "existing data");
    const publication = vi.spyOn(durableJson, "durableAtomicWriteJson")
      .mockRejectedValueOnce(Object.assign(new Error("publication failed"), { code }));
    expect((await owner(home).describe()).available).toBe(false);
    expect(await readFile(join(root, "kept.txt"), "utf8")).toBe("existing data");
    await expect(lstat(join(home, "gateway/workspace-state/initialized.json"))).rejects.toMatchObject({ code: "ENOENT" });
    publication.mockRestore();
    expect((await owner(home).describe()).available).toBe(true);
  });

  it("isolates homes and rejects a second managed owner of the same resolved home", async () => {
    const base = await fixture();
    const stable = owner(join(base, "stable"));
    const debug = owner(join(base, "debug"));
    const [a, b] = await Promise.all([stable.describe(), debug.describe()]);
    expect(a.available && b.available).toBe(true);
    expect(a.root).not.toBe(b.root);
    expect(await owner(join(base, "stable")).describe()).toMatchObject({ available: false, reason: "owned_elsewhere" });
    await stable.dispose();
    expect((await owner(join(base, "stable")).describe()).available).toBe(true);
  });

  it("refuses a separate process owner and recovers its abandoned stale lock without losing data", async () => {
    const home = await fixture();
    const first = owner(home);
    const { root } = await first.describe();
    await writeFile(join(root, "kept.txt"), "durable");
    await first.dispose();
    const state = join(home, "gateway/workspace-state");
    const lockModule = createRequire(import.meta.url).resolve("proper-lockfile");
    const child = spawn(process.execPath, ["-e", `require(${JSON.stringify(lockModule)}).lock(${JSON.stringify(state)}, {stale:60000, update:10000}).then(() => { process.stdout.write('ready'); setInterval(() => {}, 1000); });`], { stdio: ["ignore", "pipe", "pipe"] });
    const exited = once(child, "exit");
    try {
      await once(child.stdout!, "data");
      expect(await owner(home).describe()).toMatchObject({ available: false, reason: "owned_elsewhere" });
    } finally { child.kill("SIGKILL"); await exited; }
    // Advance only the abandoned fixture's lock age, avoiding a minute-long test.
    const stale = new Date(Date.now() - 120_000);
    await utimes(`${state}.lock`, stale, stale);
    expect((await owner(home).describe()).available).toBe(true);
    expect(await readFile(join(root, "kept.txt"), "utf8")).toBe("durable");
  });

  it("resolves files without creating them or exposing state; refuses links", async () => {
    const home = await fixture();
    const value = owner(home);
    const { root } = await value.describe();
    await expect(value.filesRoot()).rejects.toMatchObject({ code: "conflict" });
    expect(await readdir(root)).toEqual([]);
    await mkdir(join(root, "files"));
    expect(await value.filesRoot()).toBe(join(root, "files"));
    await rm(join(root, "files"), { recursive: true });
    await symlink(home, join(root, "files"));
    await expect(value.filesRoot()).rejects.toMatchObject({ code: "conflict" });
  });

  it("disposal closes initialization and releases its lock idempotently", async () => {
    const home = join(await fixture(), "home");
    const value = owner(home);
    await Promise.all([value.initialize(), value.dispose(), value.dispose()]);
    expect(await value.describe()).toMatchObject({ available: false, reason: "closed" });
    expect((await owner(home).describe()).available).toBe(true);
  });
});
