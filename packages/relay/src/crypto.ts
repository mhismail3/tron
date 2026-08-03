export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  return hexEncode(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer),
    ),
  );
}

export async function stableProviderId(requestId: string): Promise<string> {
  const digest = await sha256Hex(new TextEncoder().encode(requestId));
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-${digest.slice(
    12,
    16,
  )}-${digest.slice(16, 20)}-${digest.slice(20, 32)}`;
}

export function pemBytes(value: string): Uint8Array<ArrayBuffer> {
  const body = value
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

export function base64Url(value: string | Uint8Array): string {
  const bytes =
    typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export function hexBytes(value: string): Uint8Array {
  if (value.length % 2 !== 0) return new Uint8Array();
  return Uint8Array.from(
    value.match(/.{2}/g) ?? [],
    (pair) => Number.parseInt(pair, 16),
  );
}

export function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < left.byteLength; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function hexEncode(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
