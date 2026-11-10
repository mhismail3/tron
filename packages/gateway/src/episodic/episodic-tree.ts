import { yieldToEventLoop } from "../util/event-loop-yield.js";
import { EPISODIC_PLACEHOLDER, type EpisodicContextRun } from "./episodic-contract.js";

export interface EpisodicViewPart {
  level: number;
  index: number;
  start: number;
  span: number;
}

type EpisodicViewBytes = (part: EpisodicViewPart) => { built: boolean; bytes: number };

export const EPISODIC_MAX_LEVEL = 31;

export function nodeAddress(level: number, index: number): string {
  const span = 2 ** level;
  return `${index * span}+${span}`;
}

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

export function capText(text: string, capChars: number, tailChars: number): { text: string; capped: boolean } {
  if (text.length <= capChars) return { text, capped: false };
  let tail = Math.min(tailChars, Math.max(0, capChars - 1));
  let head = capChars - tail;
  if (/[\uD800-\uDBFF]/u.test(text[head - 1] ?? "") && /[\uDC00-\uDFFF]/u.test(text[head] ?? "")) head -= 1;
  if (/[\uDC00-\uDFFF]/u.test(text[text.length - tail] ?? "") && /[\uD800-\uDBFF]/u.test(text[text.length - tail - 1] ?? "")) tail -= 1;
  const removed = text.length - head - tail;
  const capped = `${text.slice(0, head)}\n…[truncated ${removed} characters]…\n${text.slice(text.length - tail)}`;
  return { text: Buffer.from(capped, "utf8").toString("utf8"), capped: true };
}

export function snippetAround(text: string, matchIndex: number, matchLength: number, limit: number): string {
  const body = Math.max(0, limit - 2);
  const latest = Math.max(0, text.length - body);
  const start = Math.min(Math.max(0, matchIndex - Math.floor((body - matchLength) / 2)), latest);
  const end = Math.min(text.length, start + body);
  const window = text.slice(start, end).replace(/\n+/gu, " ");
  return `${start > 0 ? "…" : ""}${window}${end < text.length ? "…" : ""}`;
}

export function freeNodeText(kind: string, text: string, nodeBytes: number): string | undefined {
  const line = `${kind}: ${text}`;
  return utf8Bytes(line) <= nodeBytes ? line : undefined;
}

export function mergedFreeText(childA: string, childB: string, nodeBytes: number): string | undefined {
  const line = `${childA}\n${childB}`;
  return utf8Bytes(line) <= nodeBytes ? line : undefined;
}

export function placeholderBytes(): number {
  return utf8Bytes(EPISODIC_PLACEHOLDER);
}

function siblings(a: EpisodicViewPart, b: EpisodicViewPart | undefined): boolean {
  return b !== undefined && a.level === b.level && a.index % 2 === 0 && b.index === a.index + 1;
}

function viewBytes(parts: readonly EpisodicViewPart[], bytesOf: EpisodicViewBytes): number {
  let total = 0;
  for (const part of parts) total += bytesOf(part).bytes;
  return total;
}

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
      if (!siblings(a, b)) continue;
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

function viewLowWater(viewBudget: number): number {
  return viewBudget - Math.floor(viewBudget / 8);
}

export function rebalanceView(
  parts: EpisodicViewPart[],
  count: number,
  viewBudget: number,
  bytesOf: EpisodicViewBytes,
  isBuilt: (address: string) => boolean,
  total = viewBytes(parts, bytesOf),
): number {
  if (total <= viewBudget) return total;
  const lowWater = viewLowWater(viewBudget);
  const fitted = [...parts];
  const bytes = fitView(fitted, count, lowWater, bytesOf, isBuilt, total);
  if (bytes > lowWater && fitted.some((part, index) => siblings(part, fitted[index + 1]))) return total;
  for (let index = 0; index < fitted.length; index += 1) parts[index] = fitted[index]!;
  parts.length = fitted.length;
  return bytes;
}

const EPISODIC_FOLD_SLICE_MESSAGES = 2_000;

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
