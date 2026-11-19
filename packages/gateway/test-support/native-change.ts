import type { GatewayService, ClientContext } from "../src/transport/gateway-service.js";
import type { ChangeResult } from "../src/kernel/settings/tool-contract.js";

export async function maintainerChange(service: GatewayService, client: ClientContext,
  method: "settings.change" | "settings.undo", params: Record<string, unknown>): Promise<ChangeResult> {
  return await service.invoke(client, method, params) as unknown as ChangeResult;
}

export async function answerChangeCard(service: GatewayService, client: ClientContext,
  slot: { id: string; snapshot(): { extensionPresentation: { pendingInteractions: Array<{ id: string; method: string; hostEpoch: string; presentationRevision: number; review?: { digest: string } }> } } },
  approved: boolean, commandId: string) {
  const { waitFor } = await import("./wait-for.js");
  const interaction = await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.find(item => item.method === "change"),
    "the exact change card", { boundMs: 30_000 });
  const viewer = Object.assign(Object.create(Object.getPrototypeOf(client)), client, { isSubscribed: () => true }) as ClientContext;
  const response = service.invoke(viewer, "extension.respond", { commandId, sessionId: slot.id, interactionId: interaction.id,
    hostEpoch: interaction.hostEpoch, presentationRevision: interaction.presentationRevision, value: { digest: interaction.review!.digest, approved } });
  return { interaction, response };
}
