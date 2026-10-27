import { GatewayError } from "../../errors.js";
import type { SettingsChangePath } from "./settings-change.js";
import type { ApprovalRequest } from "./settings-approvals.js";
import type { ApprovalPresenter, ChangeResult } from "./tool-contract.js";

/**
 * One agent tool call waiting for the maintainer's decision on its own request
 * (#2050). The durable request owns admission, decision and expiry; the host form
 * only shows the request in the asking chat. Every decision (chat sheet, push or
 * Changes) is `settings.decide`, which settles the request and so ends this wait.
 * Stop or host retirement supersedes the pending request, never declining it.
 */
export async function awaitApprovalDecision(input: {
  path: SettingsChangePath;
  requestId: string;
  requesterSessionId: string;
  present: ApprovalPresenter;
  signal?: AbortSignal;
}): Promise<ChangeResult> {
  const { path, requestId, requesterSessionId, signal } = input;
  const read = async () => {
    const request = await path.approvals.get(requestId);
    if (!request || request.actor.sessionId !== requesterSessionId) throw new GatewayError("conflict", "This approval belongs to another requester");
    return request;
  };
  const form = new AbortController();
  let release!: () => void;
  const settled = new Promise<void>(resolve => { release = resolve; });
  const stop = path.onOutcome((sessionId, settledId) => { if (sessionId === requesterSessionId && settledId === requestId) release(); });
  signal?.addEventListener("abort", release, { once: true });
  try {
    let request = await read();
    if (request.status === "pending" && !signal?.aborted) {
      const title = request.action?.preview.title ?? "Approve settings changes";
      // The form resolves only when its host retires it: approval answers are refused.
      const host: { refused?: { error: unknown } } = {};
      const shown = input.present({ requestId, title }, form.signal).then(() => undefined, (error: unknown) => { host.refused = { error }; });
      await Promise.race([settled, shown]);
      if (host.refused) {
        // No host can show it (or the host refused it): retire the request it owns.
        await path.cancelApproval(requestId, requesterSessionId, "turn-ended");
        await path.approvals.acknowledge([requesterSessionId], [requestId]);
        throw host.refused.error;
      }
      request = await read();
    }
    if (request.status === "pending") {
      await path.cancelApproval(requestId, requesterSessionId, "turn-ended");
      request = await read();
    }
    // The tool result is this requester's delivery: no later outcome turn repeats it.
    await path.approvals.acknowledge([requesterSessionId], [requestId]);
    return approvalResult(request);
  } finally {
    stop();
    signal?.removeEventListener("abort", release);
    form.abort();
  }
}

/** A request's state as every approval-requesting tool reports it: the same
 * `approval` reference while pending and once settled, so its chat chip persists. */
export function approvalResult(request: ApprovalRequest): ChangeResult {
  return {
    status: request.status, tier: "approve",
    approval: { requestId: request.requestId, digest: request.digest, expiresAt: request.expiresAt },
    ...(request.action ? { action: request.action.preview } : {}),
    ...(request.summary ? { summary: request.summary } : {}),
    ...(request.failure ? { failure: request.failure } : {}),
    changes: request.changes.map(change => ({
      changeId: change.changeId, key: change.key, layer: change.layer, tier: change.tier, status: request.status,
      ...(change.qualifiers ? { qualifiers: change.qualifiers } : {}),
      ...(change.redacted ? { redacted: true } : { before: change.before ?? null, after: change.after ?? null }),
      ...(request.failure ? { error: { code: request.status, message: request.failure } } : {}),
    })),
  };
}
