const FRAME = "<turn-frame>";
type Shape = { role?: unknown; content?: unknown; text?: unknown };
const blocks = (message: Shape): unknown[] => typeof message.content === "string" ? [message.content]
  : Array.isArray(message.content) ? message.content : typeof message.text === "string" ? [message.text] : [];
const text = (block: unknown) => typeof block === "string" ? block : (block as { text?: unknown } | null)?.text;
const holdsFrame = (message: Shape) => blocks(message).some(block => typeof text(block) === "string" && (text(block) as string).startsWith(FRAME));
const isFrame = (message: Shape) => message.role === "user" && blocks(message).length === 1 && holdsFrame(message);

export function withoutTurnFrame<T>(messages: readonly T[], framed = true): T[] {
  const holders = messages.flatMap((message, index) => holdsFrame(message as Shape) ? [index] : []);
  if (!framed) {
    if (holders.length > 0) throw new Error(`expected no turn frame in a non-turn request, found ${holders.length} at ${JSON.stringify(holders)}`);
    return [...messages];
  }
  if (holders.length !== 1 || holders[0] !== messages.length - 1 || !isFrame(messages.at(-1) as Shape)) {
    throw new Error(`expected exactly one trailing request-only turn frame, found ${holders.length} at ${JSON.stringify(holders)} of ${messages.length}`);
  }
  return messages.slice(0, -1);
}

export function droppingAnyTurnFrame<T>(messages: readonly T[]): T[] {
  return messages.length > 0 && isFrame(messages.at(-1) as Shape) ? messages.slice(0, -1) : [...messages];
}
