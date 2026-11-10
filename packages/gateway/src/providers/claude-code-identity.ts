import type { ModelRuntime } from "../kernel/pi/coding-agent.js";
import identity from "./claude-code-identity.json" with { type: "json" };

/**
 * The Claude Code version Tron claims on Claude subscription requests. Anthropic gates
 * newer models on it (Fable 5.2 needs 2.1.290 or later), so Tron owns it instead of
 * inheriting the one Pi hardcodes. `scripts/tron provider-smoke` reads the same JSON and
 * fails when the server's floor passes it; raise it to the current
 * `@anthropic-ai/claude-code` release then.
 */
export const CLAUDE_CODE_VERSION: string = identity.version;

const installed = new WeakSet<ModelRuntime>();

/**
 * Send `user-agent: claude-cli/<CLAUDE_CODE_VERSION>` on built-in `anthropic` requests that
 * use the stored OAuth login. Pi merges request headers over its own Claude Code identity
 * in OAuth mode, so this replaces only the version. API-key logins and requests that bring
 * their own key keep Pi's headers.
 */
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
