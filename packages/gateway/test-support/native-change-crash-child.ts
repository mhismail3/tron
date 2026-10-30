import { writeFileSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { createTestRegistry, displayOwnerOf } from "./gateway-registry.js";
import { settingsDependencies } from "./settings-dependencies.js";
import { waitFor } from "./wait-for.js";
import { TrustService } from "../src/kernel/resources/trust-service.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../src/transport/gateway-service.js";
import { CommandReceiptStore } from "../src/transport/command-receipts.js";
import { durableAtomicWriteJson } from "../src/foundation/durable-json.js";

const [root, cut, mode] = process.argv.slice(2);
if (!root || !["pending", "effects", "completion"].includes(cut!) || !["kill", "recover"].includes(mode!)) throw new Error("Expected isolated native receipt crash arguments");
const tronHome = join(root, "tron"), agentDir = join(root, "agent"), project = join(root, "project");
await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(project, { recursive: true })]);
process.env.PI_CODING_AGENT_DIR = agentDir;
process.env.PI_OFFLINE = "1";
const model = { provider: "native-crash-faux", id: "chat" };
const faux = fauxProvider({ provider: model.provider, models: [{ id: model.id }], tokensPerSecond: 1_000_000 });
if (mode === "kill") await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir: join(root, "sessions"), defaultProvider: model.provider, defaultModel: model.id, images: { blockImages: true } }));
const createRuntime = async () => {
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  return runtime;
};
const modelRuntime = await createRuntime(), trust = new TrustService(agentDir);
await trust.set(project, true);
const registry = await createTestRegistry({ agentDir, tronHome, trust, idleRuntimeMs: 60_000, modelRuntimeFactory: createRuntime,
  broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
await registry.initialize();
const settings = settingsDependencies({ agentDir, tronHome, trust, modelRuntime, registry, sessions: registry });
const park = async (): Promise<never> => {
  // A parent-owned fixture process, never a Gateway worker suspension.
  process.stdin.resume();
  writeFileSync(join(root, "cut"), cut!);
  return new Promise<never>(() => {});
};
const receipts = new CommandReceiptStore(tronHome, async (path, receipt, permissions) => {
  const status = (receipt as { status: string }).status;
  // This is the real callback's completion write: effects and audit are already
  // durable, but the canonical response still says pending at the effects cut.
  if (mode === "kill" && cut === "effects" && status === "completed") await park();
  await durableAtomicWriteJson(path, receipt, permissions);
  if (mode === "kill" && (cut === "pending" && status === "pending" || cut === "completion" && status === "completed")) await park();
});
const service = new GatewayService({ display: displayOwnerOf(registry),
  config: { machineId: "fixture", machineGroupID: "fixture", machineName: "Fixture", tronHome, agentDir },
  modelRuntime, trust, ...settings, sessions: registry, receipts,
  broadcast: () => {}, globalProviderResources: { withStableSnapshot: async (op: () => Promise<unknown>) => op(), requestReload: () => {} },
} as unknown as GatewayServiceDependencies);
const phone = { id: "phone", identity: "device:native-crash", isLocal: false, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;
if (mode === "kill") {
  const slot = await registry.create(project);
  await slot.setModel(model.provider, model.id);
  faux.setResponses([fauxAssistantMessage([fauxToolCall("settings", { action: "change", reason: "Exact crash-cut image access",
    changes: [{ key: "context.images.block", layer: "global", op: "set", value: false }] })], { stopReason: "toolUse" }), fauxAssistantMessage("Done")]);
  await slot.prompt("Allow images");
  const card = await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions[0], "child native card").catch(error => {
    process.stderr.write(JSON.stringify(slot.snapshot())); throw error;
  });
  if (card.method !== "change") throw new Error("Expected a native card, not a generic form");
  const params = { commandId: "native-crash-response", sessionId: slot.id, interactionId: card.id,
    hostEpoch: card.hostEpoch, presentationRevision: card.presentationRevision, value: { digest: card.review.digest, approved: true } };
  await writeFile(join(root, "request.json"), JSON.stringify(params));
  await service.invoke(phone, "extension.respond", params);
  throw new Error("Native response passed its requested crash cut");
}
try {
  const params = JSON.parse(await readFile(join(root, "request.json"), "utf8"));
  let replay: unknown;
  try { replay = { result: await service.invoke(phone, "extension.respond", params) }; }
  catch (error) { const failure = error as { code?: string; details?: unknown }; replay = { error: { code: failure.code, details: failure.details } }; }
  const document = JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8"));
  const history = (await settings.settingsChanges.history({ key: "context.images.block" })).entries;
  await writeFile(join(root, "recovered.json"), JSON.stringify({ replay, blockImages: document.images?.blockImages ?? null, history }));
} finally { await registry.dispose(); await receipts.dispose(); }
