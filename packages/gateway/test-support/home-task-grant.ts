import { authorizationRequestId, HomeTaskAuthorizationError, type HomeTaskAuthorization, type HomeTaskAuthorizationRequest } from "../src/modules/home/home-task-authorization.js";

export async function issueGrant(owner: HomeTaskAuthorization, request: HomeTaskAuthorizationRequest,
  input: { decisionId: string; approved?: boolean; expiresAt: number }) {
  let requestId = authorizationRequestId(request);
  await owner.authorize(request).catch(error => { if (error instanceof HomeTaskAuthorizationError && error.requestId) requestId = error.requestId; });
  const result = await owner.recordDecisionAndGrant(requestId, { ...input, approved: input.approved ?? true, restoreEpoch: request.restoreEpoch });
  return result.grant!;
}
