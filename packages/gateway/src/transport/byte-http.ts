import type { IncomingMessage, ServerResponse } from "node:http";
import { pipeline } from "node:stream/promises";
import { GatewayError, publicError } from "../errors.js";
import type { ByteLease, ByteRange } from "../util/byte-stream.js";
import { parseAppArtifactPath } from "../modules/apps/apps-artifact-resource.js";

interface ArtifactReader {
  acquireArtifact(owner: string, resource: string, range?: ByteRange, signal?: AbortSignal): Promise<ByteLease>;
}
export interface ByteHttpReaders {
  display: ArtifactReader;
  apps?: ArtifactReader;
  sessions: { acquireBlob(id: string, range?: ByteRange, signal?: AbortSignal): Promise<ByteLease> };
}
function parseByteRange(value: string | string[] | undefined): ByteRange | undefined {
  if (value === undefined) return undefined;
  if (Array.isArray(value)) throw new GatewayError("invalid_request", "Only one blob byte range may be requested");
  const match = /^bytes=(\d+)-(\d*)$/.exec(value.trim());
  if (!match) throw new GatewayError("invalid_request", "Blob byte range must use bytes=start-end syntax");
  const start = Number(match[1]), end = match[2] ? Number(match[2]) : undefined;
  if (!Number.isSafeInteger(start) || start < 0 || end !== undefined && (!Number.isSafeInteger(end) || end < start)) {
    throw new GatewayError("invalid_request", "Blob byte range is not satisfiable");
  }
  return end === undefined ? { start } : { start, end };
}
function rangeFailure(response: ServerResponse, error: GatewayError, sendJson: JsonResponder): void {
  const details = error.details as { rangeUnsatisfiable?: unknown; totalSize?: unknown } | undefined;
  if (details?.rangeUnsatisfiable === true && Number.isSafeInteger(details.totalSize)) response.setHeader("content-range", `bytes */${details.totalSize}`);
  sendJson(response, 416, { error: publicError(error) });
}
type JsonResponder = (response: ServerResponse, status: number, value: unknown) => void;
/** Authentication, device revocation, transport admission and read deadlines
 * stay with GatewayServer. Resource owners admit/pin bytes; this one transport
 * writes ranges and always releases their leases, including 304/disconnect. */
export function handleByteHttp(request: IncomingMessage, response: ServerResponse, url: URL, signal: AbortSignal, readers: ByteHttpReaders, sendJson: JsonResponder): Promise<void> | undefined {
  if (request.method !== "GET") return;
  const display = /^\/v1\/sessions\/([^/]+)\/display-artifacts\/([^/]+)$/.exec(url.pathname);
  const appsReader = readers.apps, apps = appsReader ? parseAppArtifactPath(url.pathname) : undefined;
  const blob = url.pathname.startsWith("/v1/blobs/");
  if (!display && !apps && !blob) return;
  return (async () => {
    const immutable = !!display || !!apps;
    let range: ByteRange | undefined;
    try { range = parseByteRange(request.headers.range); }
    catch (error) {
      if (!immutable || !(error instanceof GatewayError) || error.code !== "invalid_request") throw error;
      rangeFailure(response, error, sendJson); return;
    }
    const acquire = (): Promise<ByteLease> => display
      ? readers.display.acquireArtifact(decodeURIComponent(display[1]!), decodeURIComponent(display[2]!), range, signal)
      : apps && appsReader ? appsReader.acquireArtifact(apps.id, apps.revision, range, signal)
        : readers.sessions.acquireBlob(decodeURIComponent(url.pathname.slice("/v1/blobs/".length)), range, signal);
    let lease: ByteLease;
    try { lease = await acquire(); }
    catch (error) {
      const details = error instanceof GatewayError ? error.details as { rangeUnsatisfiable?: unknown; totalSize?: unknown } | undefined : undefined;
      if (immutable && error instanceof GatewayError && error.code === "invalid_request"
        && details?.rangeUnsatisfiable === true && Number.isSafeInteger(details.totalSize)) {
        rangeFailure(response, error, sendJson); return;
      }
      throw error;
    }
    const etag = display ? `\"display-${decodeURIComponent(display[2]!)}\"` : apps ? `\"app-${encodeURIComponent(apps.id)}-${encodeURIComponent(apps.revision)}\"` : undefined;
    const cache = immutable ? "private, immutable, max-age=31536000" : "private, max-age=300";
    try {
      signal.throwIfAborted();
      if (etag && request.headers["if-none-match"] === etag) {
        response.writeHead(304, { etag, "cache-control": cache }); response.end(); return;
      }
      response.writeHead(range ? 206 : 200, {
        "content-type": lease.mimeType, "content-length": lease.size, "accept-ranges": "bytes",
        ...(etag ? { etag } : {}), ...(range ? { "content-range": `bytes ${lease.rangeStart}-${lease.rangeEnd}/${lease.totalSize}` } : {}),
        "cache-control": cache, "x-content-type-options": "nosniff",
      });
      response.flushHeaders();
      await pipeline(lease.stream, response, { signal });
    } finally { await lease.release(); }
  })();
}
