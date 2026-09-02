import { isIP } from "node:net";
import {
  DISPLAY_MAXIMUM_ARTIFACT_BYTES,
  type DisplayArtifactDescriptor,
  type DisplayArtifactKind,
} from "./display-artifact-store.js";

export const DISPLAY_SCHEMA = "tron.display.v1";
export const DISPLAY_CAPABILITY = "display-artifacts.v1";
export { DISPLAY_MAXIMUM_ARTIFACT_BYTES };
export const DISPLAY_EMBEDDED_MEDIA_MAXIMUM_BYTES = 50 * 1_024 * 1_024;

const DISPLAY_ARTIFACT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type DisplaySurface = "sheet" | "inline" | "floating";
export type DisplayInlineTapAction = "sheet" | "none";
export type DisplayKind = DisplayArtifactKind | "webpage" | "hls";

export interface DisplayPresentationPreference {
  requestedSurface: DisplaySurface;
  inlineTapAction: DisplayInlineTapAction;
}

export interface DisplayProjection {
  schema: typeof DISPLAY_SCHEMA;
  displayId: string;
  revision: number;
  title: string;
  caption?: string;
  altText: string;
  kind: DisplayKind;
  presentation: DisplayPresentationPreference;
  eligibleSurfaces: DisplaySurface[];
  fallbackText: string;
  artifact?: DisplayArtifactDescriptor;
  remoteURL?: string;
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  const admitted = new Set(allowed);
  return Object.keys(value).every((key) => admitted.has(key));
}

function boundedString(value: unknown, minimum: number, maximumBytes: number): value is string {
  return typeof value === "string" && Buffer.byteLength(value) >= minimum
    && Buffer.byteLength(value) <= maximumBytes
    && !/[\u0000-\u001f\u007f]/.test(value);
}

function blockedIPv4(host: string): boolean {
  const octets = host.split(".").map(Number);
  if (octets.length !== 4 || octets.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) return true;
  const [a, b, c] = octets as [number, number, number, number];
  return a === 0 || a === 10 || a === 127 || a >= 224
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && (b === 0 || b === 168))
    || (a === 198 && (b === 18 || b === 19))
    || (a === 198 && b === 51 && c === 100)
    || (a === 203 && b === 0 && c === 113);
}

function blockedIPv6(host: string): boolean {
  const normalized = host.toLowerCase().replace(/^\[|\]$/g, "");
  if (normalized === "::" || normalized === "::1") return true;
  const first = Number.parseInt(normalized.split(":", 1)[0] || "0", 16);
  if (!Number.isFinite(first) || first < 0x2000 || first > 0x3fff
    || normalized.startsWith("2001:db8:")) return true;
  if (normalized.startsWith("::ffff:")) {
    const tail = normalized.slice("::ffff:".length).split(":");
    if (tail.length !== 2) return true;
    const high = Number.parseInt(tail[0]!, 16);
    const low = Number.parseInt(tail[1]!, 16);
    if (!Number.isFinite(high) || !Number.isFinite(low)) return true;
    return blockedIPv4(`${high >> 8}.${high & 0xff}.${low >> 8}.${low & 0xff}`);
  }
  return false;
}

/** Canonical public-URL admission shared by tool creation and projection.
 * Remote content is gesture-gated in Safari, but persisted descriptors still
 * reject local/reserved literals, local DNS suffixes, query credentials, and
 * fragments. */
export function normalizePublicDisplayURL(input: string): string | undefined {
  if (Buffer.byteLength(input) < 1 || Buffer.byteLength(input) > 8_192) return undefined;
  let url: URL;
  try { url = new URL(input); } catch { return undefined; }
  if (url.protocol !== "https:" || url.username || url.password || url.href.includes("?") || url.href.includes("#")) return undefined;
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.+$/g, "");
  if (!host || host === "localhost" || host.endsWith(".localhost")
    || [".local", ".internal", ".home", ".lan"].some((suffix) => host.endsWith(suffix))) return undefined;
  const family = isIP(host);
  if ((family === 4 && blockedIPv4(host)) || (family === 6 && blockedIPv6(host))) return undefined;
  return url.toString();
}

function surface(value: unknown): value is DisplaySurface {
  return value === "sheet" || value === "inline" || value === "floating";
}

function displayKind(value: unknown): value is DisplayKind {
  return ["image", "markdown", "text", "code", "pdf", "html", "video", "audio", "document", "webpage", "hls"].includes(String(value));
}

function artifactKind(value: unknown): value is DisplayArtifactKind {
  return ["image", "markdown", "text", "code", "pdf", "html", "video", "audio", "document"].includes(String(value));
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
  }
}

/** Strictly promotes the reserved display tool's canonical details into the
 * typed mobile contract. Unknown or malformed details remain ordinary tool
 * output and cannot select an active renderer. */
export function admitDisplayProjection(toolName: string | undefined, value: unknown): DisplayProjection | undefined {
  if (toolName !== "display" || !value || typeof value !== "object") return undefined;
  const root = value as Record<string, unknown>;
  if (!hasOnlyKeys(root, ["display"])) return undefined;
  const candidate = root.display;
  if (!candidate || typeof candidate !== "object") return undefined;
  const item = candidate as Record<string, unknown>;
  if (!hasOnlyKeys(item, [
    "schema", "displayId", "revision", "title", "caption", "altText", "kind",
    "presentation", "eligibleSurfaces", "fallbackText", "artifact", "remoteURL",
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

  let artifact: DisplayArtifactDescriptor | undefined;
  if (item.artifact !== undefined) {
    if (!item.artifact || typeof item.artifact !== "object") return undefined;
    const source = item.artifact as Record<string, unknown>;
    if (!hasOnlyKeys(source, ["id", "name", "mimeType", "size", "kind"])
      || !boundedString(source.id, 1, 200) || !DISPLAY_ARTIFACT_ID.test(source.id)
      || !boundedString(source.name, 1, 160) || /[\\/]/.test(source.name)
      || !boundedString(source.mimeType, 1, 200) || !Number.isSafeInteger(source.size)
      || (source.size as number) < 1 || (source.size as number) > DISPLAY_MAXIMUM_ARTIFACT_BYTES
      || !artifactKind(source.kind) || source.kind !== item.kind) return undefined;
    artifact = {
      id: source.id,
      name: source.name,
      mimeType: source.mimeType,
      size: source.size as number,
      kind: source.kind,
    };
  }

  let remoteURL: string | undefined;
  if (item.remoteURL !== undefined) {
    if (!boundedString(item.remoteURL, 1, 8_192)) return undefined;
    remoteURL = normalizePublicDisplayURL(item.remoteURL);
    if (!remoteURL) return undefined;
  }
  if ((artifact === undefined) === (remoteURL === undefined)) return undefined;
  if (artifact && (item.kind === "webpage" || item.kind === "hls")) return undefined;
  if (remoteURL && item.kind !== "webpage" && item.kind !== "hls") return undefined;

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
    ...(artifact ? { artifact } : {}),
    ...(remoteURL ? { remoteURL } : {}),
  };
}

export function displayArtifactIDs(entries: readonly unknown[]): string[] {
  const ids = new Set<string>();
  for (const entry of entries) {
    if (!entry || typeof entry !== "object") continue;
    const value = entry as { type?: unknown; message?: { role?: unknown; toolName?: unknown; details?: unknown } };
    if (value.type !== "message" || value.message?.role !== "toolResult") continue;
    const display = admitDisplayProjection(
      typeof value.message.toolName === "string" ? value.message.toolName : undefined,
      value.message.details,
    );
    if (display?.artifact) ids.add(display.artifact.id);
  }
  return [...ids];
}
