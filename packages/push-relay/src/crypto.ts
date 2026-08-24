const encoder = new TextEncoder();

export function utf8(value: string): Uint8Array {
  return encoder.encode(value);
}

export function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((sum, part) => sum + part.byteLength, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.byteLength;
  }
  return result;
}

export function ownedBuffer(value: Uint8Array): ArrayBuffer {
  return Uint8Array.from(value).buffer;
}

export async function sha256(value: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", ownedBuffer(value)));
}

export async function sha256Hex(value: Uint8Array): Promise<string> {
  return bytesToHex(await sha256(value));
}

export function bytesToHex(value: Uint8Array): string {
  return [...value].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function hexBytes(value: string): Uint8Array {
  if (value.length % 2 !== 0 || !/^[0-9a-f]*$/i.test(value)) return new Uint8Array();
  return Uint8Array.from(value.match(/.{2}/g)?.map((byte) => Number.parseInt(byte, 16)) ?? []);
}

export function base64Url(value: string | Uint8Array): string {
  const bytes = typeof value === "string" ? utf8(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export function decodeBase64Url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid_base64url");
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function pemBytes(pem: string): Uint8Array {
  const body = pem.replace(/-----BEGIN [^-]+-----|-----END [^-]+-----|\s/g, "");
  const binary = atob(body);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  const length = Math.max(left.byteLength, right.byteLength);
  let difference = left.byteLength ^ right.byteLength;
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

export async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    ownedBuffer(utf8(secret)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return bytesToHex(new Uint8Array(await crypto.subtle.sign("HMAC", key, ownedBuffer(utf8(value)))));
}

export async function stableProviderId(requestId: string): Promise<string> {
  const digest = await sha256(utf8(requestId));
  const hex = bytesToHex(digest.slice(0, 16));
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function randomOpaqueId(byteCount = 24): string {
  return base64Url(crypto.getRandomValues(new Uint8Array(byteCount)));
}

export function canonicalRegistration(fields: {
  version: 1;
  challengeId: string;
  challenge: string;
  keyId: string;
  apnsToken: string;
  route: string;
  bindingHash: string;
}): Uint8Array {
  // Lexicographic keys match Swift JSONEncoder.sortedKeys byte-for-byte.
  return utf8(JSON.stringify({
    apnsToken: fields.apnsToken,
    bindingHash: fields.bindingHash,
    challenge: fields.challenge,
    challengeId: fields.challengeId,
    keyId: fields.keyId,
    route: fields.route,
    version: fields.version,
  }));
}
