import { extname } from "node:path";

export type ArtifactMedia = "image" | "video" | "audio" | "pdf" | "markdown" | "html" | "text" | "code" | "document";
export interface AppFileFormat {
  kind: "swift" | "web" | "document" | "image" | "video" | "link" | "live";
  media: ArtifactMedia; mimeType: string; maximumBytes: number; buffer: boolean;
}
const MiB = 1024 * 1024;
/** The folder edge admits the same media byte ceilings as ordinary display:
 * 5 MiB text, 25 MiB images/documents and 2 GiB streamed audio/video. Executable
 * Swift and web bundles retain their separate, smaller execution bounds. */
export function appFileFormat(path: string): AppFileFormat | undefined {
  if (path === "entry.link.json" || path === "entry.live.json") return {
    kind: path === "entry.link.json" ? "link" : "live", media: "text", mimeType: "application/json", maximumBytes: 32 * 1024, buffer: true,
  };
  const extension = extname(path).toLowerCase();
  const text = (media: ArtifactMedia, mimeType: string): AppFileFormat => ({ kind: "document", media, mimeType, maximumBytes: 5 * MiB, buffer: true });
  const binary = (kind: "image" | "video" | "document", media: ArtifactMedia, mimeType: string, maximumBytes: number): AppFileFormat => ({ kind, media, mimeType, maximumBytes, buffer: false });
  switch (extension) {
    case ".swift": return { kind: "swift", media: "code", mimeType: "text/plain; charset=utf-8", maximumBytes: 320_000, buffer: true };
    case ".html": case ".htm": return { ...text("html", "text/html; charset=utf-8"), kind: "web" };
    case ".md": case ".markdown": return text("markdown", "text/markdown; charset=utf-8");
    case ".json": return text("code", "application/json");
    case ".txt": case ".log": case ".csv": return text("text", "text/plain; charset=utf-8");
    case ".ts": case ".tsx": case ".js": case ".css": case ".py": case ".go": case ".rs":
    case ".java": case ".kt": case ".sh": case ".sql": case ".xml": case ".yaml": case ".yml": case ".toml":
      return text("code", "text/plain; charset=utf-8");
    case ".svg": return text("html", "image/svg+xml");
    case ".png": return binary("image", "image", "image/png", 25 * MiB);
    case ".jpg": case ".jpeg": return binary("image", "image", "image/jpeg", 25 * MiB);
    case ".gif": return binary("image", "image", "image/gif", 25 * MiB);
    case ".heic": case ".heif": return binary("image", "image", "image/heic", 25 * MiB);
    case ".bmp": return binary("image", "image", "image/bmp", 25 * MiB);
    case ".bin": return binary("document", "document", "application/octet-stream", 25 * MiB);
    case ".rtf": return binary("document", "document", "application/rtf", 25 * MiB);
    case ".webp": return binary("image", "image", "image/webp", 25 * MiB);
    case ".pdf": return binary("document", "pdf", "application/pdf", 25 * MiB);
    case ".mp4": return binary("video", "video", "video/mp4", 2 * 1024 * MiB);
    case ".mov": return binary("video", "video", "video/quicktime", 2 * 1024 * MiB);
    case ".m4v": return binary("video", "video", "video/x-m4v", 2 * 1024 * MiB);
    case ".mp3": return binary("document", "audio", "audio/mpeg", 2 * 1024 * MiB);
    case ".m4a": return binary("document", "audio", "audio/mp4", 2 * 1024 * MiB);
    case ".wav": return binary("document", "audio", "audio/wav", 2 * 1024 * MiB);
    default: return undefined;
  }
}
export function appSignatureMatches(prefix: Buffer, mimeType: string): boolean {
  const ascii = prefix.toString("ascii");
  switch (mimeType) {
    case "image/png": return prefix.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    case "image/heic": return prefix.subarray(4, 8).toString("ascii") === "ftyp";
    case "image/bmp": return ascii.startsWith("BM");
    case "application/rtf": return ascii.startsWith("{\\rtf");
    case "image/jpeg": return prefix[0] === 255 && prefix[1] === 216 && prefix[2] === 255;
    case "image/gif": return ascii.startsWith("GIF87a") || ascii.startsWith("GIF89a");
    case "image/webp": return ascii.startsWith("RIFF") && ascii.slice(8, 12) === "WEBP";
    case "application/pdf": return ascii.startsWith("%PDF-");
    case "video/mp4": case "video/quicktime": case "video/x-m4v": case "audio/mp4": return prefix.subarray(4, 8).toString("ascii") === "ftyp";
    case "audio/mpeg": return ascii.startsWith("ID3") || prefix[0] === 255 && (prefix[1] ?? 0) >= 224;
    case "audio/wav": return ascii.startsWith("RIFF") && ascii.slice(8, 12) === "WAVE";
    default: return true;
  }
}
