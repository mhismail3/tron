/**
 * The one credential-detecting rule set: shapes that are a secret wherever they
 * appear, so both the process preview (`redactProcessText`) and the episodic
 * projection compose this instead of each keeping their own copy.
 *
 * It is deliberately credential-only. The process preview additionally masks
 * every `NAME=value` assignment and long high-entropy tokens, which is right for
 * a bounded presentation of shell output and wrong for text that must stay
 * readable: it would destroy file paths, hashes and ordinary identifiers the
 * memory has to keep.
 */
export function redactCredentials(value: string): string {
  return value
    .replace(/-----BEGIN [^-\r\n]{1,80}-----[\s\S]*?-----END [^-\r\n]{1,80}-----/gu, "[REDACTED PRIVATE KEY]")
    .replace(/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/gu, "[REDACTED]")
    .replace(/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{16,})\b/gu, "[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu, "[REDACTED]")
    // A bearer credential is a token by definition, so its shape is enough:
    // this also covers the `authorization` header written as prose.
    .replace(/\b(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}/giu, "$1[REDACTED]");
}
