import { statSync } from "node:fs";
import type { InputAdmissionPolicy, InputEnvelopeContext, InputEnvelope } from "../kernel/host/input-admission.js";
import type { HomeOwner } from "./home-owner.js";
import type { HomeTaskDiagnostic } from "./home-task-dispatcher.js";
import { HOME_OPERATING_CONTEXT } from "./tron-home-extension.js";
import { HOME_PROFILE_BOUND_BYTES } from "./home-profile.js";
import { HOME_HARD_BYTES, HOME_HARD_ENTRIES } from "./home-chapter-state.js";

/** Delivery headroom counts the learned profile at its bound: the activation's section is
 * read inside Home's prompt hook, after this estimate, and never exceeds it. */
const HOME_PROFILE_HEADROOM_TEXT = "x".repeat(HOME_PROFILE_BOUND_BYTES + 1_024);
const HOME_INBOX_ADMISSION_SLOW_MS = 2_000;

export function homeInputAdmission(owner: HomeOwner, diagnostic?: (record: HomeTaskDiagnostic) => void): InputAdmissionPolicy {
  return {
    admit: (sessionId, operationId, delivery, append, envelope) => owner.admitTaskResults(sessionId, operationId, delivery, append, envelope),
    release: (taskId, operationId, eventId) => owner.releaseWakeTrigger(taskId, operationId, eventId),
    settle: (sessionId, operationId) => owner.settleTaskResults(sessionId, operationId),
    envelope: homeInputEnvelope,
    finished: (startedAt, delivery) => {
      const durationMs = Math.round(performance.now() - startedAt);
      if (durationMs >= HOME_INBOX_ADMISSION_SLOW_MS) diagnostic?.({ event: "home.inbox.admission-slow", delivery, durationMs });
    },
  };
}

async function homeInputEnvelope(context: InputEnvelopeContext): Promise<InputEnvelope> {
  const { session, policy, text, images, signal } = context;
  const headroom = await policy.deliveryHeadroom(session, { role: "user", content: [{ type: "text", text }, ...(images ?? [])], timestamp: Date.now() }, `${session.systemPrompt}\n\n${HOME_OPERATING_CONTEXT}\n\n${HOME_PROFILE_HEADROOM_TEXT}`, signal);
  let chapterBytes = 0;
  if (context.sessionFile()) {
    try { chapterBytes = statSync(context.sessionFile()!).size; }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  }
  return { ...headroom, bytes: Math.max(0, HOME_HARD_BYTES - chapterBytes - Buffer.byteLength(JSON.stringify({ text, images })) * 4),
    entries: Math.max(0, HOME_HARD_ENTRIES - context.entries()) };
}
