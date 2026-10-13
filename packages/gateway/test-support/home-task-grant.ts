import { authorizationRequestId, HomeTaskAuthorizationError, type HomeTaskAuthorization, type HomeTaskAuthorizationRequest } from "../src/home/home-task-authorization.js";

/** Records an approving decision for one authorization request and returns the
 * one-use grant it mints. A refused first attempt still names its request ID. */
export async function issueGrant(owner: HomeTaskAuthorization, request: HomeTaskAuthorizationRequest,
  input: { decisionId: string; approved?: boolean; expiresAt: number }) {
  let requestId = authorizationRequestId(request);
  await owner.authorize(request).catch(error => { if (error instanceof HomeTaskAuthorizationError && error.requestId) requestId = error.requestId; });
  const result = await owner.recordDecisionAndGrant(requestId, { ...input, approved: input.approved ?? true, restoreEpoch: request.restoreEpoch });
  return result.grant!;
}
