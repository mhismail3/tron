import { applyTranscriptDelta } from "../src/protocol/transcript-delta.js";
import { decodeSessionTranscriptDelta, type SessionSnapshot } from "../src/protocol/types.js";

type Frame = { type?: string; topic?: string; sessionId?: string; payload?: any; result?: any };

export function sessionStates(frames: readonly Frame[], sessionId: string): Array<{ index: number; snapshot: SessionSnapshot }> {
  const states: Array<{ index: number; snapshot: SessionSnapshot }> = [];
  let current: SessionSnapshot | undefined;
  frames.forEach((frame, index) => {
    if (frame.type === "response") {
      if (frame.result?.session?.sessionId === sessionId) current = frame.result.session as SessionSnapshot;
      return;
    }
    if (frame.sessionId !== sessionId) return;
    if (frame.topic === "session.snapshot") current = frame.payload as SessionSnapshot;
    else if (frame.topic === "session.rebaseline") current = frame.payload.snapshot as SessionSnapshot;
    else if (frame.topic === "session.transcriptDelta") {
      const applied = current && applyTranscriptDelta(current, decodeSessionTranscriptDelta(frame.payload.data));
      if (!applied) throw new Error(`session.transcriptDelta ${frame.payload?.eventSequence} does not extend the client's transcript`);
      current = applied;
    } else return;
    states.push({ index, snapshot: current });
  });
  return states;
}

export function statedSnapshot(event: { topic: string; payload: unknown }): Partial<SessionSnapshot> | undefined {
  const payload = event.payload as any;
  if (event.topic === "session.snapshot") return payload;
  if (event.topic === "session.rebaseline") return payload?.snapshot;
  if (event.topic === "session.transcriptDelta") return payload?.data?.snapshot;
  return undefined;
}
