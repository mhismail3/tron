import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterEach, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";

// A home still holding a retired location (docs/tron-home.md) must not start:
// no store may read or recreate either place until the offline migration ran.
// After `scripts/tron home-layout migrate` the same home starts and the owner
// serves the moved document (its distinctive revision) through the real RPC.

const gatewayRoot = fileURLToPath(new URL("../..", import.meta.url));
const repositoryRoot = join(gatewayRoot, "..", "..");
// Resolves source `.js` specifiers to their `.ts` files for a Gateway run from source.
const resolverPreload = pathToFileURL(join(gatewayRoot, "test-support", "home-ledger-crash-preload.mjs")).href;
const deployModule = pathToFileURL(join(repositoryRoot, "scripts", "gateway-payload-deploy.mjs")).href;
const connections = `${JSON.stringify({ schemaVersion: 1, stateRevision: 41, instances: {}, setupOperations: {}, receipts: {} })}\n`;
const roots: string[] = [];
const children: Array<ReturnType<typeof spawn>> = [];

afterEach(async () => {
  for (const child of children.splice(0)) {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
      await once(child, "exit");
    }
  }
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => typeof address === "object" && address ? resolve(address.port) : reject(new Error("no port")));
    });
  });
}

async function startGateway(root: string, tronHome: string) {
  const port = await freePort();
  const child = spawn(process.execPath, ["--experimental-transform-types", "--no-warnings", "--import", resolverPreload, join(gatewayRoot, "src", "index.ts")], {
    cwd: gatewayRoot,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      PATH: process.env.PATH,
      HOME: join(root, "home"),
      TMPDIR: join(root, "tmp"),
      TRON_DATA_DIR: tronHome,
      PI_CODING_AGENT_DIR: join(tronHome, "agent"),
      PI_SUBAGENTS_TEMP_ROOT: join(tronHome, "internal", "subagents"),
      TRON_GATEWAY_HOST: "127.0.0.1",
      TRON_GATEWAY_PORT: String(port),
    },
  });
  children.push(child);
  let output = "";
  child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  return { child, port, output: () => output };
}

async function logged(tronHome: string, event: string): Promise<boolean> {
  const text = await readFile(join(tronHome, "logs", "gateway.jsonl"), "utf8").catch(() => "");
  return text.includes(`"event":"${event}"`);
}

it("refuses a home with a retired location, then starts once the offline migration moved it", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-home-layout-"));
  roots.push(root);
  const tronHome = join(root, "tron");
  for (const directory of ["home", "tmp", "tron/agent", "tron/state/integrations"]) await mkdir(join(root, directory), { recursive: true, mode: 0o700 });
  const legacy = join(tronHome, "state", "integrations", "connections.json");
  await writeFile(legacy, connections, { mode: 0o600 });

  const refused = await startGateway(root, tronHome);
  const outcome = await waitFor(async () => refused.child.exitCode !== null ? "exited"
    : await logged(tronHome, "gateway.startup-budget") ? "serving" : undefined, "the Gateway exits or serves");
  expect(outcome).toBe("exited");
  expect(refused.child.exitCode).not.toBe(0);
  expect(refused.output()).toContain("uses a retired layout (state/integrations/connections.json -> gateway/integrations/connections.json)");
  expect(refused.output()).toContain(`scripts/tron home-layout migrate --home ${tronHome}`);
  expect(await readFile(legacy, "utf8")).toBe(connections);
  await expect(stat(join(tronHome, "gateway", "integrations"))).rejects.toMatchObject({ code: "ENOENT" });

  execFileSync("python3", [join(repositoryRoot, "tools", "home-layout", "home_layout.py"), "migrate", "--home", tronHome]);
  expect(await readFile(join(tronHome, "gateway", "integrations", "connections.json"), "utf8")).toBe(connections);
  await expect(stat(join(tronHome, "state"))).rejects.toMatchObject({ code: "ENOENT" });

  const started = await startGateway(root, tronHome);
  await waitFor(async () => {
    if (started.child.exitCode !== null || started.child.signalCode !== null) throw new Error(`Gateway exited during startup: ${started.output()}`);
    return await logged(tronHome, "gateway.startup-budget") || undefined;
  }, "the migrated home's Gateway is serving");
  const { authenticatedRequest, readLocalCredential } = await import(deployModule) as {
    authenticatedRequest: (options: Record<string, unknown>) => Promise<{ stateRevision: number }>;
    readLocalCredential: (path: string) => Promise<string>;
  };
  const token = await readLocalCredential(join(tronHome, "gateway", "local-auth.json"));
  const listed = await authenticatedRequest({ host: "127.0.0.1", port: started.port, token, timeoutMs: 10_000, method: "connections.list", params: {} });
  expect(listed.stateRevision).toBe(41);
}, 120_000);
