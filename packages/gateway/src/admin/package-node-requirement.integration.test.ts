import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
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

const exec = promisify(execFile);

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

async function publishedNpmRegistry(root: string, name: string, versions: string[], initialLatest: string) {
  const tarballs = join(root, "tarballs");
  await mkdir(tarballs, { recursive: true });
  for (const version of versions) {
    const build = join(root, "build", version, "package");
    await mkdir(build, { recursive: true });
    await writeFile(join(build, "package.json"), JSON.stringify({ name, version }));
    await exec("tar", ["-czf", join(tarballs, `${name}-${version}.tgz`), "-C", join(root, "build", version), "package"]);
  }
  const state = { latest: initialLatest, base: "" };
  const server = createServer(async (request, response) => {
    const url = request.url ?? "";
    if (url === `/${name}`) {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({
        name,
        "dist-tags": { latest: state.latest },
        versions: Object.fromEntries(versions.map(version => [version, { name, version, dist: { tarball: `${state.base}/-/${name}-${version}.tgz` } }])),
      }));
      return;
    }
    if (url.startsWith("/-/")) {
      const content = await readFile(join(tarballs, basename(url))).catch(() => undefined);
      if (content) { response.setHeader("content-type", "application/octet-stream"); response.end(content); return; }
    }
    response.statusCode = 404;
    response.end("{}");
  });
  await new Promise<void>(done => server.listen(0, "127.0.0.1", done));
  state.base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return { state, close: () => new Promise<void>(done => server.close(() => done())) };
}

describe("settings package update installs one exact npm version through the owner", () => {
  it("binds the card to the exact version, applies it despite later latest drift, audits it irreversibly and refuses the rest", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-package-update-"));
    roots.push(root);
    const agentDir = join(root, "agent"), cwd = join(root, "workspace"), tronHome = join(root, "tron");
    await mkdir(agentDir, { recursive: true });
    await mkdir(cwd, { recursive: true });
    const name = `tron-update-fixture-${randomUUID().slice(0, 8)}`;
    const registry = await publishedNpmRegistry(root, name, ["1.0.0", "1.2.0", "1.3.0"], "1.0.0");
    const saved = { registry: process.env.npm_config_registry, cache: process.env.npm_config_cache };
    process.env.npm_config_registry = registry.state.base;
    process.env.npm_config_cache = join(root, "npm-cache");
    try {
      const source = `npm:${name}`;
      const local = await fixturePackage(root, "local-update-refusal");
      const pinned = `npm:${name}@1.0.0`;
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: [source, local, pinned] }));
      const records = new SettingsChangeRecord(tronHome);
      const changes = new SettingsChangePath({} as never, records, { setTrust: async () => undefined });
      let reloads = 0;
      const packages = new PackageService(agentDir, new TrustService(agentDir), () => {});
      packages.register(changes, () => { reloads += 1; });
      const requester = { kind: "home" as const, id: "home-session" };
      const request = { cwd, source, reason: "Home requested the fixture update" };
      const installedPathOf = async (configured: string) => (await packages.list(cwd)).packages.find(row => row.source === configured)?.installedPath;
      const installedVersion = async () => {
        const installedPath = await installedPathOf(source);
        return installedPath ? JSON.parse(await readFile(join(installedPath, "package.json"), "utf8")).version as string : undefined;
      };

      await packages.mutate("update", source, cwd, false);
      expect(await installedVersion()).toBe("1.0.0");

      let reviewed: ChangeReview | undefined;
      const applied = await packages.updatePackage({ ...request, version: "1.2.0" }, requester, async (review, apply) => {
        reviewed = review;
        registry.state.latest = "1.3.0";
        return apply({ deviceId: "ios-device", commandId: "command-1" });
      });
      expect(reviewed?.title).toContain(name);
      expect(reviewed?.title).toContain("1.2.0");
      expect(reviewed?.items).toEqual([expect.objectContaining({ label: expect.stringContaining(name), before: "1.0.0", after: "1.2.0" })]);
      expect(applied).toMatchObject({ status: "applied", changes: [expect.objectContaining({ key: "package.update", undoable: false })] });
      expect(await installedVersion()).toBe("1.2.0");
      expect(reloads).toBe(1);
      const configured = JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8")).packages;
      expect(configured).toEqual([source, local, pinned]);

      const audited = (await records.page({ filter: entry => entry.key === "package.update" })).entries;
      expect(audited.map(entry => [entry.status, entry.action, entry.reason])).toEqual([
        ["applied", true, "Home requested the fixture update"], ["started", true, "Home requested the fixture update"],
      ]);
      const startedChange = audited.find(entry => entry.status === "started")!;
      await expect(changes.undo(startedChange.changeId, { actor: { kind: "ui", id: "ios-device" }, reason: "try undo" }))
        .rejects.toMatchObject({ code: "conflict", message: "This change is not undoable; inspect it with its owner" });
      expect(await installedVersion()).toBe("1.2.0");

      await expect(packages.updatePackage({ ...request, version: "1.3.0" }, requester, async () => undefined))
        .resolves.toEqual({ status: "declined", changes: [] });
      await expect(packages.updatePackage({ ...request, version: "1.3.0" }, requester, async (review, apply) => {
        const installedPath = await installedPathOf(source);
        await writeFile(join(installedPath!, "package.json"), JSON.stringify({ name, version: "1.2.1" }));
        return apply({ deviceId: "ios-device", commandId: "command-2" });
      })).rejects.toMatchObject({ code: "conflict" });
      expect(await installedVersion()).toBe("1.2.1");
      await writeFile(join(await installedPathOf(source) as string, "package.json"), JSON.stringify({ name, version: "1.2.0" }));

      await expect(packages.updatePackage({ ...request, version: "1.3.0" }, requester)).resolves.toMatchObject({ status: "review" });
      expect(await installedVersion()).toBe("1.2.0");

      await expect(packages.updatePackage({ ...request, version: "1.3.0", source: local }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("Local package sources have no update source") });
      await expect(packages.updatePackage({ ...request, version: "1.3.0", source: pinned }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("pinned") });
      await expect(packages.updatePackage({ ...request, version: "1.3.0", source: `npm:${name}-missing` }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "not_found" });
      await expect(packages.updatePackage({ ...request, version: "latest" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("exact npm version") });
      await expect(packages.updatePackage({ ...request, version: "1.2.0" }, requester, async () => undefined))
        .rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("already") });
      await expect(packages.updatePackage({ ...request, version: "1.3.0", source: `npm:${name}` }, { kind: "agent", id: "ordinary-chat" }, async () => undefined))
        .rejects.toMatchObject({ code: "invalid_request", message: expect.stringContaining("Tron Home") });
      expect(await installedVersion()).toBe("1.2.0");
      expect(reloads).toBe(1);
    } finally {
      await registry.close();
      process.env.npm_config_registry = saved.registry;
      process.env.npm_config_cache = saved.cache;
    }
  });
});
