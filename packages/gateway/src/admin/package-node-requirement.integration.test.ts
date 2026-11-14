import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { PackageService } from "./package-service.js";
import { TrustService } from "../kernel/resources/trust-service.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "../kernel/delegation/managed-subagents.js";
import { SettingsChangePath } from "../kernel/settings/settings-change.js";
import { SettingsChangeRecord } from "../kernel/settings/settings-record.js";
import type { ChangeReview } from "../protocol/types.js";
import { gitDaemonRepository, publishedNpmRegistry } from "../../test-support/package-source-fixtures.js";

const execFileAsync = promisify(execFile);

const client: ClientContext = {
  id: "dashboard", identity: "device:dashboard", isLocal: false, signal: undefined,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => false,

  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
};

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true }))); });

async function fixturePackage(root: string, name: string, engines?: unknown): Promise<string> {
  const directory = join(root, "packages", name);
  await mkdir(join(directory, "skills", name), { recursive: true });
  await writeFile(join(directory, "package.json"), JSON.stringify({
    name, version: "1.0.0", pi: { skills: ["skills"] }, ...(engines === undefined ? {} : { engines }),
  }));
  await writeFile(join(directory, "skills", name, "SKILL.md"), `---\nname: ${name}\ndescription: Fixture skill.\n---\nFixture.\n`);
  return directory;
}

interface ListedPackage {
  source: string;
  provides: { skills: string[] };
  nodeRequirement?: { range: string; runtime: string; status: string };
}

it("refuses managed-package mutation before admission while ordinary package controls remain usable", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-managed-package-control-"));
  roots.push(root);
  const agentDir = join(root, "agent"), cwd = join(root, "workspace");
  await mkdir(agentDir, { recursive: true });
  await mkdir(cwd, { recursive: true });
  const settingsPath = join(agentDir, "settings.json");
  const settings = JSON.stringify({ packages: [] });
  await writeFile(settingsPath, settings);
  const managed = ManagedSubagents.activateForStartup(join(root, "tron"));
  const managedRoot = managed.verify();
  const receiptPath = join(managedRoot, "tron-install-receipt.json");
  const receipt = await readFile(receiptPath, "utf8");
  const gateway = new GatewayService({ display: {} as never,
    sessions: { isAdministrativeDrainStarted: false },
    packages: new PackageService(agentDir, new TrustService(agentDir), () => {}, undefined, managed),
    receipts: new CommandReceiptStore(join(root, "receipts")),
    globalProviderResources: { requestReload: () => {} }, broadcast: () => {},
  } as unknown as GatewayServiceDependencies);
  const inventory = await gateway.invoke(client, "packages.list", { cwd }) as { packages: Array<{ source: string; scope: string }> };
  expect(inventory.packages).toContainEqual(expect.objectContaining({ source: MANAGED_SUBAGENTS_SOURCE, scope: "user" }));
  for (const action of ["remove", "update"]) {
    await expect(gateway.invoke(client, `packages.${action}`, { commandId: `managed-${action}`, cwd, source: MANAGED_SUBAGENTS_SOURCE }))
      .rejects.toMatchObject({ code: "conflict", message: "Tron manages pi-subagents; package commands cannot change its bundled payload" });
  }
  expect(await readFile(settingsPath, "utf8")).toBe(settings);
  expect(managed.verify()).toBe(managedRoot);
  expect(await readFile(receiptPath, "utf8")).toBe(receipt);

  const source = await fixturePackage(root, "ordinary-control");
  await writeFile(settingsPath, JSON.stringify({ packages: [source] }));
  const listed = await gateway.invoke(client, "packages.list", { cwd }) as typeof inventory;
  const ordinary = listed.packages.find(row => row.source !== MANAGED_SUBAGENTS_SOURCE)!;
  expect(ordinary).toBeDefined();
  for (const action of ["update", "remove"]) {
    await expect(gateway.invoke(client, `packages.${action}`, { commandId: `ordinary-${action}`, cwd, source: ordinary.source }))
      .resolves.toMatchObject({ operationId: expect.any(String) });
  }
  expect(managed.verify()).toBe(managedRoot);
  expect(await readFile(receiptPath, "utf8")).toBe(receipt);
});

