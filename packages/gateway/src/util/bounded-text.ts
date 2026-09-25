/** Bounded UTF-8 cuts for wire projections and display summaries. Every cut
 * keeps whole code points, so a multi-byte character is never torn and a
 * genuine U+FFFD in the source is never mistaken for a torn tail. Callers own
 * their byte budget and where the marker is placed. */

/** Appended or prefixed where a value had to be cut to fit a byte budget. */
export const TRUNCATION_MARKER = "…";

function utf8CodePointBytes(codePoint: number): number {
  return codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
}

/** The longest prefix of `value` whose UTF-8 size is at most `maximumBytes`. */
export function boundedUtf8Prefix(value: string, maximumBytes: number): string {
  if (maximumBytes <= 0) return "";
  let bytes = 0;
  let index = 0;
  while (index < value.length) {
    const codePoint = value.codePointAt(index)!;
    const width = utf8CodePointBytes(codePoint);
    if (bytes + width > maximumBytes) break;
    bytes += width;
    index += codePoint > 0xffff ? 2 : 1;
  }
  return index === value.length ? value : value.slice(0, index);
}

/** The longest suffix of `value` whose UTF-8 size is at most `maximumBytes`. */
export function boundedUtf8Suffix(value: string, maximumBytes: number): string {
  if (maximumBytes <= 0) return "";
  let bytes = 0;
  let index = value.length;
  while (index > 0) {
    let start = index - 1;
    const unit = value.charCodeAt(start);
    if (unit >= 0xdc00 && unit <= 0xdfff && start > 0) {
      const lead = value.charCodeAt(start - 1);
      if (lead >= 0xd800 && lead <= 0xdbff) start -= 1;
    }
    const codePoint = value.codePointAt(start)!;
    const width = utf8CodePointBytes(codePoint);
    if (bytes + width > maximumBytes) break;
    bytes += width;
    index = start;
  }
  return index === 0 ? value : value.slice(index);
}
