import type { StreamFn } from "@earendil-works/pi-agent-core";
import { lazyStream, type AssistantMessageEvent, type AssistantMessageEventStream } from "@earendil-works/pi-ai";

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
