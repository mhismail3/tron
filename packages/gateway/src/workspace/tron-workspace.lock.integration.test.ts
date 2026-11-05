import { chmod, mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished } from "vitest";
import { TronWorkspace, type TronWorkspaceFeature, type TronWorkspaceUnavailableCause } from "./tron-workspace.js";

/**
 * `gateway/workspace` workspace-state markers: the shared initialization record and
 * each feature's marker, what initialization and marking commit, which hand-written
 * markers are admitted, and when the workspace refuses to be available.
 */
it("workspace-state-paths: initialize, mark features, admission and availability", async () => {
  const home = join(await realpath(await mkdtemp(join(tmpdir(), "tron-workspace-state-"))), "home");
  onTestFinished(() => rm(join(home, ".."), { recursive: true, force: true }));
  const state = join(home, "gateway", "workspace-state");
  const root = join(home, "workspace");
  const features: TronWorkspaceFeature[] = ["profile", "episodic", "home-tasks", "apps"];
  const opened: TronWorkspace[] = [];
  onTestFinished(async () => { for (const workspace of opened) await workspace.dispose().catch(() => {}); });
  const open = () => {
    const causes: TronWorkspaceUnavailableCause[] = [];
    const workspace = new TronWorkspace(home, { unavailable: (cause) => causes.push(cause) });
    opened.push(workspace);
    return { workspace, causes };
  };
  const initialized = async (workspace: TronWorkspace) => Object.fromEntries(await Promise.all(features.map(async (feature) =>
    [feature, await workspace.featureInitialized(feature).catch((error: Error) => `refused: ${error.message}`)])));
  const availability = async ({ workspace, causes }: ReturnType<typeof open>) => ({ describe: await workspace.describe(), causes });
  /** Every file in the workspace-state directory, parsed. */
  const markers = async (): Promise<Record<string, unknown>> => {
    const names = await readdir(state).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return []; throw error; });
    return Object.fromEntries(await Promise.all(names.sort().map(async (name) => [name, JSON.parse(await readFile(join(state, name), "utf8"))])));
  };
  const v1 = { version: 1 };
  const available = { root, available: true };
  const unavailable = (reason: string) => ({ root, available: false, reason });

  expect(await TronWorkspace.describeExisting(home), "describe an absent workspace").toEqual(unavailable("unavailable"));
  expect(await markers()).toEqual({});
  const first = open();
  expect(await availability(first), "initialize a fresh home").toEqual({ describe: available, causes: [] });
  expect(await markers(), "initialization writes only the shared record").toEqual({ "initialized.json": v1 });
  expect(await TronWorkspace.describeExisting(home), "describe the existing workspace").toEqual(available);
  expect(await initialized(first.workspace), "no feature is initialized").toEqual({ profile: false, episodic: false, "home-tasks": false, apps: false });

  await expect(first.workspace.markFeatureInitialized("home-tasks")).resolves.toBeUndefined();
  expect(await markers()).toEqual({ "home-tasks-initialized.json": v1, "initialized.json": v1 });
  await expect(first.workspace.markFeatureInitialized("home-tasks"), "mark home-tasks again").resolves.toBeUndefined();
  expect(await markers(), "is unchanged").toEqual({ "home-tasks-initialized.json": v1, "initialized.json": v1 });
  await expect(first.workspace.markFeatureInitialized("profile")).resolves.toBeUndefined();
  expect(await markers(), "Profile writes its separate feature record")
    .toEqual({ "home-tasks-initialized.json": v1, "initialized.json": v1, "profile-initialized.json": v1 });
  expect(await Promise.all([first.workspace.markFeatureInitialized("apps"), first.workspace.markFeatureInitialized("apps")]), "mark apps twice at once")
    .toEqual([undefined, undefined]);
  const marked = { "apps-initialized.json": v1, "home-tasks-initialized.json": v1, "initialized.json": v1, "profile-initialized.json": v1 };
  expect(await markers()).toEqual(marked);
  expect(await initialized(first.workspace), "marked features are initialized").toEqual({ profile: true, episodic: false, "home-tasks": true, apps: true });
  expect(await availability(open()), "a second owner of the same home is unavailable")
    .toEqual({ describe: unavailable("owned_elsewhere"), causes: ["owned-elsewhere"] });

  const files = join(root, "files");
  const filesRoot = () => first.workspace.filesRoot().then((path) => ({ path }),
    (error: { message: string; code?: unknown; retryable?: unknown; details?: unknown }) =>
      ({ refused: error.message, code: error.code, retryable: error.retryable, details: error.details ?? null }));
  const unsafeFiles = { refused: "Tron internal files must be an existing directory writable only by its owner", code: "conflict", retryable: false, details: null };
  expect(await filesRoot(), "files root before it exists is refused").toEqual(unsafeFiles);
  await mkdir(files, { mode: 0o700 });
  try {
    expect(await filesRoot(), "an owner-only files root").toEqual({ path: files });
    await chmod(files, 0o500);
    expect(await filesRoot(), "a files root its owner cannot write is refused").toEqual(unsafeFiles);
    await chmod(files, 0o755);
    expect(await filesRoot(), "a files root others can enter but not write").toEqual({ path: files });
    await chmod(files, 0o775);
    expect(await filesRoot(), "a files root its group can write is refused").toEqual(unsafeFiles);
  } finally { await chmod(files, 0o700); }
  expect(await markers(), "files-root checks write no marker").toEqual(marked);

  const marker = (name: string, value: unknown) => writeFile(join(state, name), JSON.stringify(value), { mode: 0o600 });
  const invalidEpisodic = "refused: episodic: invalid initialization record";
  const episodic: Array<[unknown, unknown]> = [[{ version: 1 }, true], [{ version: 1, extra: 1 }, invalidEpisodic], [{ version: 2 }, invalidEpisodic],
    [[{ version: 1 }], invalidEpisodic], [null, invalidEpisodic], [{}, invalidEpisodic]];
  for (const [value, expected] of episodic) {
    await marker("episodic-initialized.json", value);
    expect(await first.workspace.featureInitialized("episodic").catch((error: Error) => `refused: ${error.message}`), `hand-written feature marker ${JSON.stringify(value)}`).toBe(expected);
  }
  await expect(first.workspace.markFeatureInitialized("episodic"), "marking over an invalid feature marker").rejects.toThrow("episodic: invalid initialization record");
  const withEpisodic = { ...marked, "episodic-initialized.json": {} };
  expect(await markers(), "the invalid marker is not overwritten").toEqual(withEpisodic);
  await first.workspace.dispose();
  expect(await first.workspace.describe(), "dispose closes the workspace").toEqual(unavailable("closed"));
  await expect(first.workspace.dispose(), "dispose again").resolves.toBeUndefined();

  // A fresh owner admits only the exact shared record; anything else is unavailable
  // and its features refuse instead of reading as uninitialized.
  for (const value of [{ version: 1, knowledgeInitialized: false }, { version: 1, knowledgeInitialized: true }, { version: 1, extra: true },
    { version: 2 }, { version: 1, knowledgeInitialized: "yes" }, [{ version: 1 }], { version: 1 }]) {
    await marker("initialized.json", value);
    const next = open();
    try {
      const valid = JSON.stringify(value) === JSON.stringify(v1);
      expect({ ...await availability(next), profileInitialized: await next.workspace.featureInitialized("profile").catch((error: Error) => `refused: ${error.message}`) },
        `hand-written shared record ${JSON.stringify(value)}`).toEqual(valid
        ? { describe: available, causes: [], profileInitialized: true }
        : { describe: unavailable("unavailable"), causes: ["invalid-record"], profileInitialized: "refused: profile: Tron workspace is unavailable" });
    } finally { await next.workspace.dispose(); }
    expect((await markers())["initialized.json"], "a fresh owner never rewrites the shared record").toEqual(value);
  }
  await marker("initialized.json", [{ version: 1 }]);
  expect(await availability(open()), "an invalid shared record makes the workspace unavailable").toEqual({ describe: unavailable("unavailable"), causes: ["invalid-record"] });
  await marker("initialized.json", v1);
  const next = open();
  expect(await availability(next), "a valid shared record admits a new owner").toEqual({ describe: available, causes: [] });
  await next.workspace.dispose();
  await chmod(state, 0o755);
  try {
    expect(await availability(open()), "a workspace-state directory others can read is unsafe").toEqual({ describe: unavailable("unavailable"), causes: ["unsafe-directory"] });
  } finally { await chmod(state, 0o700); }
  await rm(root, { recursive: true });
  expect(await TronWorkspace.describeExisting(home), "describe after the root was removed").toEqual(unavailable("unavailable"));
  expect(await availability(open()), "a removed root is lost data, not a fresh install").toEqual({ describe: unavailable("unavailable"), causes: ["missing-root"] });
  await writeFile(root, "", { mode: 0o700 });
  expect(await availability(open()), "a regular file in place of the root is unsafe").toEqual({ describe: unavailable("unavailable"), causes: ["unsafe-directory"] });
  expect(await markers(), "no unavailable owner rewrote a marker").toEqual(withEpisodic);
});
