import { AsyncLocalStorage } from "node:async_hooks";
import type { AgentSession, ModelRuntime, SettingsManager } from "../pi/coding-agent.js";
import type { StreamFn } from "../pi/agent-core.js";
import { installAgentPipeline, wrapModelRuntimeStream, type AgentPipelineStages } from "../pi/adapters.js";
import { getSystemMessageText, lazyStream, type AssistantMessageEvent, type AssistantMessageEventStream, type Context } from "../pi/ai.js";
import { recordingStream, type RequestOutcome } from "./request-record.js";
import { projectInjectedMessages } from "../host/injected-text.js";
import { turnFrameStream, type TurnFrameSource } from "./turn-frame.js";

async function* abortAwareEvents(
  source: AssistantMessageEventStream,
  signal: AbortSignal,
): AsyncIterable<AssistantMessageEvent> {
  for await (const event of source) {
    if (event.type === "error" && signal.aborted) {
      yield { ...event, reason: "aborted", error: { ...event.error, stopReason: "aborted" } };
    } else {
      yield event;
    }
  }
}

export function abortAwareStream(stream: StreamFn): StreamFn {
  return (model, context, options) => {
    const signal = options?.signal;
    if (!signal) return stream(model, context, options);
    const source = lazyStream(model, async () => stream(model, context, options));
    return lazyStream(model, async () => ({
      [Symbol.asyncIterator]: () => abortAwareEvents(source, signal)[Symbol.asyncIterator](),
      result: async () => {
        const message = await source.result();
        return message.stopReason === "error" && signal.aborted
          ? { ...message, stopReason: "aborted" as const }
          : message;
      },
    }));
  };
}

const SHARED_SECTIONS = new Set(["preamble", "role", "tools", "rules", "docs", "addendum", "global_context", "skills"]);

function sharedPrefix(context: Context): string | undefined {
  const system = context.messages[0];
  if (system?.role !== "system" || !system.sections) return undefined;
  const sections: Record<string, string | null> = {};
  for (const [name, text] of Object.entries(system.sections)) {
    if (!SHARED_SECTIONS.has(name)) return getSystemMessageText({ ...system, sections });
    sections[name] = text;
  }
  return undefined;
}

function markSharedPrefix(payload: unknown, prefix: string): unknown {
  if (typeof payload !== "object" || payload === null || !Array.isArray((payload as { system?: unknown }).system)) return payload;
  const system = (payload as { system: Array<Record<string, unknown>> }).system;
  const at = system.findLastIndex(block => typeof block.text === "string" && block.cache_control !== undefined);
  const block = system[at];
  if (!block || !(block.text as string).startsWith(`${prefix}\n\n`)) return payload;
  const { cache_control: control, ...rest } = block;
  return { ...payload, system: [...system.slice(0, at), { ...rest, text: prefix, cache_control: control },
    { ...rest, text: (block.text as string).slice(prefix.length + 2) }, ...system.slice(at + 1)] };
}

function sharedPrefixStream(stream: StreamFn): StreamFn {
  return (model, context, options) => {
    const prefix = model.api === "anthropic-messages" ? sharedPrefix(context) : undefined;
    if (prefix === undefined) return stream(model, context, options);
    return stream(model, context, {
      ...options,
      onPayload: async (payload, requestModel) => {
        const next = await options?.onPayload?.(payload, requestModel);
        return markSharedPrefix(next === undefined ? payload : next, prefix);
      },
    });
  };
}

type RequestSettings = ReturnType<SettingsManager["getSettings"]>;

interface RunRequestPipelineOptions {
  applySettings(): Promise<RequestSettings | undefined>;
  settingsApplied(): void;
  compactionStream(stream: StreamFn): StreamFn;
  policyStream?: (stream: StreamFn) => StreamFn;
  frame: TurnFrameSource;
  record?: (outcome: RequestOutcome) => void;
  outer?: AgentPipelineStages["outer"];
  finishTurn?: AgentPipelineStages["finishTurn"];
}

export class RunRequestPipeline {
  private readonly requestSettings = new AsyncLocalStorage<RequestSettings>();

  constructor(modelRuntime: ModelRuntime) {
    wrapModelRuntimeStream(modelRuntime, (streamSimple) => (model, context, options) => {
      const settings = this.requestSettings.getStore();
      if (!settings) return streamSimple(model, context, options);
      const { timeoutMs: _timeout, maxRetries: _retries, websocketConnectTimeoutMs: _connect, ...rest } = options ?? {};
      const idle = settings.httpIdleTimeoutMs === "disabled" ? 0 : settings.httpIdleTimeoutMs;
      const timeoutMs = settings.retry?.provider?.timeoutMs ?? (idle === 0 ? 2_147_483_647 : idle);
      const connect = settings.websocketConnectTimeoutMs === "disabled" ? 0 : settings.websocketConnectTimeoutMs;
      return streamSimple(model, context, {
        ...rest,
        ...(timeoutMs === undefined ? {} : { timeoutMs }),
        ...(settings.retry?.provider?.maxRetries === undefined ? {} : { maxRetries: settings.retry.provider.maxRetries }),
        ...(connect === undefined ? {} : { websocketConnectTimeoutMs: connect }),
      });
    });
  }

  install(session: AgentSession, options: RunRequestPipelineOptions): void {
    let admittedSettings: RequestSettings | undefined;
    installAgentPipeline(session.agent, {
      convertToLlm: (convertToLlm) => async messages => {
        await options.applySettings();
        return convertToLlm(projectInjectedMessages(messages, session.sessionFile));
      },
      prepareRequest: (prepareRequest) => async (request, signal) => {
        if (signal?.aborted) throw new Error("Request cancelled before settings resolution");
        admittedSettings = await options.applySettings();
        if (signal?.aborted) throw new Error("Request cancelled during settings resolution");
        options.settingsApplied();
        return (await prepareRequest?.(request, signal)) ?? undefined;
      },
      streamFunction: (providerStream) => {
        const baseStream: StreamFn = (model, context, streamOptions) => {
          const settings = admittedSettings;
          if (!settings) return providerStream(model, context, streamOptions);
          return this.requestSettings.run(settings, () => providerStream(model, context, {
            ...streamOptions,
            ...(settings.transport === undefined ? {} : { transport: settings.transport }),
            ...(settings.retry?.provider?.maxRetryDelayMs === undefined ? {} : { maxRetryDelayMs: settings.retry.provider.maxRetryDelayMs }),
          }));
        };
        const framed = turnFrameStream(options.frame, baseStream);
        const sent = abortAwareStream(options.policyStream ? options.policyStream(framed) : framed);
        return options.compactionStream(sharedPrefixStream(options.record ? recordingStream(sent, options.record) : sent));
      },
      ...(options.outer ? { outer: options.outer } : {}),
      ...(options.finishTurn ? { finishTurn: options.finishTurn } : {}),
    });
  }
}
