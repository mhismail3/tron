export const VIEW_BLOCK_LINES = 4;

export const VIEW_SETTLED_SPAN = 64;

export const ANTHROPIC_MAX_CACHE_BREAKPOINTS = 4;

type Json = Record<string, unknown>;

function isObject(value: unknown): value is Json {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function markAnthropicBlocks(payload: unknown, messageIndex: number, blocks: readonly number[]): unknown {
  if (!isObject(payload) || !Array.isArray(payload.messages) || blocks.length === 0) return payload;
  const target = payload.messages[messageIndex];
  if (!isObject(target) || !Array.isArray(target.content)) return payload;
  if (blocks.some((block) => !Number.isInteger(block) || block < 0 || block >= (target.content as unknown[]).length)) return payload;
  const control = existingControl(payload);
  if (control === undefined) return payload;

  const next = structuredClone(payload) as Json & { messages: Json[] };
  const content = next.messages[messageIndex]!.content as Json[];
  for (const index of blocks) {
    if (!isObject(content[index])) return payload;
    content[index]!.cache_control = structuredClone(control);
  }
  const system = Array.isArray(next.system) ? (next.system as unknown[]).filter(isObject) : [];
  const optional: Json[] = [
    ...(Array.isArray(next.tools) ? (next.tools as unknown[]).filter(isObject).reverse() : []),
    ...system.slice(0, -1),
    ...system.slice(-1),
  ].filter((item) => item.cache_control !== undefined);
  let total = countMarks(next);
  for (const item of optional) {
    if (total <= ANTHROPIC_MAX_CACHE_BREAKPOINTS) break;
    delete item.cache_control;
    total -= 1;
  }
  return total <= ANTHROPIC_MAX_CACHE_BREAKPOINTS ? next : payload;
}

export function shortenLastMessageMark(payload: unknown, after: number): unknown {
  if (!isObject(payload) || !Array.isArray(payload.messages)) return payload;
  const longLived = (block: unknown) => isObject(block) && isObject(block.cache_control) && block.cache_control.ttl !== undefined;
  for (let at = payload.messages.length - 1; at > after; at -= 1) {
    const message = payload.messages[at];
    if (!isObject(message) || !Array.isArray(message.content) || !message.content.some(longLived)) continue;
    const next = structuredClone(payload) as Json & { messages: Json[] };
    const block = (next.messages[at]!.content as Json[]).findLast(longLived)!;
    const { ttl: _ttl, ...control } = block.cache_control as Json;
    block.cache_control = control;
    return next;
  }
  return payload;
}

function existingControl(payload: Json): unknown {
  let found: unknown;
  visit(payload, (holder) => { found ??= holder.cache_control; });
  return found;
}

function countMarks(payload: Json): number {
  let count = 0;
  visit(payload, () => { count += 1; });
  return count;
}

function visit(value: unknown, onMark: (holder: Json) => void): void {
  if (Array.isArray(value)) {
    for (const item of value) visit(item, onMark);
    return;
  }
  if (!isObject(value)) return;
  if (value.cache_control !== undefined) onMark(value);
  for (const [key, field] of Object.entries(value)) if (key !== "cache_control") visit(field, onMark);
}
