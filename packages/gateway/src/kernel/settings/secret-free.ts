import { GatewayError } from "../../errors.js";
import { redactCredentials } from "../../util/credential-redaction.js";

export const SECRET_NAME = /(token|secret|password|passwd|api[-_]?key|apikey|credential|bearer|authorization)/iu;

const URL_USERINFO = /\b[a-z][a-z0-9+.-]*:\/\/[^\s/?#@]+(?::[^\s/?#@]+)?@/iu;
const URL_SECRET_QUERY = /\b[a-z][a-z0-9+.-]*:\/\/[^\s?#]*\?(?:[^\s#]*&)?[^\s=&#]*(?:token|secret|password|passwd|api[-_]?key|apikey|credential|bearer|authorization)[^\s=&#]*=/iu;
const SECRET_PAIR = /(?<![a-z0-9])(?:authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret)\s*[:=]\s*["']?(?=[^\s,;'"]*\d)[^\s,;'"]{8,}/iu;

function textCarriesSecret(text: string): boolean {
  return redactCredentials(text) !== text || URL_USERINFO.test(text) || URL_SECRET_QUERY.test(text) || SECRET_PAIR.test(text);
}

export function carriesSecret(value: unknown): boolean {
  if (typeof value === "string") return textCarriesSecret(value);
  if (!value || typeof value !== "object") return false;
  return Object.entries(value).some(([name, child]) => (!Array.isArray(value) && SECRET_NAME.test(name)) || carriesSecret(child));
}

export function refuseSetting(label: string, reason: string): never {
  throw new GatewayError("invalid_request", `${label} ${reason}`);
}

export function secretFreeText(text: string, label: string, what: string, hint: string): string {
  if (redactCredentials(text) !== text) refuseSetting(label, `${what} carries a credential; ${hint}`);
  if (/[\u0000\r\n\p{Bidi_Control}]/u.test(text)) refuseSetting(label, `${what} has a control character`);
  return text;
}

export function secretFreeUrl(value: string, label: string, hint: string): string {
  secretFreeText(value, label, "url", hint);
  let parsed: URL;
  try { parsed = new URL(value); } catch { refuseSetting(label, "must be an absolute URL"); }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") refuseSetting(label, "must use HTTP or HTTPS");
  if (parsed.username || parsed.password) refuseSetting(label, `must not carry credentials; ${hint}`);
  for (const name of parsed.searchParams.keys()) {
    if (SECRET_NAME.test(name)) refuseSetting(label, `carries a secret in its query; ${hint}`);
  }
  return value;
}
