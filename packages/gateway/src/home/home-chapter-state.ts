import { GatewayError } from "../errors.js";

/** Shared ledger/source bound; no second chapter-count authority. */
export const HOME_MAX_CHAPTERS = 100_000;

/** Admission and the canonical growth observer share these exact boundaries. */
export const HOME_HARD_BYTES = 200 * 1_024 * 1_024;
export const HOME_HARD_ENTRIES = 100_000;

/** Physical chapter state consumed only by the runtime that owns that session. */
export interface HomeChapterState {
  sessionId: string;
  sealed: boolean;
  materializing?: boolean;
  homeId?: string;
  ordinal?: number;
  attemptId?: string;
  expectedPath?: string;
}

export class HomeChapterIdentityReplacementError extends GatewayError {
  constructor(sessionId: string) {
    super("conflict", "A Home chapter cannot replace its physical session identity or path", false, {
      reason: "home-identity-replacement", sessionId,
    });
    this.name = "HomeChapterIdentityReplacementError";
  }
}

export class SealedChapterMutationError extends GatewayError {
  constructor(state: HomeChapterState) {
    super("conflict", "This Home chapter is sealed and cannot be changed", false, {
      reason: "sealed-chapter",
      sessionId: state.sessionId,
    });
    this.name = "SealedChapterMutationError";
  }
}

/** The current Home record has one writable session; chapter support is not active. */
export function unsealedHomeChapterState(sessionId: string): HomeChapterState {
  return { sessionId, sealed: false };
}

/** Slot-owner refusal; materialization is allowed only for the slot bound to the exact durable attempt and path. */
export function assertChapterWritable(state: HomeChapterState, ownsMaterialization = false): void {
  if (!state.sealed || (state.materializing && ownsMaterialization)) return;
  throw new SealedChapterMutationError(state);
}
