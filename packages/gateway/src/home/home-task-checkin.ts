import { Type } from "@earendil-works/pi-ai";

/** Small durable progress snapshots, not another transcript or a result. */
export const HOME_TASK_CHECKIN_LIMIT = 12;
export const HOME_TASK_CHECKIN_VISIBLE = 3;
export const HOME_TASK_ATTENTION_INTERVAL_MS = 30 * 60 * 1000;
export interface HomeTaskCheckinRequest {
  step: string;
  done: string;
  next: string;
  blocker?: string;
  refs?: { branch?: string; commit?: string; issue?: string };
  needsAttention?: boolean;
}
export interface HomeTaskCheckin extends HomeTaskCheckinRequest {
  id: string;
  taskId: string;
  sessionId: string;
  operationId: string;
  at: string;
  attention: "none" | "requested" | "rate-limited" | "pending";
}
const short = (maxLength: number) => Type.String({ minLength: 1, maxLength });
export const HOME_TASK_CHECKIN_PARAMETERS = Type.Object({
  step: short(256), done: short(512), next: short(512), blocker: Type.Optional(short(512)),
  refs: Type.Optional(Type.Object({ branch: Type.Optional(short(256)), commit: Type.Optional(short(256)), issue: Type.Optional(short(256)) }, { additionalProperties: false })),
  needsAttention: Type.Optional(Type.Boolean()),
}, { additionalProperties: false });
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const text = (v: unknown, bytes: number) => typeof v === "string" && !!v.trim() && !v.includes("\0") && Buffer.byteLength(v) <= bytes;
export function parseHomeTaskCheckinRequest(value: unknown): HomeTaskCheckinRequest {
  if (!object(value) || Object.keys(value).some(key => !["step", "done", "next", "blocker", "refs", "needsAttention"].includes(key))
    || !text(value.step, 256) || !text(value.done, 512) || !text(value.next, 512)
    || (value.blocker !== undefined && !text(value.blocker, 512))
    || (value.needsAttention !== undefined && typeof value.needsAttention !== "boolean")
    || (value.needsAttention === true && !text(value.blocker, 512))
    || (value.refs !== undefined && (!object(value.refs) || Object.entries(value.refs).some(([key, v]) => !["branch", "commit", "issue"].includes(key) || !text(v, 256))))
    || Buffer.byteLength(JSON.stringify(value)) > 4096) throw new Error("Invalid check-in: use short step/done/next fields; needsAttention requires a blocker.");
  return structuredClone(value) as unknown as HomeTaskCheckinRequest;
}
export function parseHomeTaskCheckin(value: unknown): HomeTaskCheckin {
  if (!object(value)) throw new Error("Invalid stored check-in");
  const { id, taskId, sessionId, operationId, at, attention, ...request } = value;
  parseHomeTaskCheckinRequest(request);
  if ([id, taskId, sessionId, operationId].some(v => typeof v !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u.test(v))
    || typeof at !== "string" || at.length > 64 || !Number.isFinite(Date.parse(at))
    || !["none", "requested", "rate-limited", "pending"].includes(attention as string)
    || ((attention !== "none") !== (request.needsAttention === true))) throw new Error("Invalid stored check-in");
  return value as unknown as HomeTaskCheckin;
}
