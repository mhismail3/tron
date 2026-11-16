const isFrame = (content: unknown): boolean => typeof content === "string" ? content.startsWith("<turn-frame>")
  : Array.isArray(content) && content.length === 1 && isFrame((content[0] as { text?: unknown }).text);

export function withoutTurnFrame<T extends { role: string; content?: unknown }>(messages: readonly T[]): T[] {
  const last = messages.at(-1);
  return last?.role === "user" && isFrame(last.content) ? messages.slice(0, -1) : [...messages];
}
