import type { RuntimeSlot } from "../../kernel/run/runtime-slot.js";

export const HOME_TOOL_NAMES: readonly string[] = [
  "ask_user", "display", "notify", "zoom", "date", "memory_search", "delegate", "task", "schedule", "profile", "obligation",
  "web_search", "session_search", "session_read", "session_import", "settings", "projects",
  "read", "write", "edit", "bash", "grep", "find", "ls", "computer",
];

const MAINTAINER_TURN_TOOLS = new Set(["write", "edit", "bash", "computer"]);

export function homeToolAvailable(name: string, kind: "user" | "wake" | undefined): boolean {
  return HOME_TOOL_NAMES.includes(name) && (kind === "user" || !MAINTAINER_TURN_TOOLS.has(name));
}

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
