import type { ModelRuntime } from "../kernel/pi/coding-agent.js";

const installed = new WeakSet<ModelRuntime>();

/**
 * Every Anthropic Messages request carries its full context. Pi continues a server-side
 * message thread by default on Anthropic's own endpoint and then sends only the messages after
 * the previous reply; Tron keeps threads off for chats, Home and workers alike. Turning
 * `supportsMessageThreads` off on the request's model leaves Pi's request exactly as without
 * threads: no `thread` field and no threads beta. Every Gateway Anthropic Messages request, including the
 * SDK's cache-warm requests, goes through this runtime's `stream` or `streamSimple`.
 */
export function installAnthropicFullContext(runtime: ModelRuntime): ModelRuntime {
  if (installed.has(runtime)) return runtime;
  installed.add(runtime);
  const fullContext = <T extends { api: string; compat?: unknown }>(model: T): T => model.api !== "anthropic-messages"
    ? model
    : { ...model, compat: { ...(model.compat as object | undefined), supportsMessageThreads: false } };
  const streamSimple = runtime.streamSimple.bind(runtime);
  runtime.streamSimple = ((model, context, options) => streamSimple(fullContext(model), context, options)) as ModelRuntime["streamSimple"];
  const stream = runtime.stream.bind(runtime);
  runtime.stream = ((model, context, options) => stream(fullContext(model), context, options)) as ModelRuntime["stream"];
  return runtime;
}
