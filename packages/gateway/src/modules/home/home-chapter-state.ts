import { GatewayError } from "../../errors.js";

export const HOME_HARD_BYTES = 200 * 1_024 * 1_024;
export const HOME_HARD_ENTRIES = 100_000;
export const HOME_SOFT_BYTES = 24 * 1_024 * 1_024;
export const HOME_SOFT_ENTRIES = 50_000;

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

export function unsealedHomeChapterState(sessionId: string): HomeChapterState {
  return { sessionId, sealed: false };
}

export function assertChapterWritable(state: HomeChapterState, ownsMaterialization = false): void {
  if (!state.sealed || (state.materializing && ownsMaterialization)) return;
  throw new SealedChapterMutationError(state);
}
