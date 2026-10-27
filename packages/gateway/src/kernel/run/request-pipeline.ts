import { AsyncLocalStorage } from "node:async_hooks";
import type { AgentSession, ModelRuntime, SettingsManager } from "../pi/coding-agent.js";
import type { StreamFn } from "../pi/agent-core.js";
import { installAgentPipeline, wrapModelRuntimeStream, type AgentPipelineStages } from "../pi/adapters.js";
import { lazyStream, type AssistantMessageEvent, type AssistantMessageEventStream } from "../pi/ai.js";

async function* abortAwareEvents(
  source: AssistantMessageEventStream,
  signal: AbortSignal,
): AsyncIterable<AssistantMessageEvent> {
  for await (const event of source) {
    // Request setup can reject before a provider sees the signal. The pinned
    // SDK's lazy stream labels that as an ordinary error, which would authorize
    // post-run retry/compaction of a cancelled turn. Use the request's signal,
    // never error-message matching, and preserve successful terminal results.
    if (event.type === "error" && signal.aborted) {
      yield { ...event, reason: "aborted", error: { ...event.error, stopReason: "aborted" } };
    } else {
      yield event;
    }
  }
}

/** One AgentSession boundary, shared by ordinary responses and summarization. */
export function abortAwareStream(stream: StreamFn): StreamFn {
  return (model, context, options) => {
    const signal = options?.signal;
    if (!signal) return stream(model, context, options);
    // Keep both synchronous and asynchronous setup failures inside the SDK's
    // stream contract before correcting their cancellation classification.
    const source = lazyStream(model, async () => stream(model, context, options));
    return lazyStream(model, async () => ({
      [Symbol.asyncIterator]: () => abortAwareEvents(source, signal)[Symbol.asyncIterator](),
      // Agent-core also accepts a stream that ends with only result(), without
      // a terminal event. Preserve that contract for custom providers.
      result: async () => {
        const message = await source.result();
        return message.stopReason === "error" && signal.aborted
          ? { ...message, stopReason: "aborted" as const }
          : message;
      },
    }));
  };
}

type RequestSettings = ReturnType<SettingsManager["getSettings"]>;

export interface RunRequestPipelineOptions {
  applySettings(): Promise<RequestSettings | undefined>;
  settingsApplied(): void;
  compactionStream(stream: StreamFn): StreamFn;
  policyStream?: (stream: StreamFn) => StreamFn;
  outer?: AgentPipelineStages["outer"];
  finishTurn?: AgentPipelineStages["finishTurn"];
}

/** One runtime's provider cut and request stages share the same settings scope. */
export class RunRequestPipeline {
  private readonly requestSettings = new AsyncLocalStorage<RequestSettings>();

  constructor(modelRuntime: ModelRuntime) {
    // The SDK merges initial optional defaults after agent.streamFunction.
    // Carry this exact request's resolved settings to the final provider cut:
    // clearing a Chat/Global value must not resurrect that stale SDK default.
    // Ordinary runtimes and Home's borrowed *view* are session-owned; unrelated
    // memory/extension calls outside this stream retain their explicit options.
    wrapModelRuntimeStream(modelRuntime, (streamSimple) => (model, context, options) => {
      const settings = this.requestSettings.getStore();
      if (!settings) return streamSimple(model, context, options);
      const { timeoutMs: _timeout, maxRetries: _retries, websocketConnectTimeoutMs: _connect, ...rest } = options ?? {};
      // Pi settings spell a disabled timeout "disabled" (or 0). As the SDK's own
      // request options do, a disabled HTTP timeout is the maximum int32 the
      // provider SDKs accept, and a disabled WebSocket connect wait is 0.
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
        // Image filtering happens during SDK message conversion, before
        // prepareRequest. Resolve here too, so a tool's narrowing applies to
        // the very next request rather than leaking one request of images.
        await options.applySettings();
        return convertToLlm(messages);
      },
      prepareRequest: (prepareRequest) => async (request, signal) => {
        if (signal?.aborted) throw new Error("Request cancelled before settings resolution");
        admittedSettings = await options.applySettings();
        if (signal?.aborted) throw new Error("Request cancelled during settings resolution");
        options.settingsApplied();
        return (await prepareRequest?.(request, signal)) ?? undefined;
      },
      // The guard is INNERMOST, so it validates the exact request the
      // provider-facing base stream receives: after `abortAwareStream` and after
      // the compaction policy's summary-focus rewrite. Installed outermost, it
      // would run before both and never see them.
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
        return options.compactionStream(abortAwareStream(options.policyStream ? options.policyStream(baseStream) : baseStream));
      },
      ...(options.outer ? { outer: options.outer } : {}),
      ...(options.finishTurn ? { finishTurn: options.finishTurn } : {}),
    });
  }
}
