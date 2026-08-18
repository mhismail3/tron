import { CURSOR_MARKER, visibleWidth } from "@earendil-works/pi-tui";

export const EXTENSION_FRAME_MAX_COLUMNS = 160;
export const EXTENSION_FRAME_MAX_LINES = 120;
export const EXTENSION_FRAME_MAX_RUNS = 4_096;
export const EXTENSION_FRAME_MAX_BYTES = 256 * 1024;
export const EXTENSION_FRAME_MAX_SOURCE_BYTES = 256 * 1024;

const TAB_WIDTH = 4;
const MAX_LINK_LENGTH = 2_048;
const MAX_DIAGNOSTICS = 16;

export interface ExtensionFrameStyle {
  bold?: true;
  dim?: true;
  italic?: true;
  underline?: true;
  inverse?: true;
  strike?: true;
  foreground?: `#${string}`;
  background?: `#${string}`;
  link?: string;
}

export interface ExtensionFrameRun {
  text: string;
  style: ExtensionFrameStyle;
}

export interface ExtensionFrameLine {
  plainText: string;
  runs: readonly ExtensionFrameRun[];
}

export interface ExtensionFrameCursor {
  row: number;
  column: number;
}

export interface ExtensionFrame {
  lines: readonly ExtensionFrameLine[];
  plainText: string;
  cursor?: ExtensionFrameCursor;
}

export type FrameDiagnosticCode =
  | "unsafe-control-stripped"
  | "unsafe-link-stripped"
  | "line-clamped"
  | "source-limit-exceeded"
  | "line-limit-exceeded"
  | "run-limit-exceeded"
  | "frame-limit-exceeded";

export interface FrameDiagnostic {
  code: FrameDiagnosticCode;
  message: string;
}

export interface ParseExtensionFrameResult {
  ok: boolean;
  frame: ExtensionFrame;
  diagnostics: readonly FrameDiagnostic[];
}

export interface ExtensionFrameLimits {
  maxColumns?: number;
  maxLines?: number;
  maxRuns?: number;
  maxFrameBytes?: number;
  maxSourceBytes?: number;
}

interface ResolvedLimits {
  maxColumns: number;
  maxLines: number;
  maxRuns: number;
  maxFrameBytes: number;
  maxSourceBytes: number;
}

class FrameLimitError extends Error {
  constructor(readonly code: FrameDiagnosticCode, message: string) { super(message); }
}

const ANSI_16: readonly string[] = [
  "#000000", "#800000", "#008000", "#808000", "#000080", "#800080", "#008080", "#c0c0c0",
  "#808080", "#ff0000", "#00ff00", "#ffff00", "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
];

const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

function boundedInteger(value: number | undefined, fallback: number, minimum: number, maximum: number): number {
  if (value === undefined || !Number.isFinite(value)) return fallback;
  return Math.min(maximum, Math.max(minimum, Math.trunc(value)));
}

function resolveLimits(limits: ExtensionFrameLimits): ResolvedLimits {
  return {
    maxColumns: boundedInteger(limits.maxColumns, EXTENSION_FRAME_MAX_COLUMNS, 1, EXTENSION_FRAME_MAX_COLUMNS),
    maxLines: boundedInteger(limits.maxLines, EXTENSION_FRAME_MAX_LINES, 1, EXTENSION_FRAME_MAX_LINES),
    maxRuns: boundedInteger(limits.maxRuns, EXTENSION_FRAME_MAX_RUNS, 1, EXTENSION_FRAME_MAX_RUNS),
    maxFrameBytes: boundedInteger(limits.maxFrameBytes, EXTENSION_FRAME_MAX_BYTES, 256, EXTENSION_FRAME_MAX_BYTES),
    maxSourceBytes: boundedInteger(limits.maxSourceBytes, EXTENSION_FRAME_MAX_SOURCE_BYTES, 256, EXTENSION_FRAME_MAX_SOURCE_BYTES),
  };
}

function fallbackFrame(maxColumns: number): ExtensionFrame {
  const source = maxColumns < 13 ? "!" : maxColumns < 33 ? "[Unavailable]" : "[Extension component unavailable]";
  let text = "";
  let columns = 0;
  for (const segment of graphemeSegmenter.segment(source)) {
    const width = visibleWidth(segment.segment);
    if (columns + width > maxColumns) break;
    text += segment.segment;
    columns += width;
  }
  return { lines: [{ plainText: text, runs: [{ text, style: {} }] }], plainText: text };
}

