/**
 * Prompt-caching layout for Home requests, which carry the memory view.
 *
 * Home's activations send the view in fixed groups of lines (`viewPieces`,
 * #2228). Anthropic caches only where a request places
 * `cache_control`, at most four times per request, and keys each entry by every
 * block before it; OpenAI and DeepSeek cache shared prefixes on their own, so for
 * them the order of the request is the whole layout.
 */

/**
 * View lines per block of a Home request. Four lines keep the uncached partial
 * group small, and 20 blocks of lookback cover about 80 new lines per activation.
 */
export const VIEW_BLOCK_LINES = 4;

/** Anthropic refuses a request with more `cache_control` blocks than this. */
export const ANTHROPIC_MAX_CACHE_BREAKPOINTS = 4;

type Json = Record<string, unknown>;

function isObject(value: unknown): value is Json {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/**
 * Mark the content blocks `blocks` of `messages[messageIndex]` in an Anthropic
 * Messages payload, as pi-ai builds it, and keep the request within Anthropic's
 * breakpoint limit.
 *
 * Only `cache_control` fields change. The request's own end mark and the new
 * piece marks are kept; when the limit is exceeded, marks are dropped from the
 * tool list first, then from the system blocks, because the first piece mark
 * covers both. A payload with no mark at all has caching turned off, and one
 * of any other shape is returned as it is.
 */
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
  const optional: Json[] = [
    ...(Array.isArray(next.tools) ? (next.tools as unknown[]).filter(isObject).reverse() : []),
    ...(Array.isArray(next.system) ? (next.system as unknown[]).filter(isObject).reverse() : []),
  ].filter((item) => item.cache_control !== undefined);
  let total = countMarks(next);
  for (const item of optional) {
    if (total <= ANTHROPIC_MAX_CACHE_BREAKPOINTS) break;
    delete item.cache_control;
    total -= 1;
  }
  return total <= ANTHROPIC_MAX_CACHE_BREAKPOINTS ? next : payload;
}

/** The cache control pi-ai chose for this request (retention, TTL), or undefined when it set none. */
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
