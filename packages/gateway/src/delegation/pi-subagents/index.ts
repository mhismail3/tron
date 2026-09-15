import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type {} from "./src/types/pi-runtime-compat.d.js";
import registerParentExtension from "./src/extension/index.js";

export interface TronSubagentRegistrationOptions {
  /** Bounded, non-secret ownership/context prompt inherited by native children. */
  childBootstrapPrompt?: string;
}

/** Tron loads this factory in the parent runtime; child Pi processes load the
 * same deterministic entrypoint but intentionally omit the parent tool. */
export default function registerTronSubagentExtension(pi: ExtensionAPI, options: TronSubagentRegistrationOptions = {}): void {
	if (process.env.PI_SUBAGENT_CHILD === "1") return;
	registerParentExtension(pi, { tronBootstrapPrompt: options.childBootstrapPrompt });
}
