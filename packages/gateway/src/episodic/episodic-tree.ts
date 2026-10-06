import { EPISODIC_PLACEHOLDER } from "./episodic-contract.js";

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
export type EpisodicViewBytes = (part: EpisodicViewPart) => { built: boolean; bytes: number };

export function nodeAddress(level: number, index: number): string {
  const span = 2 ** level;
  return `${index * span}+${span}`;
}

export function nodeStart(level: number, index: number): number {
  return index * 2 ** level;
}

export function nodeSpan(level: number): number {
  return 2 ** level;
}

/** Parse `start+n`; the level is `log2(n)` and the index `start/n`. */
export function parseNodeAddress(address: string): { level: number; index: number } | undefined {
  const match = /^(\d+)\+(\d+)$/u.exec(address);
  if (!match) return undefined;
  const start = Number(match[1]);
  const span = Number(match[2]);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(span) || span < 1 || (span & (span - 1)) !== 0) return undefined;
  if (start % span !== 0) return undefined;
  return { level: Math.log2(span), index: start / span };
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
 * was removed (gist §7; the recipe caps tool output the same way). */
export function capText(text: string, capChars: number, tailChars: number): { text: string; capped: boolean } {
  if (text.length <= capChars) return { text, capped: false };
  const tail = Math.min(tailChars, Math.max(0, capChars - 1));
  const head = capChars - tail;
  const removed = text.length - head - tail;
  return { text: `${text.slice(0, head)}\n…[truncated ${removed} characters]…\n${text.slice(text.length - tail)}`, capped: true };
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

export function viewBytes(parts: readonly EpisodicViewPart[], bytesOf: EpisodicViewBytes): number {
  let total = 0;
  for (const part of parts) total += bytesOf(part).bytes;
  return total;
}

/**
 * The view's `fit` (gist §5.2): while over budget, merge the adjacent built
 * parent pair with the largest `due = (T - start) / 2^(l+2)`. Parents that are
 * not built are passed over, so the budget is soft; parts are never split.
 */
export function fitView(
  parts: EpisodicViewPart[],
  count: number,
  viewBudget: number,
  bytesOf: EpisodicViewBytes,
  isBuilt: (address: string) => boolean,
): void {
  let total = viewBytes(parts, bytesOf);
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
}

/** Fold the view again from message 0 (gist §5.2 "At load"): append each
 * message's part, then fit. The memory does this once at load and keeps the
 * result live afterwards. */
export function foldView(count: number, viewBudget: number, bytesOf: EpisodicViewBytes, isBuilt: (address: string) => boolean): EpisodicViewPart[] {
  const parts: EpisodicViewPart[] = [];
  for (let index = 0; index < count; index += 1) {
    parts.push({ level: 0, index, start: index, span: 1 });
    fitView(parts, index + 1, viewBudget, bytesOf, isBuilt);
  }
  return parts;
}

/** The view's lines up to (not including) `end`, bare text, no ids (gist §4.2).
 * Every one of them is a built summary for a node the pump may start. */
export function viewLineTexts(parts: readonly EpisodicViewPart[], end: number, textOf: (part: EpisodicViewPart) => string | undefined): Array<{ address: string; text: string }> {
  const lines: Array<{ address: string; text: string }> = [];
  for (const part of parts) {
    if (part.start >= end) break;
    if (part.start + part.span > end) break;
    const text = textOf(part);
    if (text === undefined) break;
    lines.push({ address: nodeAddress(part.level, part.index), text });
  }
  return lines;
}
