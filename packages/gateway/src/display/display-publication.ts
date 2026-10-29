import { createHash } from "node:crypto";
import { Readable } from "node:stream";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { appFileFormat } from "../modules/apps/apps-file-format.js";
import type { AppsFolderIndex } from "../modules/apps/apps-folder-index.js";
import type { DisplayProjection } from "../modules/display/contract.js";
import type { DisplayArtifactStore } from "./display-artifact-store.js";

function appTitle(value: string): string {
  value = value.trim() || "Artifact";
  if (Buffer.byteLength(value) <= 80) return value;
  let clipped = "";
  for (const { segment } of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(value)) {
    if (Buffer.byteLength(clipped + segment) > 77) break;
    clipped += segment;
  }
  return clipped + "…";
}

/** Producers supply already admitted immutable snapshots; only the Apps index
 * interprets existing entries, kinds, manifests, identity and membership. */
export async function publishDisplay(index: AppsFolderIndex, store: DisplayArtifactStore, session: string,
  display: DisplayProjection, source: { root: string; path: string } | undefined, signal?: AbortSignal): Promise<NonNullable<DisplayProjection["app"]>> {
  if (!display.artifact || !source) {
    const reference = display.remoteURL ? { kind: "url", media: display.kind, url: display.remoteURL }
      : display.liveView ? { kind: "live", sessionId: session, liveView: display.liveView } : undefined;
    if (!reference) throw new GatewayError("invalid_request", "Display has no admitted source");
    const bytes = Buffer.from(JSON.stringify({ version: 1, ...reference })), entry = display.remoteURL ? "entry.link.json" : "entry.live.json";
    const row = await index.publish({ entry, title: appTitle(display.title),
      permissions: { data: "none", feeds: [], network: display.remoteURL ? [new URL(display.remoteURL).origin] : [] }, files: [{ path: entry, size: bytes.length,
      digest: createHash("sha256").update(bytes).digest("hex"), acquire: async signal => {
        signal.throwIfAborted(); const stream = Readable.from([bytes]);
        return { stream, size: bytes.length, totalSize: bytes.length, rangeStart: 0, rangeEnd: bytes.length - 1,
          mimeType: "application/json", release: async () => { stream.destroy(); } };
      } }] }, signal);
    return { id: row.id, contentRevision: row.contentRevision };
  }
  const primary = store.snapshot(display.artifact.id, session);
  signal?.throwIfAborted();
  const selected = await index.selectDisplayedFile(join(source.root, source.path), primary.digest);
  const name = display.artifact.name, format = appFileFormat(name);
  // Source snapshots are data: reserved descriptor names and executable suffixes
  // must not change their admission policy or promote them into executable apps.
  const entry = name.toLowerCase() === "app.json" || format?.kind === "link" || format?.kind === "live"
    ? "content.json" : format?.kind === "swift" ? `${name}.txt` : format ? name : "content.bin";
  const row = selected ?? await index.publish({ entry, title: appTitle(display.title),
    ...(["html", "code"].includes(display.kind) ? { kind: "document" as const } : {}),
    files: [{ path: entry, ...primary }, ...(display.markdownImages ?? []).map(image =>
      ({ path: image.destination, ...store.snapshot(image.artifact.id, session) }))] }, signal);
  signal?.throwIfAborted();
  return { id: row.id, contentRevision: row.contentRevision };
}
