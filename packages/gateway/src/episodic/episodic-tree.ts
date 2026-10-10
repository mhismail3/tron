import { yieldToEventLoop } from "../util/event-loop-yield.js";
import { EPISODIC_PLACEHOLDER, type EpisodicContextRun } from "./episodic-contract.js";

/*
 * The tree and the view of the OptChat recipe (gist §3 and §5), as pure
 * functions. Addresses are the recipe's `start+n`: node (l, i) is
 * `${i·2^l}+${2^l}`, covering messages [i·2^l, (i+1)·2^l).
 */

export interface EpisodicViewPart {
  level: number;
  index: number;
  start: number;
  span: number;
}

/** Byte size of one part and whether its node is built; an unbuilt part counts
 * the placeholder the view would render (gist §5.2 `fit`). */
type EpisodicViewBytes = (part: EpisodicViewPart) => { built: boolean; bytes: number };

/** A node level above this cannot be addressed by one base-36 code. No real
 * session reaches it: level 31 covers 2^31 messages. */
export const EPISODIC_MAX_LEVEL = 31;

export function nodeAddress(level: number, index: number): string {
  const span = 2 ** level;
  return `${index * span}+${span}`;
}

/** Parse `start+n`; the level is `log2(n)` and the index `start/n`. */
export function parseNodeAddress(address: string): { level: number; index: number } | undefined {
  const match = /^(\d+)\+(\d+)$/u.exec(address);
  if (!match) return undefined;
  const start = Number(match[1]);
  const span = Number(match[2]);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(span) || span < 1 || (span & (span - 1)) !== 0) return undefined;
  if (start % span !== 0) return undefined;
  const level = Math.log2(span);
  if (level > EPISODIC_MAX_LEVEL) return undefined;
  return { level, index: start / span };
}

/** One address as a single base-36 code, so an invalidation record stays small
 * (`(start · 32) + level` is unique for every address). */
export function encodeNodeCode(level: number, index: number): string {
  if (!Number.isSafeInteger(level) || level < 0 || level > EPISODIC_MAX_LEVEL) throw new Error("Node level cannot be encoded");
  return (index * 2 ** level * 32 + level).toString(36);
}

export function decodeNodeCode(code: string): string | undefined {
  const value = Number.parseInt(code, 36);
  if (!Number.isSafeInteger(value) || value < 0 || value.toString(36) !== code) return undefined;
  const level = value % 32;
  const start = (value - level) / 32;
  if (start % 2 ** level !== 0) return undefined;
  return nodeAddress(level, start / 2 ** level);
}

/** The view's lines up to (not including) `end`, as level runs from message 0.
 * The view tiles from 0, so the runs reconstruct every address exactly. */
function encodeContextRuns(parts: readonly EpisodicViewPart[]): EpisodicContextRun[] {
  const runs: Array<[number, number]> = [];
  for (const part of parts) {
    const last = runs[runs.length - 1];
    if (last && last[0] === part.level) last[1] += 1;
    else runs.push([part.level, 1]);
  }
  return runs;
}

export function decodeContextRuns(runs: readonly EpisodicContextRun[]): string[] {
  const addresses: string[] = [];
  let cursor = 0;
  for (const [level, count] of runs) {
    const span = 2 ** level;
    for (let offset = 0; offset < count; offset += 1) {
      addresses.push(nodeAddress(level, cursor / span));
      cursor += span;
    }
  }
  return addresses;
}

export function utf8Bytes(text: string): number {
  return Buffer.byteLength(text, "utf8");
}

/** Cut at a byte offset without splitting a UTF-8 character: the partial
 * character's replacement is dropped (gist §4.3). */
export function cutBytes(text: string, maxBytes: number): string {
  if (maxBytes <= 0) return "";
  if (utf8Bytes(text) <= maxBytes) return text;
  const cut = Buffer.from(text, "utf8").subarray(0, maxBytes).toString("utf8");
  return cut.endsWith("\uFFFD") ? cut.slice(0, -1) : cut;
}

/** Cap one text at `capChars`, keeping head and tail with a marker naming what
 * was removed (gist §7; the recipe caps tool output the same way). The result is a
 * copy: a slice keeps its whole source string alive for as long as the capped text
 * is stored, and a stored record must not hold a multi-megabyte source. */
export function capText(text: string, capChars: number, tailChars: number): { text: string; capped: boolean } {
  if (text.length <= capChars) return { text, capped: false };
  const tail = Math.min(tailChars, Math.max(0, capChars - 1));
  const head = capChars - tail;
  const removed = text.length - head - tail;
  const capped = `${text.slice(0, head)}\n…[truncated ${removed} characters]…\n${text.slice(text.length - tail)}`;
  return { text: Buffer.from(capped, "utf8").toString("utf8"), capped: true };
}

/**
 * The window one search hit shows around its match: at most `limit` characters,
 * the match kept whole, with `…` marking each end that was cut, and its newlines
 * flattened to single spaces exactly as a view line renders text, so one hit stays
 * one line. The caller's query bound is under `limit`, so the match always fits,
 * and the marks are inside `limit`, so the returned snippet is bounded by it
 * whatever it cut.
 */
export function snippetAround(text: string, matchIndex: number, matchLength: number, limit: number): string {
  // Two characters are reserved for the truncation marks, so the snippet is
  // bounded by `limit` whatever it cut; a caller's query bound is under `body`,
  // so the whole match fits and the window never has to slide.
  const body = Math.max(0, limit - 2);
  const latest = Math.max(0, text.length - body);
  const start = Math.min(Math.max(0, matchIndex - Math.floor((body - matchLength) / 2)), latest);
  const end = Math.min(text.length, start + body);
  const window = text.slice(start, end).replace(/\n+/gu, " ");
  return `${start > 0 ? "…" : ""}${window}${end < text.length ? "…" : ""}`;
}

