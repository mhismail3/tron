import { registerHooks, syncBuiltinESMExports } from "node:module";
import fs from "node:fs/promises";
import { join } from "node:path";

// Test-only loader and real filesystem cut; no production fault hook or
// synthetic audit/receipt. The parent owns and joins this exact child's kill.
registerHooks({
  resolve(specifier, context, next) {
    try { return next(specifier, context); }
    catch (error) {
      if (specifier.endsWith(".js")) return next(specifier.slice(0, -3) + ".ts", context);
      throw error;
    }
  },
});
const [root] = process.argv.slice(2);
const tronHome = join(root, "tron"), agentDir = join(tronHome, "agent");
const request = JSON.parse(await fs.readFile(join(root, "history-crash-request.json"), "utf8"));
let registry;
const rename = fs.rename;
fs.rename = async (from, to) => {
  await rename(from, to);
  if (String(to) === join(tronHome, "gateway", "settings", "changes", "000001.jsonl")) {
    // The segment replacement is visible, but its directory/index transaction
    // is not complete. Release only this fixture's workspace lease; never age a
    // foreign lease, freeze the process, or let the mutation finish.
    await registry.dispose();
    process.stdin.resume();
    process.stdout.write("settings-history-crash-window\n");
    await new Promise(() => {});
  }
};
syncBuiltinESMExports();
const { ModelRuntime } = await import("@earendil-works/pi-coding-agent");
const { fauxProvider } = await import("@earendil-works/pi-ai");
const { createTestRegistry, displayOwnerOf } = await import("./gateway-registry.ts");
const { TEST_SETTINGS_SCHEMA } = await import("./settings-schema.ts");
const { TrustService } = await import("../src/kernel/resources/trust-service.ts");
const { SettingsStoreAdapter } = await import("../src/admin/settings-model.ts");
const { SettingsModel } = await import("../src/kernel/settings/settings-model.ts");
const { SettingsChangePath } = await import("../src/kernel/settings/settings-change.ts");
const { SettingsChangeRecord } = await import("../src/kernel/settings/settings-record.ts");
const { SettingsApprovals } = await import("../src/kernel/settings/settings-approvals.ts");
const { CommandReceiptStore } = await import("../src/transport/command-receipts.ts");
const { GatewayService } = await import("../src/transport/gateway-service.ts");
const faux = fauxProvider({ provider: "tron-settings-change", models: [{ id: "first", reasoning: true }, { id: "second", reasoning: true }] });
const runtimeFactory = async () => {
  const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider); return runtime;
};
const trust = new TrustService(agentDir), modelRuntime = await runtimeFactory();
registry = await createTestRegistry({ agentDir, tronHome, trust, modelRuntimeFactory: runtimeFactory,
  broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
await registry.initialize();
const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome, trust, modelRuntime }));
const settingsChanges = new SettingsChangePath(settingsModel, new SettingsChangeRecord(tronHome, 2), new SettingsApprovals(tronHome), {});
registry.setSettings(settingsModel, settingsChanges);
await settingsChanges.start();
const service = new GatewayService({ display: displayOwnerOf(registry),
  config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
  modelRuntime, trust, settingsModel, settingsChanges, sessions: registry, receipts: new CommandReceiptStore(tronHome), broadcast: () => {},
  globalProviderResources: { withStableSnapshot: async operation => operation(), requestReload: () => {} },
});
await service.invoke({ id: "phone", identity: "device:phone", isLocal: false }, "settings.change", request);
throw new Error("The settings history crash cut was not reached");
