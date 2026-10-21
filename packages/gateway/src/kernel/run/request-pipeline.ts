import { AsyncLocalStorage } from "node:async_hooks";
import type { AgentSession, ModelRuntime, SettingsManager } from "../pi/coding-agent.js";
import type { StreamFn } from "../pi/agent-core.js";
import { installAgentPipeline, wrapModelRuntimeStream, type AgentPipelineStages } from "../pi/adapters.js";
import { abortAwareStream } from "../../runtime/abort-aware-stream.js";

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
    // clearing a Chat/Mac value must not resurrect that stale SDK default.
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
