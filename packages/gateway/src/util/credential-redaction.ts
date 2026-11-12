function redactUrlCredentials(candidate: string): string {
  let url: URL;
  try { url = new URL(candidate); } catch { return "[REDACTED URL]"; }
  let changed = false;
  if (url.username || url.password) {
    url.username = "[REDACTED]";
    url.password = "";
    changed = true;
  }
  for (const key of [...url.searchParams.keys()]) {
    if (/(?:token|key|password|secret|authorization|credential|cookie)/iu.test(key)) {
      url.searchParams.set(key, "[REDACTED]");
      changed = true;
    }
  }
  return changed ? url.href : candidate;
}

export function redactCredentials(value: string): string {
  return value
    .replace(/\b[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s"'<>]+/gu, redactUrlCredentials)
    .replace(/-----BEGIN [^-\r\n]{1,80}-----[\s\S]*?-----END [^-\r\n]{1,80}-----/gu, "[REDACTED PRIVATE KEY]")
    .replace(/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/gu, "[REDACTED]")
    .replace(/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{16,})\b/gu, "[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu, "[REDACTED]")
    .replace(/\b(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}/giu, "$1[REDACTED]");
}

export function redactCredentialField(key: string, value: unknown): unknown {
  const normalized = key.replace(/([a-z0-9])([A-Z])/gu, "$1_$2");
  if (/(?:^|[-_])(?:key|api[-_]?key|authorization|password|secret|credential|token|cookie|set[-_]cookie)$/iu.test(normalized)) return "[REDACTED]";
  return typeof value === "string" ? redactCredentials(redact(value)) : value;
}

export function redact(value: string): string {
  return value
    .replace(/\bBearer\s+[^\s,;]+/giu, "Bearer [REDACTED]")
    .replace(/((?:authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret)\s*[:=]\s*)[^\s,;]+/giu, "$1[REDACTED]")
    .replace(/\/Users\/[^\s'"]+/gu, "[USER_PATH]")
    .replace(/\/private\/var\/[^\s'"]+/gu, "[PRIVATE_PATH]");
}
