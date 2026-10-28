import type { DisplayOwner } from "../../display/display-modules.js";
import { GatewayError } from "../../errors.js";
import { SOURCE_BYTES } from "./swift-app-format.js";

/** The existing display owner grants and pins these exact bytes. Apps never
 * opens a client-supplied path or invents a second artifact grant. */
export async function readSwiftDisplaySource(lease: Awaited<ReturnType<DisplayOwner["acquireArtifact"]>>): Promise<string> {
  try {
    if (lease.totalSize < 1 || lease.totalSize > SOURCE_BYTES || lease.size !== lease.totalSize || lease.rangeStart !== 0) {
      throw new GatewayError("invalid_request", "Install App requires a complete bounded Swift source artifact");
    }
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of lease.stream) {
      const bytes = Buffer.from(chunk as Uint8Array); size += bytes.length;
      if (size > SOURCE_BYTES) throw new GatewayError("invalid_request", "App source exceeds its byte limit");
      chunks.push(bytes);
    }
    const bytes = Buffer.concat(chunks);
    if (bytes.length !== lease.totalSize) throw new GatewayError("conflict", "The displayed Swift source was truncated");
    try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
    catch { throw new GatewayError("invalid_request", "App source must be valid UTF-8"); }
  } finally { await lease.release(); }
}
