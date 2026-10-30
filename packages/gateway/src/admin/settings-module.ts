import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { createTronSettingsExtension } from "./tron-settings-extension.js";

/** The settings owner is late-bound by the current session at every tool call. */
export const settingsModule: ModuleDescriptor = {
  name: "tron-settings",
  purpose: "Lets the agent read and change settings through the one logged change path, and marks a run that read web content.",
  tools: ["settings"],
  commands: [],
  start: () => ({ extension: (session) => createTronSettingsExtension(() => session.settings(), session.requestChange) }),
};
