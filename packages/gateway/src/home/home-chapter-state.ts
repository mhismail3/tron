import { GatewayError } from "../errors.js";

/** Physical chapter state consumed only by the runtime that owns that session. */
export interface HomeChapterState {
  sessionId: string;
  sealed: boolean;
}

/** The current Home record has one writable session; chapter support is not active. */
export function unsealedHomeChapterState(sessionId: string): HomeChapterState {
  return { sessionId, sealed: false };
}

/** Slot-owner refusal; callers invoke this inside their serialized mutation lane. */
export function assertChapterWritable(state: HomeChapterState): void {
  if (!state.sealed) return;
  throw new GatewayError("conflict", "This Home chapter is sealed and cannot be changed", false, {
    reason: "sealed-chapter",
    sessionId: state.sessionId,
  });
}