describe("packages.list projects each package's engines.node against the Gateway runtime", () => {
  it("warns for unsatisfied and invalid ranges, omits a missing one, and never blocks a configured package", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-node-"));
    roots.push(root);
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await mkdir(agentDir, { recursive: true });
    await mkdir(cwd, { recursive: true });
    const runtime = process.versions.node;
    const sources = {
      satisfied: await fixturePackage(root, "satisfied-node", { node: `>=${runtime.split(".")[0]}` }),
      unsatisfied: await fixturePackage(root, "future-node", { node: ">=999.0.0" }),
      invalid: await fixturePackage(root, "invalid-node", { node: "the newest one" }),
      missing: await fixturePackage(root, "no-engines"),
    };
    const broadcast = () => {};
    const gateway = new GatewayService({ display: {} as never,
      sessions: { isAdministrativeDrainStarted: false },
      packages: new PackageService(agentDir, new TrustService(agentDir), broadcast),
      receipts: new CommandReceiptStore(join(root, "receipts")),
      globalProviderResources: { requestReload: () => {} },
      broadcast,
    } as unknown as GatewayServiceDependencies);

    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: Object.values(sources) }));

    const listed = (await gateway.invoke(client, "packages.list", { cwd }) as { packages: ListedPackage[] }).packages;
    const bySource = new Map(listed.map((entry) => [resolve(agentDir, entry.source), entry]));
    expect(bySource.get(sources.satisfied)?.nodeRequirement)
      .toEqual({ range: `>=${runtime.split(".")[0]}`, runtime, status: "satisfied" });
    expect(bySource.get(sources.unsatisfied)?.nodeRequirement).toEqual({ range: ">=999.0.0", runtime, status: "unsatisfied" });
    expect(bySource.get(sources.invalid)?.nodeRequirement).toEqual({ range: "the newest one", runtime, status: "invalid" });
    expect(bySource.get(sources.missing)).not.toHaveProperty("nodeRequirement");
    expect(bySource.get(sources.unsatisfied)?.provides.skills).toEqual(["future-node"]);
    expect(bySource.get(sources.invalid)?.provides.skills).toEqual(["invalid-node"]);
  });
});

