import { chmod, mkdir, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { startGatewayProcess, type GatewayProcess } from "../../../test-support/gateway-process.js";
import { waitFor } from "../../../test-support/wait-for.js";

/**
 * The managed pi-subagents closure's TypeScript is transformed once per build
 * (#2214). A real Gateway process on a fresh Tron home prepares that cache in the
 * background after it serves, so the first session start reads it instead of
 * paying the transform itself (#2229).
 */

const gateways: GatewayProcess[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

async function managedBuild(gateway: GatewayProcess): Promise<{ root: string; cache: string; modules: number }> {
  const installs = join(gateway.tronHome, "internal", "pi-subagents");
  const version = (await readdir(installs)).find((name) => !name.startsWith("."))!;
  const root = join(installs, version);
  let modules = 0;
  const visit = async (directory: string): Promise<void> => {
    for (const item of await readdir(directory, { withFileTypes: true })) {
      if (item.isDirectory() && item.name !== "node_modules") await visit(join(directory, item.name));
      else if (item.isFile() && /\.[cm]?tsx?$/u.test(item.name) && !/\.d\.[cm]?tsx?$/u.test(item.name)) modules += 1;
    }
  };
  await visit(root);
  return { root, cache: join(gateway.tronHome, "internal", "pi-subagents-transform-cache", version), modules };
}

const cached = async (cache: string) => (await readdir(cache).catch(() => [])).length;

it("prepares a fresh home's managed transforms after it serves, so the first session start transforms nothing", async () => {
  const gateway = await startGatewayProcess();
  gateways.push(gateway);
  const build = await managedBuild(gateway);
  // No client has asked for anything: the Gateway serves, then prepares the cache on its own.
  const warmedStep = (log: Array<Record<string, any>>) => log.findIndex((record) => record.event === "gateway.startup-step" && record.step === "subagent-transforms");
  await waitFor(async () => warmedStep(await gateway.log()) >= 0 || undefined, "background transform preparation finishes", { boundMs: 60_000 });
  expect(await cached(build.cache)).toBeGreaterThanOrEqual(build.modules);
  const log = await gateway.log();
  const serving = log.findIndex((record) => record.event === "gateway.startup-budget");
  const warmed = warmedStep(log);
  expect(serving, "the Gateway reported serving").toBeGreaterThanOrEqual(0);
  expect(warmed, "the preparation finished after the Gateway served, never before").toBeGreaterThan(serving);
  const before = await cached(build.cache);
  const phone = await gateway.connect();
  const created = await phone.request("session.create", { commandId: "warm-first-create", cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  // The first session's managed factory found every transform already prepared.
  expect(await cached(build.cache)).toBe(before);
  await phone.close();
}, 120_000);

it("lets the first session start prepare the transforms itself when the startup preparation fails", async () => {
  const gateway = await startGatewayProcess();
  gateways.push(gateway);
  const build = await managedBuild(gateway);
  await waitFor(async () => await cached(build.cache) >= build.modules || undefined, "the first start prepared its cache", { boundMs: 60_000 });
  const failures = () => gateway.log().then((log) => log.filter((record) => record.event === "pi-subagents.transform-cache-failed").length);
  const failedBefore = await failures();
  // The next start finds an empty cache it cannot write, so its background preparation fails.
  await gateway.restart({ whileStopped: async () => {
    await rm(build.cache, { recursive: true, force: true });
    await mkdir(build.cache, { recursive: true, mode: 0o700 });
    await chmod(build.cache, 0o500);
  } });
  try {
    await waitFor(async () => await failures() > failedBefore || undefined, "the startup preparation reports its failure", { boundMs: 60_000 });
  } finally { await chmod(build.cache, 0o700); }
  expect(await cached(build.cache)).toBe(0);
  // Nothing remembers the failure: the first session start prepares and loads.
  const phone = await gateway.connect();
  const created = await phone.request("session.create", { commandId: "fallback-first-create", cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  expect(await cached(build.cache)).toBeGreaterThanOrEqual(build.modules);
  await phone.close();
}, 180_000);
