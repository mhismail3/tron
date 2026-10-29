import { normalizePublicDisplayURL } from "../util/public-display-url.js";
import { APP_ID } from "../modules/apps/apps-folder-format.js";
import { admitBrowserToolReference } from "./browser-tool-reference.js";
import {
  DISPLAY_ARTIFACT_ID_PATTERN,
  DISPLAY_MAXIMUM_ARTIFACT_BYTES,
  isDisplayArtifactKind,
} from "./display-artifact-store.js";
import {
  BROWSER_LIVE_VIEW_SCHEMA, DISPLAY_SCHEMA, NATIVE_LIVE_VIEW_SCHEMA,
  type DisplayArtifactDescriptor, type DisplayKind, type DisplayProjection, type DisplaySurface, type LiveViewDescriptor,
} from "../modules/display/contract.js";

const DISPLAY_EMBEDDED_MEDIA_MAXIMUM_BYTES = 50 * 1_024 * 1_024;

function hasOnlyKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  const admitted = new Set(allowed);
  return Object.keys(value).every((key) => admitted.has(key));
}

export function boundedString(value: unknown, minimum: number, maximumBytes: number): value is string {
  return typeof value === "string" && Buffer.byteLength(value) >= minimum
    && Buffer.byteLength(value) <= maximumBytes
    && !/[\u0000-\u001f\u007f]/.test(value);
}

function surface(value: unknown): value is DisplaySurface {
  return value === "sheet" || value === "inline" || value === "floating";
}

function displayKind(value: unknown): value is DisplayKind {
  return ["image", "markdown", "text", "code", "pdf", "html", "video", "audio", "document", "webpage", "hls", "browser_live", "native_live"].includes(String(value));
}

export function eligibleDisplaySurfaces(kind: DisplayKind, artifactSize?: number): DisplaySurface[] {
  switch (kind) {
    case "image": return ["sheet", "inline", "floating"];
    case "video": case "audio":
      return artifactSize !== undefined && artifactSize > DISPLAY_EMBEDDED_MEDIA_MAXIMUM_BYTES
        ? ["sheet"]
        : ["sheet", "inline", "floating"];
    case "markdown": case "text": case "code": case "pdf": return ["sheet", "inline"];
    case "html": return ["sheet", "floating"];
    case "document": case "webpage": case "hls": return ["sheet"];
    case "browser_live": case "native_live": return ["sheet", "floating"];
  }
}

/** Both tool entrypoints consume an admitted projection; browser receipts are
 * bound to the canonical call, not inferred from neighboring display results. */
export function admitToolDisplayProjection(
  toolName: string | undefined, value: unknown, toolCallId: unknown, sessionId?: string,
): DisplayProjection | undefined {
  const reference = admitBrowserToolReference(toolName, toolCallId, value, sessionId);
  if (!reference) return admitDisplayProjection(toolName, value);
  const liveView = reference.descriptor;
  return admitDisplayProjection("display", { display: {
    schema: DISPLAY_SCHEMA, displayId: liveView.viewId, revision: 1,
    title: liveView.title, altText: "Read-only live browser", kind: "browser_live",
    presentation: { requestedSurface: reference.automatic ? "floating" : "sheet", inlineTapAction: "sheet" },
    eligibleSurfaces: eligibleDisplaySurfaces("browser_live"),
    fallbackText: liveView.fallbackText, liveView, ...(reference.app ? { app: reference.app } : {}),
  } });
}

/** Strictly promotes the reserved display tool's canonical details into the
 * typed mobile contract. Unknown or malformed details remain ordinary tool
 * output and cannot select an active renderer. */
