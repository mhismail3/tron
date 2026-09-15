import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

export const TRON_CHILD_BOOTSTRAP_PROMPT_ENV = "TRON_CHILD_BOOTSTRAP_PROMPT";

/**
 * Native children are separate Pi runtimes. This prompt-only extension carries
 * Tron ownership/context without granting Gateway tools or services.
 */
export function createTronChildBootstrapExtension(): ExtensionFactory {
  return (pi) => {
    pi.on("before_agent_start", (event) => {
      const prompt = process.env[TRON_CHILD_BOOTSTRAP_PROMPT_ENV]?.trim();
      if (!prompt) return;
      return { systemPrompt: `${event.systemPrompt}\n\n${prompt}` };
    });
  };
}

// The SDK CLI loads a default factory; the named constructor also serves embeds.
export default createTronChildBootstrapExtension();