function diagnosticMessage(code: FrameDiagnosticCode): string {
  switch (code) {
    case "unsafe-control-stripped": return "Unsupported terminal controls were removed";
    case "unsafe-link-stripped": return "An unsafe component link was removed";
    case "line-clamped": return "Component output was clamped to the remote width";
    case "source-limit-exceeded": return "Component source exceeded the frame input budget";
    case "line-limit-exceeded": return "Component output exceeded the logical line limit";
    case "run-limit-exceeded": return "Component output exceeded the styled-run limit";
    case "frame-limit-exceeded": return "Component output exceeded the encoded frame budget";
  }
}

function color256(index: number): `#${string}` | undefined {
  if (!Number.isInteger(index) || index < 0 || index > 255) return undefined;
  if (index < 16) return ANSI_16[index] as `#${string}`;
  if (index < 232) {
    const offset = index - 16;
    const levels = [0, 95, 135, 175, 215, 255];
    const red = levels[Math.floor(offset / 36)] ?? 0;
    const green = levels[Math.floor((offset % 36) / 6)] ?? 0;
    const blue = levels[offset % 6] ?? 0;
    return rgb(red, green, blue);
  }
  const level = 8 + (index - 232) * 10;
  return rgb(level, level, level);
}

function rgb(red: number, green: number, blue: number): `#${string}` {
  const hex = (value: number) => Math.max(0, Math.min(255, value)).toString(16).padStart(2, "0");
  return `#${hex(red)}${hex(green)}${hex(blue)}`;
}

function sameStyle(left: ExtensionFrameStyle, right: ExtensionFrameStyle): boolean {
  return left.bold === right.bold && left.dim === right.dim && left.italic === right.italic &&
    left.underline === right.underline && left.inverse === right.inverse && left.strike === right.strike &&
    left.foreground === right.foreground && left.background === right.background && left.link === right.link;
}

function copyStyle(style: ExtensionFrameStyle): ExtensionFrameStyle { return { ...style }; }

function applySgr(payload: string, style: ExtensionFrameStyle): void {
  if (!/^[\d;:]*$/.test(payload)) return;
  const groups = payload.length === 0 ? ["0"] : payload.split(";");
  const values: number[] = [];
  for (const group of groups) {
    if (!group.includes(":")) {
      values.push(group.length === 0 ? 0 : Number(group));
      continue;
    }
    const parts = group.split(":");
    const code = Number(parts[0]);
    const mode = Number(parts[1]);
    if ((code === 38 || code === 48) && mode === 2 && parts.length >= 5) {
      const channels = parts.slice(-3).map(Number);
      values.push(code, 2, ...channels);
    } else if ((code === 38 || code === 48) && mode === 5 && parts.length >= 3) {
      values.push(code, 5, Number(parts.at(-1)));
    } else {
      values.push(...parts.map((part) => part.length === 0 ? 0 : Number(part)));
    }
  }
  for (let index = 0; index < values.length; index += 1) {
    const code = values[index];
    if (code === undefined || !Number.isInteger(code)) continue;
    switch (code) {
      case 0: {
        const link = style.link;
        for (const key of Object.keys(style) as (keyof ExtensionFrameStyle)[]) delete style[key];
        if (link) style.link = link;
        break;
      }
      case 1: style.bold = true; break;
      case 2: style.dim = true; break;
      case 3: style.italic = true; break;
      case 4: style.underline = true; break;
      case 7: style.inverse = true; break;
      case 9: style.strike = true; break;
      case 22: delete style.bold; delete style.dim; break;
      case 23: delete style.italic; break;
      case 24: delete style.underline; break;
      case 27: delete style.inverse; break;
      case 29: delete style.strike; break;
      case 39: delete style.foreground; break;
      case 49: delete style.background; break;
      default: {
        if (code >= 30 && code <= 37) style.foreground = ANSI_16[code - 30] as `#${string}`;
        else if (code >= 40 && code <= 47) style.background = ANSI_16[code - 40] as `#${string}`;
        else if (code >= 90 && code <= 97) style.foreground = ANSI_16[8 + code - 90] as `#${string}`;
        else if (code >= 100 && code <= 107) style.background = ANSI_16[8 + code - 100] as `#${string}`;
        else if (code === 38 || code === 48) {
          const target = code === 38 ? "foreground" : "background";
          const mode = values[index + 1];
          if (mode === 5) {
            const color = color256(values[index + 2] ?? -1);
            if (color) style[target] = color;
            index += 2;
          } else if (mode === 2) {
            const red = values[index + 2];
            const green = values[index + 3];
            const blue = values[index + 4];
            if ([red, green, blue].every((value) => Number.isInteger(value) && (value ?? -1) >= 0 && (value ?? 256) <= 255)) {
              style[target] = rgb(red ?? 0, green ?? 0, blue ?? 0);
            }
            index += 4;
          }
        }
      }
    }
  }
}

