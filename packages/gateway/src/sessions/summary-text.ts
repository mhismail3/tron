/** Presentation only: canonical prompts and session names remain untouched. */
export const MAX_SUMMARY_TEXT_BYTES = 1_024;

export function boundedSummaryText(value: string, maximumBytes = MAX_SUMMARY_TEXT_BYTES): string {
  if (Buffer.byteLength(value) <= maximumBytes) return value;
  const suffix = "…";
  const available = maximumBytes - Buffer.byteLength(suffix);
  let prefix = "";
  let bytes = 0;
  // Iterate code points so a cut never splits UTF-8 or removes a genuine
  // replacement character at the boundary. Work stops at the small prefix.
  for (const character of value) {
    bytes += Buffer.byteLength(character);
    if (bytes > available) break;
    prefix += character;
  }
  return `${prefix}${suffix}`;
}
