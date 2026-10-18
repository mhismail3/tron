/** The executable ceiling and unconfigured tool selection for Home's isolated
 * runtime. Shared by runtime admission and settings declarations: ordinary Mac
 * tool defaults cannot grant or remove Home's curated capabilities. */
export const HOME_TOOL_NAMES: readonly string[] = [
  "ask_user", "display", "notify", "zoom", "date", "memory_search", "delegate", "task", "profile",
  "web_search", "web_fetch", "session_search", "session_read", "knowledge", "read_file", "settings",
];