/** A level-0 free node (gist §3): the source itself when it fits `nodeBytes`. */
export function freeNodeText(kind: string, text: string, nodeBytes: number): string | undefined {
  const line = `${kind}: ${text}`;
  return utf8Bytes(line) <= nodeBytes ? line : undefined;
}

/** A level>0 free node: the two children when they fit `nodeBytes`. */
export function mergedFreeText(childA: string, childB: string, nodeBytes: number): string | undefined {
  const line = `${childA}\n${childB}`;
  return utf8Bytes(line) <= nodeBytes ? line : undefined;
}

export function placeholderBytes(): number {
  return utf8Bytes(EPISODIC_PLACEHOLDER);
}

function viewBytes(parts: readonly EpisodicViewPart[], bytesOf: EpisodicViewBytes): number {
  let total = 0;
  for (const part of parts) total += bytesOf(part).bytes;
  return total;
}

/**
 * The view's `fit` (gist §5.2): while over budget, merge the adjacent built
 * parent pair with the largest `due = (T - start) / 2^(l+2)`. Parents that are
 * not built are passed over, so the budget is soft; parts are never split.
 * `total` is the caller's running byte total; the returned total is the one the
 * merged view now has, so a caller that appends or merges can keep it running
 * instead of re-summing the whole view.
 */
function fitView(
  parts: EpisodicViewPart[],
  count: number,
  viewBudget: number,
  bytesOf: EpisodicViewBytes,
  isBuilt: (address: string) => boolean,
  total = viewBytes(parts, bytesOf),
): number {
  while (total > viewBudget) {
    let best: { position: number; due: number } | undefined;
    for (let position = 0; position + 1 < parts.length; position += 1) {
      const a = parts[position]!;
      const b = parts[position + 1]!;
      if (a.level !== b.level || a.index % 2 !== 0 || b.index !== a.index + 1) continue;
      if (!isBuilt(nodeAddress(a.level + 1, a.index / 2))) continue;
      const due = (count - a.start) / 2 ** (a.level + 2);
      if (!best || due > best.due) best = { position, due };
    }
    if (!best) break;
    const a = parts[best.position]!;
    const merged: EpisodicViewPart = { level: a.level + 1, index: a.index / 2, start: a.start, span: a.span * 2 };
    total -= bytesOf(a).bytes + bytesOf(parts[best.position + 1]!).bytes;
    parts.splice(best.position, 2, merged);
    total += bytesOf(merged).bytes;
  }
  return total;
}

/** Where a rebalance fits the view down to: an eighth of the budget below it. */
function viewLowWater(viewBudget: number): number {
  return viewBudget - Math.floor(viewBudget / 8);
}

/**
 * The view's rebalance (#491): nothing while the view is within its budget, then
 * one `fitView` down to the low-water mark. A fit merges the oldest eligible
 * parts, near the view's head, so fitting after every message rewrote the head of
 * nearly every request and voided every provider's prompt cache. Between two
 * rebalances the view only grows at its end, so a request re-reads everything an
 * earlier one sent, and a rebalance leaves an eighth of the budget before the next.
 */
export function rebalanceView(
  parts: EpisodicViewPart[],
  count: number,
  viewBudget: number,
  bytesOf: EpisodicViewBytes,
  isBuilt: (address: string) => boolean,
  total = viewBytes(parts, bytesOf),
): number {
  return total <= viewBudget ? total : fitView(parts, count, viewLowWater(viewBudget), bytesOf, isBuilt, total);
}

/** A bounded synchronous stretch of the fold, not a deadline. */
const EPISODIC_FOLD_SLICE_MESSAGES = 2_000;

/** The fold of the view from message 0 (gist §5.2 "At load"): append each
 * message's part, then rebalance, exactly as the live view does. It yields to the
 * event loop every `EPISODIC_FOLD_SLICE_MESSAGES` messages, so opening a long
 * memory never blocks an in-flight request for the whole fold. */
export async function foldViewSliced(
  count: number,
  viewBudget: number,
  bytesOf: EpisodicViewBytes,
  isBuilt: (address: string) => boolean,
): Promise<EpisodicViewPart[]> {
  const parts: EpisodicViewPart[] = [];
  let total = 0;
  for (let index = 0; index < count; index += 1) {
    const part: EpisodicViewPart = { level: 0, index, start: index, span: 1 };
    parts.push(part);
    total += bytesOf(part).bytes;
    total = rebalanceView(parts, index + 1, viewBudget, bytesOf, isBuilt, total);
    if ((index + 1) % EPISODIC_FOLD_SLICE_MESSAGES === 0) await yieldToEventLoop();
  }
  return parts;
}

interface EpisodicViewContext {
  /** One line per part, newlines flattened: the view is one line per part, so a
   * multi-line summary must not become several lines in the prompt. */
  lines: string[];
  /** The same parts as level runs from message 0. */
  runs: EpisodicContextRun[];
}

/** The view's lines up to (not including) `end`, bare text, no ids (gist §4.2).
 * Every one of them is a built summary for a node the pump may start. */
export function viewContext(parts: readonly EpisodicViewPart[], end: number, textOf: (part: EpisodicViewPart) => string | undefined): EpisodicViewContext {
  const included: EpisodicViewPart[] = [];
  const lines: string[] = [];
  for (const part of parts) {
    if (part.start >= end) break;
    if (part.start + part.span > end) break;
    const text = textOf(part);
    if (text === undefined) break;
    included.push(part);
    lines.push(text.replace(/\s*\n\s*/gu, " "));
  }
  return { lines, runs: encodeContextRuns(included) };
}
