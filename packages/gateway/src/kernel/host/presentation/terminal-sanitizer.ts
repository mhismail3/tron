const MAX_DIAGNOSTIC_BYTES = 512;

function stringTerminator(value: string, start: number, allowBell: boolean): number {
  for (let index = start; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if ((allowBell && code === 0x07) || code === 0x9c) return index + 1;
    if (code === 0x1b && value[index + 1] === "\\") return index + 2;
  }
  return value.length;
}

/** Removes terminal protocol controls and their payloads without interpreting them. */
export function stripTerminalControls(value: string, preserveNewlines = true): string {
  let result = "";
  for (let index = 0; index < value.length;) {
    const code = value.charCodeAt(index);
    if (code === 0x1b) {
      const introducer = value[index + 1];
      if (introducer === "]" || introducer === "P" || introducer === "_" || introducer === "^" || introducer === "X") {
        index = stringTerminator(value, index + 2, introducer === "]");
        continue;
      }
      if (introducer === "[") {
        index += 2;
        while (index < value.length && (value.charCodeAt(index) < 0x40 || value.charCodeAt(index) > 0x7e)) index += 1;
        if (index < value.length) index += 1;
        continue;
      }
      index += 1;
      while (index < value.length && value.charCodeAt(index) >= 0x20 && value.charCodeAt(index) <= 0x2f) index += 1;
      if (index < value.length && value.charCodeAt(index) >= 0x30 && value.charCodeAt(index) <= 0x7e) index += 1;
      continue;
    }
    if (code === 0x90 || code === 0x98 || code === 0x9d || code === 0x9e || code === 0x9f) {
      index = stringTerminator(value, index + 1, code === 0x9d);
      continue;
    }
    if (code === 0x9b) {
      index += 1;
      while (index < value.length && (value.charCodeAt(index) < 0x40 || value.charCodeAt(index) > 0x7e)) index += 1;
      if (index < value.length) index += 1;
      continue;
    }
    if (code < 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) {
      if (preserveNewlines && (code === 0x0a || code === 0x0d)) result += value[index];
      index += 1;
      continue;
    }
    result += value[index];
    index += 1;
  }
  return result;
}

export function boundedDisplayError(error: unknown): string {
  const source = stripTerminalControls(error instanceof Error ? error.message : String(error), false);
  let result = "";
  for (const character of source) {
    if (Buffer.byteLength(result + character, "utf8") > MAX_DIAGNOSTIC_BYTES) break;
    result += character;
  }
  return result;
}
