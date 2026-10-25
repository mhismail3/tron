import type { RuntimeSlot } from "../../kernel/run/runtime-slot.js";

/** The executable ceiling and unconfigured tool selection for Home's isolated
 * runtime. Shared by runtime admission and settings declarations: ordinary Mac
 * tool defaults cannot grant or remove Home's curated capabilities. */
export const HOME_TOOL_NAMES: readonly string[] = [
  "ask_user", "display", "notify", "zoom", "date", "memory_search", "delegate", "task", "profile",
  "web_search", "session_search", "session_read", "knowledge", "read_file", "settings",
];

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
