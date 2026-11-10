import type { ModelRuntime } from "../kernel/pi/coding-agent.js";

const installed = new WeakSet<ModelRuntime>();

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
