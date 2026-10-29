import { writeFileSync } from "node:fs";
import fs from "node:fs/promises";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { createTestRegistry, displayOwnerOf } from "./gateway-registry.js";
import { TrustService } from "../src/kernel/resources/trust-service.js";
import { CommandReceiptStore } from "../src/transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../src/transport/gateway-service.js";
import { durableAtomicWriteJson } from "../src/util/durable-json.js";

// Test-only crash cuts around real writes. No process suspension, synthetic
// app/receipt files or production test hooks: the parent owns and joins SIGKILL.
const [root, cut, marker] = process.argv.slice(2) as [string, string, string];
const request = JSON.parse(await fs.readFile(join(root, "request.json"), "utf8"));
async function barrier(): Promise<never> {
  // Release the fixture RuntimeRegistry/workspace lease, not the held Apps
  // mutation or its receipt. This isolates Apps durability from the separate
  // workspace lock's 60-second stale-owner policy after an ungraceful death.
  await registry.dispose();
  process.stdin.resume(); writeFileSync(marker, cut);
  return new Promise<never>(() => {});
}
const agentDir = join(root, "agent"), tronHome = join(root, "tron");
const faux = fauxProvider({ provider: "apps-folder-runtime-fixture", tokensPerSecond: 100_000 });
const registry = await createTestRegistry({ agentDir, tronHome, trust: new TrustService(agentDir), idleRuntimeMs: 60_000,
  modelRuntimeFactory: async () => {
    const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
    runtime.registerNativeProvider(faux.provider); return runtime;
  }, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
});
await registry.initialize(); await registry.initializeBlobStorage();
const receipts = new CommandReceiptStore(tronHome, async (path, value, mode) => {
  const receipt = value as { commandId: string; status: string };
  if (receipt.commandId !== request.params.commandId) { await durableAtomicWriteJson(path, value, mode); return; }
  if (cut === "effects" && receipt.status === "completed") await barrier();
  await durableAtomicWriteJson(path, value, mode);
  if (cut === "pending" && receipt.status === "pending" || cut === "completion" && receipt.status === "completed") await barrier();
});
const service = new GatewayService({ display: displayOwnerOf(registry),
  config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
  sessions: registry, modules: registry.moduleHost, receipts, broadcast: () => {},
  globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
} as unknown as GatewayServiceDependencies);
try {
  await service.invoke({ id: "phone", identity: "device:apps-folder-runtime", isLocal: false } as ClientContext, request.method, request.params);
  throw new Error(`The crash fixture passed ${cut} without being killed`);
} finally { await registry.dispose(); await receipts.dispose(); }
