import type { SettingsChangePath, ChangeContext } from "./settings-change.js";
import type { SettingsSchema } from "./settings-schema.js";
import type { ApprovalRequest } from "./settings-approvals.js";
import { LAYER_LABELS } from "./settings-types.js";
import type { ChangeResult, SettingsApprovalPresenter } from "./tool-contract.js";
import { GatewayError } from "../../errors.js";

/** The durable diff owns admission and expiry; the existing host form owns the
 * live continuation. Closing/retiring that continuation never approves a diff. */
export async function reviewSettingsApproval(input: {
  path: SettingsChangePath;
  schema: SettingsSchema;
  requestId: string;
  requesterSessionId: string;
  present: SettingsApprovalPresenter;
  signal?: AbortSignal;
  context: (request: ApprovalRequest) => Promise<Pick<ChangeContext, "session" | "homeChapter">>;
}): Promise<ChangeResult> {
  const { path, requestId, requesterSessionId, signal } = input;
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  const stop = path.onOutcome((sessionId, settledId) => {
    if (sessionId === requesterSessionId && settledId === requestId) abort();
  });
  const read = async () => {
    const request = await path.approvals.get(requestId);
    if (!request || request.actor.sessionId !== requesterSessionId) throw new GatewayError("conflict", "This approval belongs to another requester");
    return request;
  };
  try {
    let request = await read();
    if (signal?.aborted) abort();
    if (request.status === "pending" && !controller.signal.aborted) {
      let choice: "approve" | "deny" | undefined;
      try {
        choice = await input.present({ requestId, title: "Settings approval", context: reviewText(input.schema, request), expiresAt: request.expiresAt }, controller.signal);
      } catch (error) {
        await path.cancelApproval(requestId, requesterSessionId);
        await path.approvals.acknowledge([requesterSessionId], [requestId]);
        throw error;
      }
      // Stop wins before decision admission. A decision already admitted keeps
      // its serialized receipt; it is never replayed or rolled back by Stop.
      if (!signal?.aborted && choice !== undefined) {
        try {
          return await path.decide(requestId, { digest: request.digest, approved: choice === "approve", decidedBy: { kind: "ui", id: `interaction:${requestId}` }, ...await input.context(request) });
        } catch (error) {
          const settled = await read();
          if (settled.status === "pending") throw error;
          // A tap can lose to expiry or a newer diff while awaiting the target
          // stripe. Return that explicit terminal outcome, not an opaque tool error.
          return terminalResult(settled);
        } finally {
          await path.approvals.acknowledge([requesterSessionId], [requestId]);
        }
      }
      request = await read();
    }
    if (request.status === "pending") {
      await path.cancelApproval(requestId, requesterSessionId);
      request = await read();
    }
    await path.approvals.acknowledge([requesterSessionId], [requestId]);
    return terminalResult(request);
  } finally {
    stop();
    signal?.removeEventListener("abort", abort);
    controller.abort();
  }
}

function terminalResult(request: ApprovalRequest): ChangeResult {
  return { status: request.status, tier: "approve", changes: request.changes.map(change => ({
    changeId: change.changeId, key: change.key, layer: change.layer, tier: change.tier, status: request.status,
    ...(change.qualifiers ? { qualifiers: change.qualifiers } : {}),
    ...(change.redacted ? { redacted: true } : { before: change.before ?? null, after: change.after ?? null }),
    ...(request.failure ? { error: { code: request.status, message: request.failure } } : {}),
  })) };
}

function reviewText(schema: SettingsSchema, request: ApprovalRequest): string {
  const target = request.target.kind === "home" ? "Home" : request.target.kind === "session" ? `Session ${request.target.sessionId}`
    : request.target.kind === "project" ? `Project ${JSON.stringify(request.target.cwd)}` : "Global";
  const lines = [`Scope: ${target}`, `Reason: ${JSON.stringify(request.reason ?? "Not provided")}`, ""];
  for (const change of request.changes) {
    const key = schema.schemaKey(change.key);
    const values = change.redacted ? "Before: Hidden value\nAfter: Changed"
      : `Before:\n${JSON.stringify(change.before ?? null, null, 2)}\nAfter:\n${JSON.stringify(change.after ?? null, null, 2)}`;
    lines.push(`${key.label} (${change.key})`, `Layer: ${LAYER_LABELS[change.layer]}`, ...(change.qualifiers ? [JSON.stringify(change.qualifiers)] : []), values,
      ...(key.confirm ? [key.confirm] : []), "");
  }
  lines.push(`Expires: ${request.expiresAt}`, "Approve applies only this diff. Deny changes nothing.");
  // Escape rather than strip author-supplied controls: host sanitization must
  // never consume a terminal-control payload and silently hide the bound diff.
  const text = lines.join("\n").replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u2028\u2029]/g,
    character => "\\u" + character.charCodeAt(0).toString(16).padStart(4, "0"));
  if (Buffer.byteLength(text, "utf8") > 32 * 1_024) {
    throw new GatewayError("invalid_request", "Settings approval diff is too large to review (maximum 32 KiB); request fewer or smaller changes");
  }
  return text;
}
