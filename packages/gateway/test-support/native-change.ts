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

/** The same paired-iPhone tap over a real wire client: an exact review is
 * answered once with its digest under a new command ID; other results return. */
export async function reviewedRequest(client: { request(method: string, params: Record<string, unknown>): Promise<{ ok: boolean; result?: any }> },
  method: "settings.change" | "settings.undo" | "settings.applyAgain", params: Record<string, unknown>, commandId: () => string) {
  const response = await client.request(method, params);
  if (!response.ok || response.result?.status !== "review" || params.dryRun) return response;
  if (!response.result.review?.requiresTap) throw new Error("Expected an exact paired-native settings review");
  return client.request(method, { ...params, commandId: commandId(), confirmationDigest: response.result.review.digest });
}
