import type { GatewayService, ClientContext } from "../src/transport/gateway-service.js";
import type { ChangeResult } from "../src/kernel/settings/tool-contract.js";

/** The paired maintainer's own typed write through the shipped RPC. His tap is the
 * authority, so it applies directly; native-card provenance/denial oracles invoke
 * the agent route themselves. */
export async function maintainerChange(service: GatewayService, client: ClientContext,
  method: "settings.change" | "settings.undo" | "settings.applyAgain", params: Record<string, unknown>): Promise<ChangeResult> {
  return await service.invoke(client, method, params) as unknown as ChangeResult;
}
