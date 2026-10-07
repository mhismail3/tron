import { GatewayError } from "../errors.js";

/** Physical chapter state consumed only by the runtime that owns that session. */
export interface HomeChapterState {
  sessionId: string;
  sealed: boolean;
  /** Only the Home prompt route may cross this temporary materialization state. */
  materializing?: boolean;
  ordinal?: number;
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

/** Slot-owner refusal; callers invoke this inside their serialized mutation lane. */
export function assertChapterWritable(state: HomeChapterState, homeMaterializationPermit = false): void {
  if (!state.sealed || (state.materializing && homeMaterializationPermit)) return;
  throw new SealedChapterMutationError(state);
}