describe("settings package update installs one exact version through the owner", () => {
  it("applies exact npm, pinned and ranged npm and git SHA updates behind cards that show every configured pin change", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-update-"));
    roots.push(root);
    const agentDir = join(root, "agent"), cwd = join(root, "workspace"), tronHome = join(root, "tron");
    await mkdir(agentDir, { recursive: true });
    await mkdir(cwd, { recursive: true });
    const name = `tron-update-fixture-${randomUUID().slice(0, 8)}`, pinnedName = `tron-update-pin-${randomUUID().slice(0, 8)}`, rangedName = `tron-update-range-${randomUUID().slice(0, 8)}`;
    const registry = await publishedNpmRegistry(root, [
      { name, versions: ["1.0.0", "1.2.0", "1.3.0"], latest: "1.0.0" },
      { name: pinnedName, versions: ["1.0.0", "1.1.0"], latest: "1.0.0" },
      { name: rangedName, versions: ["1.0.0", "1.1.0", "1.2.0"], latest: "1.2.0" },
    ]);
    const saved = { registry: process.env.npm_config_registry, cache: process.env.npm_config_cache };
    process.env.npm_config_registry = registry.base;
    process.env.npm_config_cache = join(root, "npm-cache");
    try {
      const source = `npm:${name}`, pinned = `npm:${pinnedName}@1.0.0`, rangedSource = `npm:${rangedName}@^1.0.0`;
      const local = await fixturePackage(root, "local-update-refusal");
      const ranged = { source: rangedSource, skills: [] };
      const settingsPath = join(agentDir, "settings.json");
      await writeFile(settingsPath, JSON.stringify({ packages: [source, local, pinned, ranged] }));
      const records = new SettingsChangeRecord(tronHome);
      const changes = new SettingsChangePath({} as never, records, { setTrust: async () => undefined });
      let reloads = 0;
      const packages = new PackageService(agentDir, new TrustService(agentDir), () => {});
      packages.register(changes, () => { reloads += 1; });
      const requester = { kind: "home" as const, id: "home-session" };
      const installedPathOf = async (configured: string) => (await packages.list(cwd)).packages.find(row => row.source === configured)?.installedPath;
      const installedVersion = async (configured: string) => {
        const installedPath = await installedPathOf(configured);
        return installedPath ? JSON.parse(await readFile(join(installedPath, "package.json"), "utf8")).version as string : undefined;
      };
      const configured = async () => JSON.parse(await readFile(settingsPath, "utf8")).packages;

      await packages.mutate("update", source, cwd, false);
      await packages.mutate("update", pinned, cwd, false);
      await packages.mutate("update", rangedSource, cwd, false);
      expect(await installedVersion(source)).toBe("1.0.0");
      expect(await installedVersion(rangedSource)).toBe("1.2.0");

      let reviewed: ChangeReview | undefined;
      const applied = await packages.updatePackage({ cwd, source, version: "1.2.0", reason: "Home requested the fixture update" }, requester, async (review, apply) => {
        reviewed = review;
        registry.state.latest[name] = "1.3.0";
        return apply({ deviceId: "ios-device", commandId: "command-1" });
      });
      expect(reviewed?.title).toContain(name);
      expect(reviewed?.title).toContain("1.2.0");
      expect(reviewed?.items).toEqual([
        expect.objectContaining({ label: expect.stringContaining(name), before: "1.0.0", after: "1.2.0" }),
        { label: "Configured source", before: source, after: `npm:${name}@1.2.0`, detail: "sources.packages (global) pin", exact: expect.any(String) },
      ]);
      expect(applied).toMatchObject({ status: "applied", changes: [expect.objectContaining({ key: "package.update", undoable: false })] });
      expect(await installedVersion(`npm:${name}@1.2.0`)).toBe("1.2.0");
      expect(await configured()).toEqual([`npm:${name}@1.2.0`, local, pinned, ranged]);
      expect(reloads).toBe(1);

      const pinnedReview = await packages.updatePackage({ cwd, source: pinned, version: "1.1.0", reason: "Pinned fixture" }, requester);
      expect(pinnedReview).toMatchObject({ status: "review", review: { items: [
        expect.objectContaining({ before: "1.0.0", after: "1.1.0" }),
        expect.objectContaining({ label: "Configured source", before: pinned, after: `npm:${pinnedName}@1.1.0` }),
      ] } });
      await packages.updatePackage({ cwd, source: pinned, version: "1.1.0", reason: "Pinned fixture" }, requester, async (_review, apply) => apply({ deviceId: "ios-device", commandId: "command-pin" }));
      expect(await installedVersion(`npm:${pinnedName}@1.1.0`)).toBe("1.1.0");
      expect(await configured()).toEqual([`npm:${name}@1.2.0`, local, `npm:${pinnedName}@1.1.0`, ranged]);

      await packages.updatePackage({ cwd, source: rangedSource, version: "1.1.0", reason: "Ranged fixture" }, requester, async (_review, apply) => apply({ deviceId: "ios-device", commandId: "command-range" }));
      expect(await installedVersion(`npm:${rangedName}@1.1.0`)).toBe("1.1.0");
      expect(await configured()).toEqual([`npm:${name}@1.2.0`, local, `npm:${pinnedName}@1.1.0`, { source: `npm:${rangedName}@1.1.0`, skills: [] }]);
      expect(reloads).toBe(3);

      const audited = (await records.page({ filter: entry => entry.key === "package.update" })).entries;
      expect(audited.filter(entry => entry.status === "applied")).toHaveLength(3);
      expect(audited.every(entry => entry.action === true && entry.reason)).toBe(true);
      expect((await records.page({ filter: entry => entry.key === "sources.packages" })).entries).toEqual([]);
      const startedChange = audited.find(entry => entry.status === "started" && entry.reason === "Home requested the fixture update")!;
      await expect(changes.undo(startedChange.changeId, { actor: { kind: "ui", id: "ios-device" }, reason: "try undo" }))
        .rejects.toMatchObject({ code: "conflict", message: "This change is not undoable; inspect it with its owner" });

      await expect(packages.updatePackage({ cwd, source: `npm:${name}@1.2.0`, version: "1.3.0", reason: "Declined" }, requester, async () => undefined))
        .resolves.toEqual({ status: "declined", changes: [] });
      await expect(packages.updatePackage({ cwd, source: `npm:${name}@1.2.0`, version: "1.3.0", reason: "Drift" }, requester, async (_review, apply) => {
        const installedPath = await installedPathOf(`npm:${name}@1.2.0`);
        await writeFile(join(installedPath!, "package.json"), JSON.stringify({ name, version: "1.2.1" }));
        return apply({ deviceId: "ios-device", commandId: "command-2" });
      })).rejects.toMatchObject({ code: "conflict" });
      expect(await installedVersion(`npm:${name}@1.2.0`)).toBe("1.2.1");
      await writeFile(join(await installedPathOf(`npm:${name}@1.2.0`) as string, "package.json"), JSON.stringify({ name, version: "1.2.0" }));

      await expect(packages.updatePackage({ cwd, source: `npm:${name}@1.2.0`, version: "1.3.0", reason: "Review only" }, requester)).resolves.toMatchObject({ status: "review" });
      expect(await installedVersion(`npm:${name}@1.2.0`)).toBe("1.2.0");

      await expect(packages.updatePackage({ cwd, source: local, version: "1.3.0", reason: "Local" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("Local package sources have no update source") });
      await expect(packages.updatePackage({ cwd, source: `npm:${name}-missing`, version: "1.3.0", reason: "Missing" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "not_found" });
      await expect(packages.updatePackage({ cwd, source: `npm:${name}@1.2.0`, version: "latest", reason: "Tag" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("exact npm version") });
      await expect(packages.updatePackage({ cwd, source: `npm:${name}@1.2.0`, version: "1.2.0", reason: "Same" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("already") });
      await expect(packages.updatePackage({ cwd, source: `npm:${name}@1.2.0`, version: "1.3.0", reason: "Chat" }, { kind: "agent", id: "ordinary-chat" }, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("Tron Home") });
      await expect(packages.updatePackage({ cwd, source: `npm:${name}@1.2.0`, version: "1.3.0", reason: "Worker" }, { kind: "worker", id: "worker" }, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("Tron Home") });
      await expect(packages.updatePackage({ cwd, source: `https://user:secret@example.invalid/tool.git`, version: "1.3.0", reason: "Creds" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("credentials") });
      expect(await installedVersion(`npm:${name}@1.2.0`)).toBe("1.2.0");
      expect(reloads).toBe(3);

    } finally {
      await registry.close();
      process.env.npm_config_registry = saved.registry;
      process.env.npm_config_cache = saved.cache;
    }
  });

  it("updates an installed git checkout to one exact commit, refuses edits, and keeps the installed bits at that commit", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-update-git-"));
    roots.push(root);
    const agentDir = join(root, "agent"), cwd = join(root, "workspace"), tronHome = join(root, "tron");
    await mkdir(agentDir, { recursive: true });
    await mkdir(cwd, { recursive: true });
    const repo = await gitDaemonRepository(root, "tool");
    const source = repo.source;
    const restoreGitConfig = repo.activate();
    try {
      const settingsPath = join(agentDir, "settings.json");
      await writeFile(settingsPath, JSON.stringify({ packages: [source] }));
      const first = await repo.commit("a\n", "a");
      const records = new SettingsChangeRecord(tronHome);
      const changes = new SettingsChangePath({} as never, records, { setTrust: async () => undefined });
      let reloads = 0;
      const packages = new PackageService(agentDir, new TrustService(agentDir), () => {});
      packages.register(changes, () => { reloads += 1; });
      const requester = { kind: "home" as const, id: "home-session" };
      const installedPathOf = async (configured: string) => (await packages.list(cwd)).packages.find(row => row.source === configured)?.installedPath as string;

      await packages.mutate("update", source, cwd, false);
      const installedPath = await installedPathOf(source);
      expect(await gitHead(installedPath)).toBe(first);
      const second = await repo.commit("b\n", "b");
      const third = await repo.commit("c\n", "c");

      let reviewed: ChangeReview | undefined;
      await expect(packages.updatePackage({ cwd, source: source, version: second, reason: "Exact git" }, requester, async (review, apply) => {
        reviewed = review;
        await repo.commit("d\n", "d");
        return apply({ deviceId: "ios-device", commandId: "git-1" });
      })).resolves.toMatchObject({ status: "applied", changes: [expect.objectContaining({ undoable: false })] });
      expect(reviewed?.items).toEqual([
        expect.objectContaining({ before: first, after: second }),
        { label: "Configured source", before: source, after: `${source}@${second}`, detail: "sources.packages (global) pin", exact: expect.any(String) },
      ]);
      expect(reviewed?.title).toContain(second);
      expect(await gitHead(installedPath)).toBe(second);
      expect(JSON.parse(await readFile(settingsPath, "utf8")).packages).toEqual([`${source}@${second}`]);
      expect(await installedPathOf(`${source}@${second}`)).toBe(installedPath);

      await writeFile(join(installedPath, "index.txt"), "local edit\n");
      await expect(packages.updatePackage({ cwd, source: `${source}@${second}`, version: third, reason: "Dirty" }, requester, async (_review, apply) => apply({ deviceId: "ios-device", commandId: "git-dirty" })))
        .rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("local edits") });
      expect(await readFile(join(installedPath, "index.txt"), "utf8")).toBe("local edit\n");
      expect(await gitHead(installedPath)).toBe(second);
      await execFileAsync("git", ["-C", installedPath, "checkout", "--", "index.txt"]);

      const pinnedReview = await packages.updatePackage({ cwd, source: `${source}@${second}`, version: third, reason: "Pin move" }, requester);
      expect(pinnedReview).toMatchObject({ status: "review", review: { items: [
        expect.objectContaining({ before: second, after: third }),
        expect.objectContaining({ label: "Configured source", before: `${source}@${second}`, after: `${source}@${third}` }),
      ] } });
      await packages.updatePackage({ cwd, source: `${source}@${second}`, version: third, reason: "Pin move" }, requester, async (_review, apply) => apply({ deviceId: "ios-device", commandId: "git-2" }));
      expect(await gitHead(installedPath)).toBe(third);
      expect(JSON.parse(await readFile(settingsPath, "utf8")).packages).toEqual([`${source}@${third}`]);

      await expect(packages.updatePackage({ cwd, source: `${source}@${third}`, version: third.slice(0, 12), reason: "Short" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("40-character") });
      await expect(packages.updatePackage({ cwd, source: `${source}@${third}`, version: third, reason: "Same" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("already") });
      expect(reloads).toBe(2);
      expect((await records.page({ filter: entry => entry.key === "sources.packages" })).entries).toEqual([]);
    } finally {
      restoreGitConfig();
      await repo.close();
    }
  });

  it("plans a git update without running a configured fsmonitor or clean filter in the installed checkout before the tap", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-update-plan-"));
    roots.push(root);
    const agentDir = join(root, "agent"), cwd = join(root, "workspace"), tronHome = join(root, "tron");
    await mkdir(agentDir, { recursive: true });
    await mkdir(cwd, { recursive: true });
    const repo = await gitDaemonRepository(root, "tool");
    const source = repo.source;
    const restoreGitConfig = repo.activate();
    try {
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: [source] }));
      const first = await repo.commit("a\n", "a");
      const changes = new SettingsChangePath({} as never, new SettingsChangeRecord(tronHome), { setTrust: async () => undefined });
      const packages = new PackageService(agentDir, new TrustService(agentDir), () => {});
      packages.register(changes, () => {});
      await packages.mutate("update", source, cwd, false);
      const installedPath = (await packages.list(cwd)).packages.find(row => row.source === source)?.installedPath as string;
      expect(await gitHead(installedPath)).toBe(first);
      const second = await repo.commit("b\n", "b");

      const fsmonitorMarker = join(root, "fsmonitor-ran"), filterMarker = join(root, "filter-ran");
      await execFileAsync("git", ["-C", installedPath, "config", "core.fsmonitor", `touch '${fsmonitorMarker}'`]);
      await execFileAsync("git", ["-C", installedPath, "config", "filter.marker.clean", `touch '${filterMarker}' && cat`]);
      await writeFile(join(installedPath, ".git", "info", "attributes"), "index.txt filter=marker\n");

      const review = await packages.updatePackage({ cwd, source, version: second, reason: "Plan only" }, { kind: "home", id: "home-session" });
      expect(review).toMatchObject({ status: "review", review: { items: [
        expect.objectContaining({ before: first, after: second }),
        expect.objectContaining({ label: "Configured source", before: source, after: `${source}@${second}` }),
      ] } });
      await expect(readFile(fsmonitorMarker)).rejects.toThrow();
      await expect(readFile(filterMarker)).rejects.toThrow();
      expect(await gitHead(installedPath)).toBe(first);
    } finally {
      restoreGitConfig();
      await repo.close();
    }
  });
});

async function gitHead(cwd: string): Promise<string> {
  return (await execFileAsync("git", ["-C", cwd, "rev-parse", "HEAD"])).stdout.trim();
}
