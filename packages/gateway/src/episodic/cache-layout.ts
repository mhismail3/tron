/**
 * Prompt-caching layout for requests that carry a memory view.
 *
 * The episodic summarizer's context uses the recipe's cuts (OptChat gist §8): the
 * context is cut into pieces at the last line end before each mark, so two calls
 * whose contexts share their start share the pieces before the first cut that
 * differs. Home's activations use the view's own blocks instead (`viewPieces`,
 * #491). Anthropic caches only where a request places `cache_control`, at most
 * four times per request; OpenAI and DeepSeek cache shared prefixes on their
 * own, so for them the order of the request is the whole layout.
 */

/** Where the view is cut, in characters (gist §8; picked there by replaying real sessions). */
export const CACHE_MARKS = [50_000, 80_000, 100_000] as const;

/** Anthropic refuses a request with more `cache_control` blocks than this. */
export const ANTHROPIC_MAX_CACHE_BREAKPOINTS = 4;

/**
 * `text` cut at the last line end at or before each mark; a mark past the end
 * of the text, or with no new line end before it, adds no cut. The pieces
 * rejoin to exactly `text`, and every piece but the last ends with a line end.
 */
export function cachePieces(text: string, marks: readonly number[] = CACHE_MARKS): string[] {
  const pieces: string[] = [];
  let start = 0;
  for (const mark of marks) {
    if (mark >= text.length) break;
    const lineEnd = text.lastIndexOf("\n", mark - 1);
    if (lineEnd < start) continue;
    pieces.push(text.slice(start, lineEnd + 1));
    start = lineEnd + 1;
  }
  if (start < text.length || pieces.length === 0) pieces.push(text.slice(start));
  return pieces;
}

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
