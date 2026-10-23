import { join } from "node:path";
import { ModelRuntime } from "../kernel/pi/coding-agent.js";
import { installKimiK3Policy } from "./kimi-k3-policy.js";
import { applyJevModelPricing } from "./jev-model-pricing.js";

/** Canonical provider defaults and policy order for Gateway and session runtimes. */
export async function createProviderModelRuntime(agentDir: string, create?: () => Promise<ModelRuntime>): Promise<ModelRuntime> {
  return applyJevModelPricing(installKimiK3Policy(await (create ?? (() => ModelRuntime.create({
    authPath: join(agentDir, "auth.json"),
    modelsPath: join(agentDir, "models.json"),
    modelsStorePath: join(agentDir, "models-store.json"),
    refreshOnCreate: true,
    allowModelNetwork: false,
  })))()));
}
