import { chmod, mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it } from "vitest";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { TronWorkspace, type TronWorkspaceFeature, type TronWorkspaceUnavailableCause } from "./tron-workspace.js";

/**
 * `gateway/workspace` mutation-path lock for the workspace-state markers (plan §6.5 V4,
 * §6.6; test-support/store-path-lock.ts): the shared initialization record and each
 * feature's marker, what initialization and marking commit, which hand-written markers
 * are admitted, and when the workspace refuses to be available.
 */
it("workspace-state-paths: initialize, mark features, admission and availability", async () => {
  const log = await storePathLock({ module: "gateway/workspace", name: "workspace-state-paths", testFileUrl: import.meta.url, owned: "gateway/workspace-state" });
  const state = join(log.home, "gateway", "workspace-state");
  const root = join(log.home, "workspace");
  const features: TronWorkspaceFeature[] = ["profile", "episodic", "home-tasks", "apps"];
  const opened: TronWorkspace[] = [];
  const open = () => {
    const causes: TronWorkspaceUnavailableCause[] = [];
    const workspace = new TronWorkspace(log.home, { unavailable: (cause) => causes.push(cause) });
    opened.push(workspace);
    return { workspace, causes };
  };
  const initialized = async (workspace: TronWorkspace) => Object.fromEntries(await Promise.all(features.map(async (feature) =>
    [feature, await workspace.featureInitialized(feature).catch((error: Error) => `refused: ${error.message}`)])));
  const availability = async ({ workspace, causes }: ReturnType<typeof open>) => ({ describe: await workspace.describe(), causes });
  try {
    await log.step("describe an absent workspace", () => TronWorkspace.describeExisting(log.home));
    const first = open();
    await log.step("initialize a fresh home", () => availability(first), "result");
    await log.step("describe the existing workspace", () => TronWorkspace.describeExisting(log.home));
    await log.step("no feature is initialized", () => initialized(first.workspace));
    await log.step("mark home-tasks", () => first.workspace.markFeatureInitialized("home-tasks"), "result");
    await log.step("mark home-tasks again is unchanged", () => first.workspace.markFeatureInitialized("home-tasks"), "result");
    await log.step("mark Profile writes its separate feature record", () => first.workspace.markFeatureInitialized("profile"), "result");
    await log.step("mark apps twice at once", () => Promise.all([first.workspace.markFeatureInitialized("apps"), first.workspace.markFeatureInitialized("apps")]), "result");
    await log.step("marked features are initialized", () => initialized(first.workspace));
    await log.step("a second owner of the same home is unavailable", () => availability(open()));

    const files = join(root, "files");
    const filesRoot = () => first.workspace.filesRoot();
    await log.step("files root before it exists is refused", filesRoot, "refused");
    await mkdir(files, { mode: 0o700 });
    try {
      await log.step("an owner-only files root", filesRoot, "result");
      await chmod(files, 0o500);
      await log.step("a files root its owner cannot write is refused", filesRoot, "refused");
      await chmod(files, 0o755);
      await log.step("a files root others can enter but not write", filesRoot, "result");
      await chmod(files, 0o775);
      await log.step("a files root its group can write is refused", filesRoot, "refused");
    } finally { await chmod(files, 0o700); }

    const marker = (name: string, value: unknown) => writeFile(join(state, name), JSON.stringify(value), { mode: 0o600 });
    const episodic: Array<[string, unknown]> = [["version 1", { version: 1 }], ["another key", { version: 1, extra: 1 }], ["version 2", { version: 2 }],
      ["a list", [{ version: 1 }]], ["null", null], ["empty", {}]];
    await log.step("hand-written feature markers", async () => {
      const results: Record<string, unknown> = {};
      for (const [label, value] of episodic) {
        await marker("episodic-initialized.json", value);
        results[label] = await first.workspace.featureInitialized("episodic").catch((error: Error) => `refused: ${error.message}`);
      }
      return results;
    });
    await log.step("marking over an invalid feature marker is refused", () => first.workspace.markFeatureInitialized("episodic"), "refused");
    await log.step("dispose closes the workspace", async () => { await first.workspace.dispose(); return first.workspace.describe(); });
    await log.step("dispose again is unchanged", () => first.workspace.dispose(), "result");
    const shared: Array<[string, unknown]> = [["version 1", { version: 1 }], ["knowledge false", { version: 1, knowledgeInitialized: false }],
      ["knowledge true", { version: 1, knowledgeInitialized: true }], ["another key", { version: 1, extra: true }], ["version 2", { version: 2 }],
      ["knowledge text", { version: 1, knowledgeInitialized: "yes" }], ["a list", [{ version: 1 }]]];
    await log.step("hand-written shared records require fresh-owner admission", async () => {
      const results: Record<string, unknown> = {};
      for (const [label, value] of shared) {
        await marker("initialized.json", value);
        const next = open();
        try {
          results[label] = { ...await availability(next),
            profileInitialized: await next.workspace.featureInitialized("profile").catch((error: Error) => `refused: ${error.message}`) };
        } finally { await next.workspace.dispose(); }
      }
      return results;
    });
    await log.step("an invalid shared record makes the workspace unavailable", () => availability(open()));
    await marker("initialized.json", { version: 1 });
    await log.step("a valid shared record admits a new owner", async () => {
      const next = open();
      const result = await availability(next);
      await next.workspace.dispose();
      return result;
    });
    await chmod(state, 0o755);
    try {
      await log.step("a workspace-state directory others can read is unsafe", () => availability(open()));
    } finally { await chmod(state, 0o700); }
    await rm(root, { recursive: true });
    await log.step("describe after the root was removed", () => TronWorkspace.describeExisting(log.home));
    await log.step("a removed root is lost data, not a fresh install", () => availability(open()));
    await writeFile(root, "", { mode: 0o700 });
    await log.step("a regular file in place of the root is unsafe", () => availability(open()));
  } finally {
    for (const workspace of opened) await workspace.dispose().catch(() => {});
  }
  await log.finish();
});
