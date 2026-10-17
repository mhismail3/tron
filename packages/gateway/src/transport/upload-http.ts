import type { IncomingMessage, ServerResponse } from "node:http";
import { finished, pipeline } from "node:stream/promises";
import { GatewayError } from "../errors.js";
import type { UploadStore } from "../machine/upload-store.js";
import type { GatewayLogger } from "./logger.js";

export interface UploadHttpDependencies {
  options: {
    uploads: UploadStore;
    logger: Pick<GatewayLogger, "log">;
  };
  completeRequestBody(request: IncomingMessage): AsyncGenerator<Buffer>;
  sendJson(response: ServerResponse, status: number, value: unknown): void;
}

function diagnosticRequestID(request: IncomingMessage): string | undefined {
  const value = request.headers["x-tron-request-id"];
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(value)
    ? value.toLowerCase()
    : undefined;
}

function diagnosticCode(error: unknown): string {
  if (error instanceof GatewayError) {
    return ["busy", "unauthenticated", "not_found", "invalid_request"].includes(error.code)
      ? error.code
      : "gateway_failure";
  }
  return error instanceof Error ? "exception" : "unknown";
}

/**
 * Dispatch only upload routes. A miss is synchronous so later authenticated
 * routes retain their existing credential cut and are never delayed here.
 */
export function handleUploadHttp(
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  signal: AbortSignal,
  dependencies: UploadHttpDependencies,
): Promise<void> | undefined {
  if (request.method === "POST" && url.pathname === "/v1/uploads") {
    return receiveUpload(request, response, url, dependencies);
  }
  if (request.method === "DELETE" && url.pathname.startsWith("/v1/uploads/")) {
    return discardUpload(url, response, dependencies);
  }
  if (request.method === "GET" && url.pathname.startsWith("/v1/uploads/")) {
    return serveUpload(url, response, signal, dependencies);
  }
  return undefined;
}

async function receiveUpload(
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  dependencies: UploadHttpDependencies,
): Promise<void> {
  const requestID = diagnosticRequestID(request);
  const startedAt = performance.now();
  let bodyBytesConsumed: number | undefined;
  let stagedBytes: number | undefined;
  if (requestID !== undefined) {
    dependencies.options.logger.log("info", "Authenticated attachment upload received", {
      event: "http.upload.phase", source: "transport", requestID, step: "received",
    });
  }
  try {
    await dependencies.options.uploads.withBodyAdmission(async () => {
      const name = url.searchParams.get("name") ?? "attachment";
      const mimeType = request.headers["content-type"] ?? "application/octet-stream";
      const rawDeclared = request.headers["content-length"];
      const declaredBytes = rawDeclared === undefined ? undefined : Number(rawDeclared);
      const observedBody = async function* (): AsyncGenerator<Uint8Array> {
        for await (const chunk of dependencies.completeRequestBody(request)) {
          bodyBytesConsumed = (bodyBytesConsumed ?? 0) + chunk.byteLength;
          yield chunk;
        }
      };
      const upload = await dependencies.options.uploads.saveStream(name, mimeType, observedBody(), declaredBytes);
      stagedBytes = upload.size;
      if (requestID !== undefined) {
        dependencies.options.logger.log("info", "Attachment body staged", {
          event: "http.upload.phase", source: "transport", requestID, step: "staged",
          durationMs: Math.max(0, Math.round(performance.now() - startedAt)), counts: { bytes: upload.size },
        });
      }
      try {
        if (response.destroyed) throw new GatewayError("busy", "Upload response was retired", true);
        dependencies.sendJson(response, 201, { upload: { id: upload.id, name: upload.name, mimeType: upload.mimeType, size: upload.size } });
        await finished(response, { readable: false, cleanup: true });
      } catch (error) {
        // Body completion is not receipt publication. Drop only abandoned
        // staging; discard's serialized claim check protects an attachment
        // already owned by an accepted prompt, even in a close/claim race.
        try { await dependencies.options.uploads.discard(upload.id); }
        catch (cleanupError) {
          if (!(cleanupError instanceof GatewayError && ["conflict", "not_found"].includes(cleanupError.code))) {
            dependencies.options.logger.log("warning", "Abandoned upload cleanup failed", { event: "http.upload-cleanup", source: "transport" });
          }
        }
        throw error;
      }
    });
    if (requestID !== undefined) {
      dependencies.options.logger.log("info", "HTTP attachment upload response finished", {
        event: "http.upload", source: "transport", requestID,
        outcome: "response-finished", durationMs: Math.max(0, Math.round(performance.now() - startedAt)),
        ...(stagedBytes === undefined ? {} : { counts: { bytes: stagedBytes } }),
      });
    }
  } catch (error) {
    if (requestID !== undefined) {
      dependencies.options.logger.log("warning", "HTTP attachment upload failed", {
        event: "http.upload", source: "transport", requestID,
        outcome: "failure", code: diagnosticCode(error),
        durationMs: Math.max(0, Math.round(performance.now() - startedAt)),
        ...(bodyBytesConsumed === undefined ? {} : { counts: { bodyBytesConsumed } }),
      });
    }
    throw error;
  }
}

async function discardUpload(
  url: URL,
  response: ServerResponse,
  dependencies: UploadHttpDependencies,
): Promise<void> {
  const id = decodeURIComponent(url.pathname.slice("/v1/uploads/".length));
  await dependencies.options.uploads.discard(id);
  response.writeHead(204, { "cache-control": "no-store" });
  response.end();
}

async function serveUpload(
  url: URL,
  response: ServerResponse,
  signal: AbortSignal,
  dependencies: UploadHttpDependencies,
): Promise<void> {
  const id = decodeURIComponent(url.pathname.slice("/v1/uploads/".length));
  const lease = await dependencies.options.uploads.acquire(id, signal);
  try {
    response.writeHead(200, {
      "content-type": lease.mimeType,
      "content-length": lease.size,
      "content-disposition": `inline; filename*=UTF-8''${encodeURIComponent(lease.name)}`,
      "cache-control": "private, max-age=300",
      "x-content-type-options": "nosniff",
    });
    response.flushHeaders();
    await pipeline(lease.stream, response);
  } finally {
    await lease.release();
  }
}
