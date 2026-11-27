import { StringEnum, Type } from "../pi/ai.js";
import type { HomeTaskCheckin, HomeTaskCheckinRequest, HomeTaskWaitFor } from "../../protocol/types.js";

export const HOME_TASK_CHECKIN_LIMIT = 12;
export const HOME_TASK_CHECKIN_VISIBLE = 3;
export const HOME_TASK_ATTENTION_INTERVAL_MS = 30 * 60 * 1000;
const short = (maxLength: number) => Type.String({ minLength: 1, maxLength });
export const HOME_TASK_CHECKIN_PARAMETERS = Type.Object({
  step: short(256), done: short(512), next: short(512), blocker: Type.Optional(short(512)),
  refs: Type.Optional(Type.Object({ branch: Type.Optional(short(256)), commit: Type.Optional(short(256)), issue: Type.Optional(short(256)) }, { additionalProperties: false })),
  needsAttention: Type.Optional(Type.Boolean()),
  heavy: Type.Optional(StringEnum(["start", "done"] as const, { description: "start before a heavy run (simulator, large build, full suite, gate); done when it ends." })),
  waitFor: Type.Optional(Type.Object({
    home: Type.Optional(Type.String({ minLength: 1, maxLength: 512, description: "A question for Home; Home answers with a steer." })),
    task: Type.Optional(Type.String({ minLength: 1, maxLength: 160, description: "Another running task's taskId; needs until." })),
    until: Type.Optional(StringEnum(["settled", "heavy-done"] as const)),
    heavy: Type.Optional(Type.Literal(true, { description: "Wait for a free heavy slot." })),
  }, { additionalProperties: false, description: "Park this task in place until exactly one condition holds: home, task with until, or heavy. End your turn after it." })),
}, { additionalProperties: false });
const id = (v: unknown) => typeof v === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u.test(v);
function validWait(v: unknown): v is HomeTaskWaitFor {
  if (!object(v)) return false;
  const keys = Object.keys(v).sort().join(",");
  return (keys === "home" && text(v.home, 512)) || (keys === "task,until" && id(v.task) && ["settled", "heavy-done"].includes(v.until as string))
    || (keys === "heavy" && v.heavy === true);
}
export function homeTaskWaitText(wait: HomeTaskWaitFor): string {
  return wait.home !== undefined ? `Home's answer: ${wait.home}` : wait.task !== undefined ? `task ${wait.task} ${wait.until === "settled" ? "to settle" : "to post heavy done"}` : "a free heavy slot";
}
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const text = (v: unknown, bytes: number) => typeof v === "string" && !!v.trim() && !v.includes("\0") && Buffer.byteLength(v) <= bytes;
export function parseHomeTaskCheckinRequest(value: unknown): HomeTaskCheckinRequest {
  if (!object(value) || Object.keys(value).some(key => !["step", "done", "next", "blocker", "refs", "needsAttention", "heavy", "waitFor"].includes(key))
    || !text(value.step, 256) || !text(value.done, 512) || !text(value.next, 512)
    || (value.blocker !== undefined && !text(value.blocker, 512))
    || (value.needsAttention !== undefined && typeof value.needsAttention !== "boolean")
    || (value.needsAttention === true && !text(value.blocker, 512))
    || (value.heavy !== undefined && value.heavy !== "start" && value.heavy !== "done")
    || (value.waitFor !== undefined && !validWait(value.waitFor))
    || (value.refs !== undefined && (!object(value.refs) || Object.entries(value.refs).some(([key, v]) => !["branch", "commit", "issue"].includes(key) || !text(v, 256))))
    || Buffer.byteLength(JSON.stringify(value)) > 4096) throw new Error("Invalid check-in: use short step/done/next fields; needsAttention requires a blocker; waitFor is exactly one of {home}, {task, until} or {heavy: true}.");
  return structuredClone(value) as unknown as HomeTaskCheckinRequest;
}
export function parseHomeTaskCheckin(value: unknown): HomeTaskCheckin {
  if (!object(value)) throw new Error("Invalid stored check-in");
  const { id, taskId, sessionId, operationId, at, attention, ...request } = value;
  parseHomeTaskCheckinRequest(request);
  if ([id, taskId, sessionId, operationId].some(v => typeof v !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/u.test(v))
    || typeof at !== "string" || at.length > 64 || !Number.isFinite(Date.parse(at))
    || !["none", "requested", "rate-limited", "pending"].includes(attention as string)
    || ((attention !== "none") !== (request.needsAttention === true || (request.waitFor as HomeTaskWaitFor | undefined)?.home !== undefined))) throw new Error("Invalid stored check-in");
  return value as unknown as HomeTaskCheckin;
}
