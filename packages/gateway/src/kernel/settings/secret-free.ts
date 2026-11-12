import { GatewayError } from "../../errors.js";
import { redactCredentials } from "../../util/credential-redaction.js";

export const SECRET_NAME = /(token|secret|password|passwd|api[-_]?key|apikey|credential|bearer|authorization)/iu;

export function refuseSetting(label: string, reason: string): never {
  throw new GatewayError("invalid_request", `${label} ${reason}`);
}

export function secretFreeText(text: string, label: string, what: string, hint: string): string {
  if (redactCredentials(text) !== text) refuseSetting(label, `${what} carries a credential; ${hint}`);
  if (/[\u0000\r\n]/u.test(text)) refuseSetting(label, `${what} has a control character`);
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
