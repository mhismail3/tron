import type { GatewayService, ClientContext } from "../src/transport/gateway-service.js";
import type { ChangeResult } from "../src/kernel/settings/tool-contract.js";

/** An intentional paired-client grant through the shipped typed RPC. This
 * crosses admission, real stores and receipts, not native rendering; native
 * provenance/denial oracles must invoke the unconfirmed route themselves. */
export async function reviewedMutation(service: GatewayService, client: ClientContext,
  method: "settings.change" | "settings.undo" | "settings.applyAgain", params: Record<string, unknown>): Promise<ChangeResult> {
  const result = await service.invoke(client, method, params) as unknown as ChangeResult;
  if (result.status !== "review" || params.dryRun) return result;
  if (!result.review?.requiresTap || client.isLocal) throw new Error("Expected an exact paired-native settings review");
  return await service.invoke(client, method, { ...params, commandId: `${String(params.commandId)}-native`,
    confirmationDigest: result.review.digest }) as unknown as ChangeResult;
}
