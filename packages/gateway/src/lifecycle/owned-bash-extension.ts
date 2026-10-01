import { SettingsManager, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { DirectBashProcessOwner } from "../sessions/direct-bash-process-owner.js";

/** Host infrastructure supplied explicitly to child Pi launches. Replaces only
 * execution; Pi retains tool rendering, truncation, context and shell settings. */
export default function ownedBashExtension(pi: ExtensionAPI): void {
  const cwd = process.cwd();
  const owner = new DirectBashProcessOwner(SettingsManager.create(cwd));
  pi.registerTool(owner.toolDefinition(cwd));
  pi.on("user_bash", () => ({ operations: owner.operations() }));
}
