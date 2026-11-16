interface ContextIndex {
  name: string;
  open: string;
  kind: "procedure" | "data" | "tool";
  items: ReadonlyArray<{ id: string; description: string; locator: string }>;
  budget: number;
}

const collapse = (text: string) => text.replace(/\s+/gu, " ").trim();
export const escapeIndexValue = (text: string) => collapse(text).replace(/&/gu, "&amp;").replace(/</gu, "&lt;").replace(/>/gu, "&gt;").replace(/"/gu, "&quot;");

export function renderIndex(index: ContextIndex): { text: string; diagnostics: string[] } {
  const diagnostics: string[] = [];
  const rows = [...index.items].sort((left, right) => left.id < right.id ? -1 : left.id > right.id ? 1 : 0).map(item => {
    if (collapse(item.description).length > 160) diagnostics.push(`${index.name}/${item.id}: description exceeds 160 characters`);
    return `- ${escapeIndexValue(item.id)}: ${escapeIndexValue(item.description)} | ${escapeIndexValue(item.locator)}`;
  });
  const text = [`<index name="${escapeIndexValue(index.name)}" open="${escapeIndexValue(index.open)}" kind="${index.kind}">`, ...rows, "</index>"].join("\n");
  if (Buffer.byteLength(text) > index.budget) diagnostics.push(`${index.name}: index exceeds ${index.budget} bytes`);
  return { text, diagnostics };
}

export function skillsIndex(skills: ReadonlyArray<{ name: string; description: string; filePath: string; disableModelInvocation: boolean }>, open: string) {
  const items = skills.filter(skill => !skill.disableModelInvocation).map(skill => ({ id: skill.name, description: skill.description, locator: skill.filePath }));
  return items.length === 0 ? { text: "", diagnostics: [] } : renderIndex({ name: "skills", open, kind: "procedure", budget: 10_000, items });
}
