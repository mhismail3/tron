import type { RuntimeSlot } from "../../kernel/run/runtime-slot.js";

/** The executable ceiling and unconfigured tool selection for Home's isolated
 * runtime. Shared by runtime admission and settings declarations: ordinary Mac
 * tool defaults cannot grant or remove Home's curated capabilities. */
export const HOME_TOOL_NAMES: readonly string[] = [
  "ask_user", "display", "notify", "zoom", "date", "memory_search", "delegate", "task", "schedule", "profile",
  "web_search", "session_search", "session_read", "knowledge", "settings", "projects",
  "read", "write", "edit", "bash", "grep", "find", "ls",
];

const WAKE_READ_TOOLS = new Set(["read", "grep", "find", "ls", "ask_user", "display", "zoom", "date", "memory_search", "web_search", "session_search", "session_read", "knowledge"]);
const WAKE_READ_ACTIONS: Readonly<Record<string, readonly string[]>> = {
  task: ["list", "status", "report"],
  settings: ["resolve"],
  profile: ["list", "read"],
  schedule: ["list", "show"],
};

/** Admission uses the canonical activation, never a retrieved instruction or a
 * remembered user turn. Unknown tools fail closed on unattended wakes. */
export function homeToolAvailable(name: string, kind: "user" | "wake" | undefined): boolean {
  return kind === "user" || (kind === "wake" && (WAKE_READ_TOOLS.has(name) || Object.hasOwn(WAKE_READ_ACTIONS, name)));
}

export function homeToolAllowed(name: string, input: Record<string, unknown>, kind: "user" | "wake" | undefined): boolean {
  return homeToolAvailable(name, kind) && (kind === "user" || WAKE_READ_TOOLS.has(name)
    || WAKE_READ_ACTIONS[name]?.includes(String(input.action)) === true);
}

/** Select descriptions from the first native lineage member, never loading a
 * runtime for this read. Native map keys/order, not chapter order, govern it. */
export function homeToolCatalog(
  runtimes: ReadonlyArray<readonly [string, Pick<RuntimeSlot, "isDisposed" | "settingsToolCatalog">]>,
  isLineageMember: (sessionId: string) => boolean,
): Array<{ name: string; description?: string; resource: Record<string, unknown> }> {
  const chapter = runtimes.find(([id, slot]) => !slot.isDisposed && isLineageMember(id))?.[1];
  const described = new Map((chapter?.settingsToolCatalog() ?? []).map(tool => [tool.name, tool.description]));
  return HOME_TOOL_NAMES.map(name => {
    const description = described.get(name);
    return { name, ...(description ? { description } : {}), resource: {} };
  });
}
