export interface ContextIndex {
  name: string;
  open: string;
  kind: "procedure" | "data" | "tool";
  items: ReadonlyArray<{ id: string; description: string; locator: string }>;
  budget: number;
}

const collapse = (text: string) => text.replace(/\s+/gu, " ").trim();
const escape = (text: string) => collapse(text).replace(/&/gu, "&amp;").replace(/</gu, "&lt;").replace(/>/gu, "&gt;").replace(/"/gu, "&quot;");

export function renderIndex(index: ContextIndex): string {
  const rows = [...index.items].sort((left, right) => left.id < right.id ? -1 : left.id > right.id ? 1 : 0).map(item => {
    if (collapse(item.description).length > 160) throw new Error(`${index.name}/${item.id}: description exceeds 160 characters`);
    return `- ${escape(item.id)}: ${escape(item.description)} | ${escape(item.locator)}`;
  });
  const text = [`<index name="${escape(index.name)}" open="${escape(index.open)}" kind="${index.kind}">`, ...rows, "</index>"].join("\n");
  if (Buffer.byteLength(text) > index.budget) throw new Error(`${index.name}: index exceeds ${index.budget} bytes`);
  return text;
}
