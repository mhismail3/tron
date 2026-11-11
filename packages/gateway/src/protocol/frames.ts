import * as P from "./types.js";

type Encoder = (value: never) => string;
export type FrameShape = Encoder | readonly [FrameShape] | { readonly [key: string]: FrameShape };

const emitted = (data: FrameShape): FrameShape => ({ data });

const EVENT_PAYLOADS: Readonly<Record<string, FrameShape>> = {
  "session.snapshot": P.encodeSessionSnapshot,
  "session.rebaseline": { snapshot: P.encodeSessionSnapshot },
  "session.progress": emitted({ message: P.encodeTranscriptItem }),
  "session.toolProgress": emitted(P.encodeToolExecutionState),
  "session.extensionPresentation": emitted(P.encodeExtensionPresentationMutation),
};

const RESPONSE_RESULTS: Readonly<Record<string, FrameShape>> = {
  "session.open": { session: P.encodeSessionSnapshot },
  "session.transcript": { items: [P.encodeTranscriptItem] },
  "session.list": { sessions: [P.encodeSessionSummary] },
  "session.tree": [P.encodeSessionTreeNode],
  "session.history.list": { nodes: [P.encodeSessionTreeNode] },
  "session.commands": { commands: [P.encodeCommandInfo] },
};

function encodeShaped(value: unknown, shape: FrameShape | undefined): string | undefined {
  if (shape === undefined || value === undefined || value === null) return JSON.stringify(value);
  if (typeof shape === "function") return shape(value as never);
  if (Array.isArray(shape)) {
    if (!Array.isArray(value)) return JSON.stringify(value);
    return "[" + value.map((item) => encodeShaped(item, shape[0]) ?? "null").join(",") + "]";
  }
  if (typeof value !== "object" || Array.isArray(value)) return JSON.stringify(value);
  const fields = shape as { readonly [key: string]: FrameShape };
  let out = "";
  for (const [key, member] of Object.entries(value)) {
    const encoded = encodeShaped(member, Object.hasOwn(fields, key) ? fields[key] : undefined);
    if (encoded !== undefined) out += "," + JSON.stringify(key) + ":" + encoded;
  }
  return "{" + out.slice(1) + "}";
}

export const SHAPED_FRAME_KINDS: readonly string[] = [
  ...Object.keys(EVENT_PAYLOADS).map((topic) => `event ${topic}`),
  ...Object.keys(RESPONSE_RESULTS).map((method) => `response ${method}`),
];

export function frameShape(frame: unknown, method?: string): FrameShape | undefined {
  if (typeof frame !== "object" || frame === null) return undefined;
  const { type, topic, ok } = frame as { type?: unknown; topic?: unknown; ok?: unknown };
  if (type === "event" && typeof topic === "string" && Object.hasOwn(EVENT_PAYLOADS, topic)) return { payload: EVENT_PAYLOADS[topic]! };
  if (type === "response" && ok === true && method !== undefined && Object.hasOwn(RESPONSE_RESULTS, method)) return { result: RESPONSE_RESULTS[method]! };
  return undefined;
}

export function encodeFrame(frame: unknown, method?: string): string | undefined {
  return encodeShaped(frame, frameShape(frame, method));
}
