import { dirname, join } from "node:path";
import { GatewayError } from "../errors.js";
import type { DisplayArtifactStore } from "./display-artifact-store.js";
import type { DisplayArtifactDescriptor, DisplayMarkdownImage } from "../modules/display/contract.js";

/** Snapshot standalone relative image blocks, never a live filesystem resolver.
 * Child artifacts use the same branch admission, retention and media bounds as
 * the document. No source paths or external fetch authority reach the client. */
export async function ingestMarkdownImages(
  store: DisplayArtifactStore, root: string, path: string, sessionID: string,
  document: DisplayArtifactDescriptor, signal?: AbortSignal,
): Promise<DisplayMarkdownImage[]> {
  if (document.kind !== "markdown") return [];
  const lease = await store.acquire(document.id, sessionID);
  let source: string;
  try {
    const chunks: Buffer[] = [];
    for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk));
    source = Buffer.concat(chunks).toString("utf8");
  } finally { await lease.release(); }
  const result: DisplayMarkdownImage[] = [];
  const seen = new Set<string>();
  let fence: { marker: string; count: number } | undefined;
  let bytes = 0;
  try {
    for (const line of source.split(/\r?\n/)) {
      if (signal?.aborted) throw new DOMException("Display operation aborted", "AbortError");
      if (/^( {4}|\t)/.test(line)) continue;
      const trimmed = line.trim();
      const marker = /^(?:(`{3,})|(~{3,}))/.exec(trimmed)?.[0];
      if (fence) {
        if (marker?.[0] === fence.marker && marker.length >= fence.count && trimmed === marker) fence = undefined;
        continue;
      }
      if (marker) { fence = { marker: marker[0]!, count: marker.length }; continue; }
      const destination = /^!\[[^\]\n]*\]\(([^)\s]+)\)$/.exec(trimmed)?.[1];
      if (!destination || seen.has(destination)) continue;
      seen.add(destination);
      if (seen.size > 16) break;
      // A document grants only visible children of its own source directory.
      // Do not normalize traversal, URL syntax or encoded path separators into
      // authority; ingest additionally rejects symlinks and uses no-follow opens.
      if (destination.length > 4_096 || /[:%?#\\]/.test(destination)
        || destination.split("/").some(part => !part || part.startsWith(".") || Buffer.byteLength(part) > 255)
        || !/\.(png|jpe?g|gif|webp)$/i.test(destination)) continue;
      let artifact: DisplayArtifactDescriptor;
      try { artifact = await store.ingest(root, join(dirname(path), destination), sessionID); }
      catch (error) {
        // Missing or refused children remain explicit unavailable image blocks;
        // operational storage failures must not be disguised as a valid snapshot.
        if (error instanceof GatewayError && ["invalid_request", "conflict"].includes(error.code)) continue;
        throw error;
      }
      if (bytes + artifact.size > 25 * 1_024 * 1_024) {
        await store.revoke(artifact.id, sessionID);
        break;
      }
      bytes += artifact.size;
      result.push({ destination, artifact });
    }
    if (signal?.aborted) throw new DOMException("Display operation aborted", "AbortError");
    return result;
  } catch (error) {
    await Promise.all(result.map(image => store.revoke(image.artifact.id, sessionID)));
    throw error;
  }
}
