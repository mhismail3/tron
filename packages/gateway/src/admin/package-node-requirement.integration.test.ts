import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { JsonValue } from "../protocol/types.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { PackageService } from "./package-service.js";
import { TrustService } from "./trust-service.js";

/**
 * #243: a Pi package whose `engines.node` excludes the Gateway's Node installs
 * with only an npm `EBADENGINE` warning, and nothing afterwards says so. This
 * drives the real package RPCs (`packages.install` through the receipt-backed
 * mutation path, then `packages.list`) through `GatewayService`, a real
 * `PackageService`, Pi's real `DefaultPackageManager` and canonical
 * `settings.json` in a temporary agent directory. The fixture packages declare a
 * satisfied, an unsatisfied, an invalid and no range; the warning never blocks
 * install or listing (maintainer decision D-2, recorded on #241).
 */

const client: ClientContext = {
  id: "dashboard", identity: "device:dashboard", isLocal: false, signal: undefined,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => false,
  attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
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

describe("packages.list projects each package's engines.node against the Gateway runtime", () => {
  it("warns for unsatisfied and invalid ranges, omits a missing one, and never blocks install", async () => {
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
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const broadcast = (topic: string, payload: JsonValue) => { events.push({ topic, payload }); };
    const gateway = new GatewayService({
      sessions: { isAdministrativeDrainStarted: false },
      packages: new PackageService(agentDir, new TrustService(agentDir), broadcast),
      receipts: new CommandReceiptStore(join(root, "receipts")),
      globalProviderResources: { requestReload: () => {} },
      broadcast,
    } as unknown as GatewayServiceDependencies);

    for (const [index, source] of Object.values(sources).entries()) {
      await expect(gateway.invoke(client, "packages.install", { commandId: `install-node-${index}`, cwd, source }))
        .resolves.toMatchObject({ operationId: expect.any(String) });
    }
    expect(events.filter(({ topic }) => topic === "packages.completed").map(({ payload }) => (payload as { success: boolean }).success))
      .toEqual([true, true, true, true]);

    const listed = (await gateway.invoke(client, "packages.list", { cwd }) as { packages: ListedPackage[] }).packages;
    // Pi records a local source relative to the agent directory.
    const bySource = new Map(listed.map((entry) => [join(agentDir, entry.source), entry]));
    expect(bySource.get(sources.satisfied)?.nodeRequirement)
      .toEqual({ range: `>=${runtime.split(".")[0]}`, runtime, status: "satisfied" });
    expect(bySource.get(sources.unsatisfied)?.nodeRequirement).toEqual({ range: ">=999.0.0", runtime, status: "unsatisfied" });
    expect(bySource.get(sources.invalid)?.nodeRequirement).toEqual({ range: "the newest one", runtime, status: "invalid" });
    expect(bySource.get(sources.missing)).not.toHaveProperty("nodeRequirement");
    // Warn, never refuse: the mismatched package is installed and still contributes its resources.
    expect(bySource.get(sources.unsatisfied)?.provides.skills).toEqual(["future-node"]);
    expect(bySource.get(sources.invalid)?.provides.skills).toEqual(["invalid-node"]);
  });
});