function admitDisplayProjection(toolName: string | undefined, value: unknown): DisplayProjection | undefined {
  if (toolName !== "display" || !value || typeof value !== "object") return undefined;
  const root = value as Record<string, unknown>;
  if (!hasOnlyKeys(root, ["display"])) return undefined;
  const candidate = root.display;
  if (!candidate || typeof candidate !== "object") return undefined;
  const item = candidate as Record<string, unknown>;
  if (!hasOnlyKeys(item, [
    "schema", "displayId", "revision", "title", "caption", "altText", "kind",
    "presentation", "eligibleSurfaces", "fallbackText", "artifact", "markdownImages", "remoteURL", "liveView", "app",
  ])) return undefined;
  if (item.schema !== DISPLAY_SCHEMA || !boundedString(item.displayId, 1, 200)
    || item.revision !== 1 || !boundedString(item.title, 1, 256)
    || !boundedString(item.altText, 1, 2_048) || !boundedString(item.fallbackText, 1, 4_096)
    || !displayKind(item.kind)) return undefined;
  if (item.caption !== undefined && !boundedString(item.caption, 1, 4_096)) return undefined;
  const preference = item.presentation;
  if (!preference || typeof preference !== "object") return undefined;
  const presentation = preference as Record<string, unknown>;
  if (!hasOnlyKeys(presentation, ["requestedSurface", "inlineTapAction"])
    || !surface(presentation.requestedSurface)
    || (presentation.inlineTapAction !== "sheet" && presentation.inlineTapAction !== "none")) return undefined;
  if (!Array.isArray(item.eligibleSurfaces) || item.eligibleSurfaces.length < 1
    || item.eligibleSurfaces.length > 3 || !item.eligibleSurfaces.every(surface)
    || new Set(item.eligibleSurfaces).size !== item.eligibleSurfaces.length
    || item.eligibleSurfaces[0] !== "sheet") return undefined;

  let app: DisplayProjection["app"];
  if (item.app !== undefined) {
    if (!item.app || typeof item.app !== "object" || Array.isArray(item.app)) return undefined;
    const ref = item.app as Record<string, unknown>;
    if (!hasOnlyKeys(ref, ["id", "contentRevision"]) || typeof ref.id !== "string"
      || !APP_ID.test(ref.id) || typeof ref.contentRevision !== "string"
      || !/^[a-f0-9]{64}$/.test(ref.contentRevision)) return undefined;
    app = { id: ref.id, contentRevision: ref.contentRevision };
  }
  let artifact: DisplayArtifactDescriptor | undefined;
  if (item.artifact !== undefined) {
    if (!item.artifact || typeof item.artifact !== "object") return undefined;
    const source = item.artifact as Record<string, unknown>;
    if (!hasOnlyKeys(source, ["id", "name", "mimeType", "size", "kind"])
      || !boundedString(source.id, 1, 200) || !DISPLAY_ARTIFACT_ID_PATTERN.test(source.id)
      || !boundedString(source.name, 1, 160) || /[\\/]/.test(source.name)
      || !boundedString(source.mimeType, 1, 200) || !Number.isSafeInteger(source.size)
      || (source.size as number) < 1 || (source.size as number) > DISPLAY_MAXIMUM_ARTIFACT_BYTES
      || !isDisplayArtifactKind(source.kind) || source.kind !== item.kind) return undefined;
    artifact = {
      id: source.id,
      name: source.name,
      mimeType: source.mimeType,
      size: source.size as number,
      kind: source.kind,
    };
  }

  let markdownImages: DisplayProjection["markdownImages"];
  if (item.markdownImages !== undefined) {
    if (item.kind !== "markdown" || !Array.isArray(item.markdownImages)
      || item.markdownImages.length < 1 || item.markdownImages.length > 16) return undefined;
    markdownImages = [];
    let bytes = 0;
    const destinations = new Set<string>();
    for (const entry of item.markdownImages) {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) return undefined;
      const image = entry as Record<string, unknown>;
      if (!hasOnlyKeys(image, ["destination", "artifact"]) || !boundedString(image.destination, 1, 4_096)
        || destinations.has(image.destination)) return undefined;
      const projection = admitDisplayProjection("display", { display: {
        schema: DISPLAY_SCHEMA, displayId: item.displayId, revision: 1,
        title: item.title, altText: item.altText, kind: "image",
        presentation: item.presentation, eligibleSurfaces: eligibleDisplaySurfaces("image"),
        fallbackText: item.fallbackText, artifact: image.artifact,
      } });
      if (!projection?.artifact) return undefined;
      bytes += projection.artifact.size;
      if (bytes > 25 * 1_024 * 1_024) return undefined;
      destinations.add(image.destination);
      markdownImages.push({ destination: image.destination, artifact: projection.artifact });
    }
  }

  let liveView: LiveViewDescriptor | undefined;
  if (item.liveView !== undefined) {
    if (!item.liveView || typeof item.liveView !== "object") return undefined;
    const source = item.liveView as Record<string, unknown>;
    // The display kind pins the one admitted live-view schema.
    const liveSchema = item.kind === "native_live" ? NATIVE_LIVE_VIEW_SCHEMA : BROWSER_LIVE_VIEW_SCHEMA;
    if (!hasOnlyKeys(source, ["schema", "viewId", "generation", "title", "fallbackText"])
      || source.schema !== liveSchema
      || !boundedString(source.viewId, 1, 200)
      || !boundedString(source.generation, 1, 200)
      || !boundedString(source.title, 1, 256)
      || !boundedString(source.fallbackText, 1, 4_096)) return undefined;
    liveView = {
      schema: liveSchema,
      viewId: source.viewId,
      generation: source.generation,
      title: source.title,
      fallbackText: source.fallbackText,
    };
  }

  let remoteURL: string | undefined;
  if (item.remoteURL !== undefined) {
    if (!boundedString(item.remoteURL, 1, 8_192)) return undefined;
    remoteURL = normalizePublicDisplayURL(item.remoteURL);
    if (!remoteURL) return undefined;
  }
  const sources = [artifact !== undefined, remoteURL !== undefined, liveView !== undefined].filter(Boolean).length;
  if (sources !== 1) return undefined;
  if (artifact && (item.kind === "webpage" || item.kind === "hls" || item.kind === "browser_live" || item.kind === "native_live")) return undefined;
  if (remoteURL && item.kind !== "webpage" && item.kind !== "hls") return undefined;
  if (liveView && item.kind !== "browser_live" && item.kind !== "native_live") return undefined;

  const projectedEligibleSurfaces = item.eligibleSurfaces as DisplaySurface[];
  const eligible = eligibleDisplaySurfaces(item.kind, artifact?.size);
  if (eligible.length !== projectedEligibleSurfaces.length
    || !eligible.every((value, index) => projectedEligibleSurfaces[index] === value)) return undefined;

  return {
    schema: DISPLAY_SCHEMA,
    displayId: item.displayId,
    revision: 1,
    title: item.title,
    ...(item.caption === undefined ? {} : { caption: item.caption as string }),
    altText: item.altText,
    kind: item.kind,
    presentation: {
      requestedSurface: presentation.requestedSurface,
      inlineTapAction: presentation.inlineTapAction,
    },
    eligibleSurfaces: eligible,
    fallbackText: item.fallbackText,
    ...(app ? { app } : {}),
    ...(artifact ? { artifact } : {}),
    ...(markdownImages ? { markdownImages } : {}),
    ...(remoteURL ? { remoteURL } : {}),
    ...(liveView ? { liveView } : {}),
  };
}

