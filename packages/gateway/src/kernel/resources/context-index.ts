interface ContextIndex {
  name: string;
  open: string;
  kind: "procedure" | "data" | "tool";
  items: ReadonlyArray<{ id: string; description: string; locator: string }>;
  budget: number;
}

const collapse = (text: string) => text.replace(/\s+/gu, " ").trim();
export const escapeIndexValue = (text: string) => collapse(text).replace(/&/gu, "&amp;").replace(/</gu, "&lt;").replace(/>/gu, "&gt;").replace(/"/gu, "&quot;");

export function renderIndex(index: ContextIndex, more?: string): { text: string; diagnostics: string[] } {
  const diagnostics: string[] = [];
  const rows = [...index.items].sort((left, right) => left.id < right.id ? -1 : left.id > right.id ? 1 : 0).map(item => {
    if (collapse(item.description).length > 160) diagnostics.push(`${index.name}/${item.id}: description exceeds 160 characters`);
    const description = escapeIndexValue(item.description);
    return `- ${escapeIndexValue(item.id)}:${description ? ` ${description}` : ""} | ${escapeIndexValue(item.locator)}`;
  });
  const render = (kept: readonly string[]) => [`<index name="${escapeIndexValue(index.name)}" open="${escapeIndexValue(index.open)}" kind="${index.kind}">`, ...kept,
    ...(kept.length < rows.length ? [`- more: List the remaining items. | ${escapeIndexValue(more!)}`] : []), "</index>"].join("\n");
  let kept = rows.length;
  while (more !== undefined && kept > 0 && Buffer.byteLength(render(rows.slice(0, kept))) > index.budget) kept -= 1;
  const text = render(rows.slice(0, kept));
  if (Buffer.byteLength(text) > index.budget) diagnostics.push(`${index.name}: index exceeds ${index.budget} bytes`);
  return { text, diagnostics };
}

export function skillsIndex(skills: ReadonlyArray<{ name: string; description: string; filePath: string; disableModelInvocation: boolean }>, open: string) {
  const items = skills.filter(skill => !skill.disableModelInvocation).map(skill => ({ id: skill.name, description: skill.description, locator: skill.filePath }));
  return items.length === 0 ? { text: "", diagnostics: [] } : renderIndex({ name: "skills", open, kind: "procedure", budget: 10_000, items });
}

const DOCS = [
  ["extensions", "extensions"], ["themes", "themes"], ["skills", "skills"], ["prompt-templates", "prompt templates"], ["tui", "TUI components"],
  ["keybindings", "keybindings"], ["sdk", "SDK integrations"], ["custom-provider", "custom providers"], ["models", "adding models"],
  ["packages", "packages"], ["environment-variables", "environment variables"], ["mcp", "MCP servers"],
  ["codemode", "codemode scripts and non-LLM models such as classifiers and image models"],
] as const;

export function docsIndex(paths: { readme: string; docs: string; examples: string }): string {
  const items = [
    { id: "readme", description: "Main documentation", locator: paths.readme },
    { id: "docs", description: "Additional docs", locator: paths.docs },
    { id: "examples", description: "Examples (extensions, custom tools, SDK)", locator: paths.examples },
    ...DOCS.map(([id, description]) => ({ id, description, locator: `${paths.docs}/${id}.md` })),
  ];
  return ["Pi documentation (read only when the user asks about the harness itself, its SDK, extensions, themes, skills, or TUI):",
    renderIndex({ name: "docs", open: "read", kind: "data", budget: 4_096, items }).text,
    "Before implementing harness changes, read the relevant docs and examples in full, following related cross-references."].join("\n");
}

export function mcpServersIndex(servers: ReadonlyArray<{ namespace: string; reach: "codemode" | "tool_search"; summary: string }>, intro: string): string | undefined {
  if (servers.length === 0) return undefined;
  const items = servers.map(server => ({ id: server.namespace, description: server.summary, locator: server.reach }));
  return `${intro}\n${renderIndex({ name: "mcp_servers", open: "codemode", kind: "data", budget: 4_096, items }, "searchTools()").text}`;
}
