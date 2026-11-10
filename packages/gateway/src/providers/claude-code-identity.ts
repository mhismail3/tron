import type { ModelRuntime } from "../kernel/pi/coding-agent.js";
import identity from "./claude-code-identity.json" with { type: "json" };

export const CLAUDE_CODE_VERSION: string = identity.version;

const installed = new WeakSet<ModelRuntime>();

export function installClaudeCodeIdentity(runtime: ModelRuntime): ModelRuntime {
  if (installed.has(runtime)) return runtime;
  installed.add(runtime);
  const stream = runtime.streamSimple.bind(runtime);
  runtime.streamSimple = ((model, context, options) => {
    if (model.provider !== "anthropic" || model.api !== "anthropic-messages" || options?.apiKey !== undefined || !runtime.isUsingOAuth("anthropic")) {
      return stream(model, context, options);
    }
    return stream(model, context, { ...options, headers: { ...options?.headers, "user-agent": `claude-cli/${CLAUDE_CODE_VERSION}` } });
  }) as ModelRuntime["streamSimple"];
  return runtime;
}