function findStringTerminator(line: string, start: number, allowBell: boolean): { payloadEnd: number; next: number } {
  for (let index = start; index < line.length; index += 1) {
    const code = line.charCodeAt(index);
    if ((allowBell && code === 0x07) || code === 0x9c) return { payloadEnd: index, next: index + 1 };
    if (code === 0x1b && line[index + 1] === "\\") return { payloadEnd: index, next: index + 2 };
  }
  return { payloadEnd: line.length, next: line.length };
}

function safeLink(uri: string): string | undefined {
  if (uri.length === 0) return "";
  if (uri.length > MAX_LINK_LENGTH || /[\u0000-\u001f\u007f-\u009f]/.test(uri)) return undefined;
  try {
    const parsed = new URL(uri);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:" && parsed.protocol !== "mailto:") return undefined;
    return parsed.href.slice(0, MAX_LINK_LENGTH);
  } catch {
    return undefined;
  }
}

function encodedBytes(value: unknown): number { return Buffer.byteLength(JSON.stringify(value), "utf8"); }

/**
 * Converts one diagnostic/display string into a single bounded frame. This is
 * intentionally built on the parser's grapheme and display-cell accounting;
 * callers must not use JavaScript string slicing to fit terminal columns.
 */
export function boundedExtensionFrame(source: string, maxColumns = EXTENSION_FRAME_MAX_COLUMNS): ExtensionFrame {
  return parseExtensionFrame([source], { maxColumns, maxLines: 1 }).frame;
}

