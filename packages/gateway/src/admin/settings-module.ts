import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { createTronSettingsExtension } from "./tron-settings-extension.js";
import { settingsGuidePath } from "../kernel/settings/settings-guide.js";

export const settingsModule: ModuleDescriptor = {
  name: "tron-settings",
  purpose: "Lets the agent read and change settings through the one logged change path, and marks a run that read web content.",
  tools: ["settings"],
  commands: [],
  start: host => ({ extension: (session) => createTronSettingsExtension(() => session.settings(), session.requestChange, settingsGuidePath(host.tronHome)) }),
};
