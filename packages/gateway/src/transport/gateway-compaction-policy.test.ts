import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { expect, it, vi } from "vitest";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SettingsService } from "../admin/settings-service.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

it("publishes a saved compaction change and refreshes runtime projections exactly once per command", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-compaction-settings-rpc-"));
  try {
    const cwd = join(root, "project");
    await mkdir(cwd);
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    const refreshCompactionPolicies = vi.fn();
    const broadcast = vi.fn();
    const settings = new SettingsService(root, runtime);
    const service = new GatewayService({
      receipts: new CommandReceiptStore(join(root, "receipts")), settings, broadcast,
      sessions: { refreshCompactionPolicies },
      trust: { canonicalDirectory: async () => cwd, inspect: async () => ({ cwd, effectiveDecision: false }) },
    } as unknown as GatewayServiceDependencies);
    const client = { id: "phone", identity: "device:compaction-test", isLocal: false } as ClientContext;
    const params = { commandId: "compaction-settings-1", scope: "global", cwd, patch: { compaction: { thinkingLevel: "low", instructions: "Keep the API contract" } } };
    const results = await Promise.all([service.invoke(client, "settings.update", params), service.invoke(client, "settings.update", params)]);
    expect(results[0]).toEqual(results[1]);
    expect(refreshCompactionPolicies).toHaveBeenCalledExactlyOnceWith("global", cwd);
    expect(broadcast).toHaveBeenCalledExactlyOnceWith("settings.changed", { scope: "global", cwd });
    expect(JSON.parse(await readFile(join(root, "settings.json"), "utf8"))).toMatchObject(params.patch);
    const reopened = await service.invoke(client, "settings.get", { scope: "global", cwd });
    expect(reopened).toMatchObject({ effective: { compaction: { thinkingLevel: "low", instructions: "Keep the API contract", source: { thinkingLevel: "global" } } } });
    expect((reopened as any).effective.compaction.model).toBeUndefined();
  } finally { await rm(root, { recursive: true, force: true }); }
});
