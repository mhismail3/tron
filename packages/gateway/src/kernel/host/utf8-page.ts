import { GatewayError } from "../../errors.js";

export function utf8Page(text: string, source: string, offset = 0, limit = 4096) {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 4096) throw new GatewayError("invalid_request", `${source}: invalid page: offset must be 0 or more and limit 1 to 4096 bytes`);
  const bytes = Buffer.from(text);
  if (offset > bytes.length || (offset < bytes.length && (bytes[offset]! & 0xc0) === 0x80)) throw new GatewayError("invalid_request", `${source}: offset ${offset} is not a UTF-8 character start within the ${bytes.length}-byte report page`);
  let end = Math.min(bytes.length, offset + limit);
  while (end < bytes.length && end > offset && (bytes[end]! & 0xc0) === 0x80) end--;
  if (end === offset && end < bytes.length) throw new GatewayError("invalid_request", `${source}: limit is too small for the next UTF-8 character`);
  return { offset, bytes: bytes.length, text: bytes.subarray(offset, end).toString("utf8"), nextOffset: end < bytes.length ? end : null };
}