export function displayReferences(entries: readonly unknown[], sessionId: string): { artifacts: string[]; liveViews: Set<string> } {
  const ids = new Set<string>();
  const liveViews = new Set<string>();
  for (const entry of entries) {
    if (!entry || typeof entry !== "object") continue;
    const value = entry as { type?: unknown; message?: { role?: unknown; toolName?: unknown; toolCallId?: unknown; details?: unknown } };
    if (value.type !== "message" || value.message?.role !== "toolResult") continue;
    const details = value.message.details;
    const display = admitToolDisplayProjection(
      typeof value.message.toolName === "string" ? value.message.toolName : undefined,
      details, value.message.toolCallId, sessionId,
    );
    if (display?.artifact) ids.add(display.artifact.id);
    for (const image of display?.markdownImages ?? []) ids.add(image.artifact.id);
    if (display?.liveView) liveViews.add(`${display.liveView.viewId}\0${display.liveView.generation}`);
    const nested = details && typeof details === "object" && !Array.isArray(details)
      ? (details as Record<string, unknown>).tronNested : undefined;
    const nestedDisplays = nested && typeof nested === "object" && !Array.isArray(nested)
      ? (nested as Record<string, unknown>).display : undefined;
    if (Array.isArray(nestedDisplays)) for (const item of nestedDisplays) {
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const nestedDisplay = admitDisplayProjection("display", { display: (item as Record<string, unknown>).display });
      if (nestedDisplay?.artifact) ids.add(nestedDisplay.artifact.id);
      for (const image of nestedDisplay?.markdownImages ?? []) ids.add(image.artifact.id);
    }
    const browserLiveViews = nested && typeof nested === "object" && !Array.isArray(nested)
      ? (nested as Record<string, unknown>).browserLiveViews : undefined;
    if (Array.isArray(browserLiveViews)) for (const item of browserLiveViews) {
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const reference = admitBrowserToolReference("agent_browser", value.message.toolCallId,
        { tronBrowserReference: (item as Record<string, unknown>).receipt }, sessionId);
      if (reference) liveViews.add(`${reference.descriptor.viewId}\0${reference.descriptor.generation}`);
    }
  }
  return { artifacts: [...ids], liveViews };
}
