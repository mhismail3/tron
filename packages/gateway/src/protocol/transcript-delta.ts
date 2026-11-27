import { createHash } from "node:crypto";
import type { SessionSnapshot, SessionTranscriptDelta } from "./types.js";

export const MAXIMUM_TRANSCRIPT_DELTA_REPLACEMENTS = 16;

export interface TranscriptCut {
  readonly runtimeGeneration: string;
  readonly eventSequence: number;
  readonly transcriptStart: number;
  readonly transcriptTotal: number;
  readonly leafEntryId: string | null;
  readonly ids: readonly string[];
  readonly digests: readonly string[];
}

export function transcriptCut(snapshot: SessionSnapshot): TranscriptCut {
  return {
    runtimeGeneration: snapshot.runtimeGeneration,
    eventSequence: snapshot.eventSequence,
    transcriptStart: snapshot.transcriptStart,
    transcriptTotal: snapshot.transcriptTotal,
    leafEntryId: snapshot.leafEntryId ?? null,
    ids: snapshot.transcript.map((item) => item.id),
    digests: snapshot.transcript.map((item) => createHash("sha256").update(JSON.stringify(item)).digest("base64")),
  };
}

export function transcriptDelta(base: TranscriptCut, current: TranscriptCut, snapshot: SessionSnapshot): SessionTranscriptDelta | undefined {
  if (base.runtimeGeneration !== current.runtimeGeneration
    || base.digests.length !== base.transcriptTotal - base.transcriptStart
    || current.transcriptStart < base.transcriptStart
    || current.transcriptStart > base.transcriptTotal
    || current.transcriptTotal < base.transcriptTotal) return undefined;
  const replaced: SessionTranscriptDelta["replaced"] = [];
  for (let index = current.transcriptStart; index < base.transcriptTotal; index += 1) {
    const before = index - base.transcriptStart;
    const after = index - current.transcriptStart;
    if (base.digests[before] === current.digests[after]) continue;
    if (replaced.length === MAXIMUM_TRANSCRIPT_DELTA_REPLACEMENTS || base.ids[before] !== current.ids[after]) return undefined;
    replaced.push({ index, item: snapshot.transcript[after]! });
  }
  return {
    cut: { baseTranscriptStart: base.transcriptStart, baseLeafEntryId: base.leafEntryId, transcriptStart: current.transcriptStart },
    replaced,
    snapshot: {
      ...snapshot,
      transcript: snapshot.transcript.slice(base.transcriptTotal - current.transcriptStart),
      transcriptStart: base.transcriptTotal,
    },
  };
}

export function applyTranscriptDelta(current: SessionSnapshot, delta: SessionTranscriptDelta): SessionSnapshot | undefined {
  const { cut, replaced, snapshot } = delta;
  const baseTotal = snapshot.transcriptStart;
  if (current.sessionId !== snapshot.sessionId
    || current.runtimeGeneration !== snapshot.runtimeGeneration
    || current.transcriptStart !== cut.baseTranscriptStart
    || current.transcriptTotal !== baseTotal
    || current.transcriptStart + current.transcript.length !== baseTotal
    || (current.leafEntryId ?? null) !== cut.baseLeafEntryId
    || cut.transcriptStart < cut.baseTranscriptStart
    || cut.transcriptStart > baseTotal
    || replaced.length > MAXIMUM_TRANSCRIPT_DELTA_REPLACEMENTS
    || baseTotal + snapshot.transcript.length !== snapshot.transcriptTotal) return undefined;
  const retained = current.transcript.slice(cut.transcriptStart - cut.baseTranscriptStart);
  for (const { index, item } of replaced) {
    const offset = index - cut.transcriptStart;
    if (!Number.isSafeInteger(offset) || offset < 0 || offset >= retained.length || retained[offset]!.id !== item.id) return undefined;
    retained[offset] = item;
  }
  return { ...snapshot, transcript: [...retained, ...snapshot.transcript], transcriptStart: cut.transcriptStart };
}
