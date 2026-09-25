import { boundedUtf8Prefix, TRUNCATION_MARKER } from "../util/bounded-text.js";

/** Presentation only: canonical prompts and session names remain untouched. */
export const MAX_SUMMARY_TEXT_BYTES = 1_024;

export function boundedSummaryText(value: string, maximumBytes = MAX_SUMMARY_TEXT_BYTES): string {
  if (Buffer.byteLength(value) <= maximumBytes) return value;
  const available = maximumBytes - Buffer.byteLength(TRUNCATION_MARKER);
  return `${boundedUtf8Prefix(value, available)}${TRUNCATION_MARKER}`;
}
