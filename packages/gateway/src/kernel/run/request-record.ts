import { createHash, createHmac, randomBytes } from "node:crypto";
import type { StreamFn } from "../pi/agent-core.js";

export interface RequestPrefix {
  bytes: number;
  hash: string;
}

export interface RequestLayers {
  hashKey: string;
  params: RequestPrefix;
  tools: RequestPrefix;
  system: RequestPrefix[];
  request: RequestPrefix;
  marks: Array<RequestPrefix & { at: string; ttl: string }>;
}

export interface RequestOutcome extends RequestLayers {
  provider: string;
  model: string;
  api: string;
  stop: string;
  usage: { input: number; cacheRead: number; cacheWrite: number; output: number };
}

export interface RequestRecord extends RequestOutcome {
  sessionId: string;
  kind: string;
}

type Json = Record<string, unknown>;

const SYSTEM_FIELDS = ["system", "instructions", "systemInstruction"] as const;
const CONVERSATION_FIELDS = ["messages", "input", "contents"] as const;
const LAYER_FIELDS: ReadonlySet<string> = new Set(["tools", ...SYSTEM_FIELDS, ...CONVERSATION_FIELDS]);
const PROCESS_KEY = randomBytes(32);
const PROCESS_KEY_ID = randomBytes(4).toString("hex");

function isObject(value: unknown): value is Json {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requestUnits(key: string, value: unknown): Array<{ at: string; unit: unknown }> {
  if (value === undefined) return [];
  if (!Array.isArray(value)) return [{ at: `.${key}`, unit: value }];
  return value.flatMap((item, index) => {
    const at = `.${key}[${index}]`;
    if (!isObject(item) || !Array.isArray(item.content)) return [{ at, unit: item }];
    const { content, ...envelope } = item;
    return [{ at, unit: envelope }, ...content.map((block, part) => ({ at: `${at}.content[${part}]`, unit: block }))];
  });
}

export function requestLayers(payload: unknown): RequestLayers {
  const body = isObject(payload) ? payload : {};
  const keyed = (digest: Buffer) => createHmac("sha256", PROCESS_KEY).update(digest).digest("hex").slice(0, 16);
  const hash = createHash("sha256");
  let bytes = 0;
  const marks: RequestLayers["marks"] = [];
  const prefix = (): RequestPrefix => ({ bytes, hash: keyed(hash.copy().digest()) });
  const add = (key: string, each?: (prefix: RequestPrefix) => void): void => {
    for (const { at, unit } of requestUnits(key, body[key])) {
      const { cache_control: control, ...rest } = isObject(unit) ? unit : { value: unit };
      const json = JSON.stringify(isObject(unit) ? rest : unit);
      hash.update(json);
      bytes += Buffer.byteLength(json);
      if (isObject(control)) marks.push({ at, ttl: typeof control.ttl === "string" ? control.ttl : "5m", ...prefix() });
      each?.(prefix());
    }
  };
  add("tools");
  const tools = prefix();
  const system: RequestPrefix[] = [];
  for (const key of SYSTEM_FIELDS) add(key, block => system.push(block));
  for (const key of CONVERSATION_FIELDS) add(key);
  const rest = JSON.stringify(Object.fromEntries(Object.entries(body).filter(([key]) => !LAYER_FIELDS.has(key)).sort(([left], [right]) => left < right ? -1 : 1)));
  const params = { bytes: Buffer.byteLength(rest), hash: keyed(createHash("sha256").update(rest).digest()) };
  return { hashKey: PROCESS_KEY_ID, params, tools, system, request: prefix(), marks };
}

export function recordingStream(stream: StreamFn, record: (outcome: RequestOutcome) => void): StreamFn {
  return (model, context, options) => {
    let layers: RequestLayers | undefined;
    const result = stream(model, context, {
      ...options,
      onPayload: async (payload, requestModel) => {
        const next = await options?.onPayload?.(payload, requestModel);
        try { layers = requestLayers(next === undefined ? payload : next); } catch { layers = undefined; }
        return next;
      },
    });
    void Promise.resolve(result).then(events => events.result()).then(message => {
      if (!layers) return;
      const usage = message.usage;
      record({
        ...layers, provider: model.provider, model: model.id, api: model.api, stop: message.stopReason,
        usage: { input: usage.input, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite, output: usage.output },
      });
    }).catch(() => {});
    return result;
  };
}
