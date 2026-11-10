import { join } from "node:path";
import { ModelRuntime } from "../kernel/pi/coding-agent.js";
import { installAnthropicFullContext } from "./anthropic-full-context.js";
import { installClaudeCodeIdentity } from "./claude-code-identity.js";
import { installKimiK3Policy } from "./kimi-k3-policy.js";
import { applyJevModelPricing } from "./jev-model-pricing.js";

export async function createProviderModelRuntime(agentDir: string, create?: () => Promise<ModelRuntime>): Promise<ModelRuntime> {
  return applyJevModelPricing(installAnthropicFullContext(installClaudeCodeIdentity(installKimiK3Policy(await (create ?? (() => ModelRuntime.create({
    authPath: join(agentDir, "auth.json"),
    modelsPath: join(agentDir, "models.json"),
    modelsStorePath: join(agentDir, "models-store.json"),
    refreshOnCreate: true,
    allowModelNetwork: false,
  })))()))));
}