/** Converts logical component lines into a bounded, terminal-independent frame. */
export function parseExtensionFrame(sourceLines: readonly string[], limits: ExtensionFrameLimits = {}): ParseExtensionFrameResult {
  const resolved = resolveLimits(limits);
  const diagnosticCodes = new Set<FrameDiagnosticCode>();
  const addDiagnostic = (code: FrameDiagnosticCode) => {
    if (diagnosticCodes.size < MAX_DIAGNOSTICS) diagnosticCodes.add(code);
  };
  const resultDiagnostics = (): FrameDiagnostic[] => [...diagnosticCodes].map((code) => ({ code, message: diagnosticMessage(code) }));
  const fail = (code: FrameDiagnosticCode): ParseExtensionFrameResult => {
    addDiagnostic(code);
    return { ok: false, frame: fallbackFrame(resolved.maxColumns), diagnostics: resultDiagnostics() };
  };

  if (sourceLines.length > resolved.maxLines) return fail("line-limit-exceeded");
  let sourceBytes = 0;
  for (const line of sourceLines) {
    sourceBytes += Buffer.byteLength(line, "utf8");
    if (sourceBytes > resolved.maxSourceBytes) return fail("source-limit-exceeded");
  }

  try {
    const frameLines: ExtensionFrameLine[] = [];
    let cursor: ExtensionFrameCursor | undefined;
    let runCount = 0;

    for (let row = 0; row < sourceLines.length; row += 1) {
      const source = sourceLines[row] ?? "";
      const runs: ExtensionFrameRun[] = [];
      const style: ExtensionFrameStyle = {};
      let plainText = "";
      let columns = 0;
      let index = 0;
      let cursorSourceOffset: number | undefined;

      // First tokenize printable spans with style. Cell accounting happens only
      // after controls are removed so a style boundary cannot split a grapheme.
      const append = (text: string) => {
        if (text.length === 0) return;
        const last = runs.at(-1);
        if (last && sameStyle(last.style, style)) last.text += text;
        else runs.push({ text, style: copyStyle(style) });
        plainText += text;
      };

      while (index < source.length) {
        if (source.startsWith(CURSOR_MARKER, index)) {
          if (cursorSourceOffset === undefined) cursorSourceOffset = plainText.length;
          index += CURSOR_MARKER.length;
          continue;
        }

        const code = source.charCodeAt(index);
        if (code === 0x1b) {
          const introducer = source[index + 1];
          if (introducer === "[") {
            let end = index + 2;
            while (end < source.length && (source.charCodeAt(end) < 0x40 || source.charCodeAt(end) > 0x7e)) end += 1;
            if (end >= source.length) { addDiagnostic("unsafe-control-stripped"); break; }
            const final = source[end];
            if (final === "m") applySgr(source.slice(index + 2, end), style);
            else addDiagnostic("unsafe-control-stripped");
            index = end + 1;
            continue;
          }
          if (introducer === "]") {
            const terminator = findStringTerminator(source, index + 2, true);
            const payload = source.slice(index + 2, terminator.payloadEnd);
            if (payload.startsWith("8;")) {
              const separator = payload.indexOf(";", 2);
              const uri = separator === -1 ? undefined : payload.slice(separator + 1);
              const link = uri === undefined ? undefined : safeLink(uri);
              if (link === "") delete style.link;
              else if (link) style.link = link;
              else addDiagnostic("unsafe-link-stripped");
            } else addDiagnostic("unsafe-control-stripped");
            index = terminator.next;
            continue;
          }
          if (introducer === "P" || introducer === "_" || introducer === "^" || introducer === "X") {
            const terminator = findStringTerminator(source, index + 2, false);
            addDiagnostic("unsafe-control-stripped");
            index = terminator.next;
            continue;
          }
          addDiagnostic("unsafe-control-stripped");
          let escapeEnd = index + 1;
          while (escapeEnd < source.length && source.charCodeAt(escapeEnd) >= 0x20 && source.charCodeAt(escapeEnd) <= 0x2f) escapeEnd += 1;
          if (escapeEnd < source.length && source.charCodeAt(escapeEnd) >= 0x30 && source.charCodeAt(escapeEnd) <= 0x7e) escapeEnd += 1;
          index = Math.max(index + 1, escapeEnd);
          continue;
        }

        if (code === 0x09) {
          // Tabs are expanded after the current visible prefix is known.
          const prefixColumns = visibleWidth(plainText);
          append(" ".repeat(TAB_WIDTH - (prefixColumns % TAB_WIDTH)));
          index += 1;
          continue;
        }

        if (code < 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) {
          addDiagnostic("unsafe-control-stripped");
          if (code === 0x90 || code === 0x98 || code === 0x9d || code === 0x9e || code === 0x9f) {
            index = findStringTerminator(source, index + 1, code === 0x9d).next;
          } else if (code === 0x9b) {
            index += 1;
            while (index < source.length && (source.charCodeAt(index) < 0x40 || source.charCodeAt(index) > 0x7e)) index += 1;
            if (index < source.length) index += 1;
          } else index += 1;
          continue;
        }

        let end = index + 1;
        while (end < source.length) {
          const next = source.charCodeAt(end);
          if (next === 0x1b || next < 0x20 || next === 0x7f || (next >= 0x80 && next <= 0x9f)) break;
          end += 1;
        }
        append(source.slice(index, end));
        index = end;
      }

      const sourceRuns = runs.splice(0);
      const boundaries: Array<{ end: number; style: ExtensionFrameStyle }> = [];
      let boundary = 0;
      for (const run of sourceRuns) {
        boundary += run.text.length;
        boundaries.push({ end: boundary, style: run.style });
      }
      let sourceOffset = 0;
      plainText = "";
      columns = 0;
      for (const segment of graphemeSegmenter.segment(sourceRuns.map((run) => run.text).join(""))) {
        const grapheme = segment.segment;
        const width = visibleWidth(grapheme);
        const selected = boundaries.find((item) => sourceOffset < item.end)?.style ?? {};
        sourceOffset += grapheme.length;
        if (width < 0) continue;
        if (width > 0 && columns + width > resolved.maxColumns) {
          addDiagnostic("line-clamped");
          continue;
        }
        const last = runs.at(-1);
        if (last && sameStyle(last.style, selected)) last.text += grapheme;
        else {
          runCount += 1;
          if (runCount > resolved.maxRuns) throw new FrameLimitError("run-limit-exceeded", "styled run limit");
          runs.push({ text: grapheme, style: copyStyle(selected) });
        }
        plainText += grapheme;
        columns += width;
      }
      if (cursorSourceOffset !== undefined && cursor === undefined) {
        const prefix = sourceRuns.map((run) => run.text).join("").slice(0, cursorSourceOffset);
        cursor = { row, column: Math.min(visibleWidth(prefix), resolved.maxColumns) };
      }
      frameLines.push({ plainText, runs });
    }

    const frame: ExtensionFrame = {
      lines: frameLines,
      plainText: frameLines.map((line) => line.plainText).join("\n"),
      ...(cursor ? { cursor } : {}),
    };
    if (encodedBytes(frame) > resolved.maxFrameBytes) return fail("frame-limit-exceeded");
    return { ok: true, frame, diagnostics: resultDiagnostics() };
  } catch (error) {
    if (error instanceof FrameLimitError) return fail(error.code);
    return fail("frame-limit-exceeded");
  }
}
