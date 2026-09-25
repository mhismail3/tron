import { randomUUID } from "node:crypto";
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { DISPLAY_SCHEMA, boundedString, eligibleDisplaySurfaces, normalizePublicDisplayURL, type DisplayInlineTapAction, type DisplayKind, type DisplayProjection, type DisplaySurface } from "./display-contract.js";
import type { DisplayArtifactStore } from "./display-artifact-store.js";
import { GatewayError } from "../errors.js";
import { BROWSER_LIVE_VIEW_SCHEMA, type BrowserLiveViewRegistry } from "./browser-live-view.js";
import { NATIVE_LIVE_VIEW_SCHEMA } from "./native-live-view.js";

const presentationSchema = Type.Object({
  surface: Type.Union([Type.Literal("sheet"), Type.Literal("inline"), Type.Literal("floating")]),
  inlineTapAction: Type.Optional(Type.Union([Type.Literal("sheet"), Type.Literal("none")])),
}, { additionalProperties: false });

const parameters = Type.Object({
  title: Type.String({ minLength: 1, maxLength: 256 }),
  caption: Type.Optional(Type.String({ minLength: 1, maxLength: 4_096 })),
  altText: Type.String({ minLength: 1, maxLength: 2_048 }),
  fallbackText: Type.Optional(Type.String({ minLength: 1, maxLength: 4_096 })),
  source: Type.Union([
    Type.Object({
      kind: Type.Literal("path"),
      path: Type.String({ minLength: 1, maxLength: 4_096 }),
    }, { additionalProperties: false }),
    Type.Object({
      kind: Type.Literal("internal_file"),
      path: Type.String({ minLength: 1, maxLength: 4_096 }),
    }, { additionalProperties: false }),
    Type.Object({
      kind: Type.Literal("public_url"),
      url: Type.String({ minLength: 1, maxLength: 8_192 }),
      media: Type.Union([Type.Literal("webpage"), Type.Literal("hls")]),
    }, { additionalProperties: false }),
    Type.Object({
      kind: Type.Union([Type.Literal("browser_live"), Type.Literal("native_live")]),
      viewId: Type.String({ minLength: 1, maxLength: 200 }),
      generation: Type.String({ minLength: 1, maxLength: 200 }),
    }, { additionalProperties: false }),
  ]),
  presentation: Type.Optional(presentationSchema),
}, { additionalProperties: false });

type Parameters = {
  title: string;
  caption?: string;
  altText: string;
  fallbackText?: string;
  source: { kind: "path"; path: string } | { kind: "internal_file"; path: string } | { kind: "public_url"; url: string; media: "webpage" | "hls" } | { kind: "browser_live"; viewId: string; generation: string } | { kind: "native_live"; viewId: string; generation: string };
  presentation?: { surface: DisplaySurface; inlineTapAction?: DisplayInlineTapAction };
};

function publicURL(input: string): string {
  const normalized = normalizePublicDisplayURL(input);
  if (!normalized) {
    throw new GatewayError(
      "invalid_request",
      "Display URLs must be public HTTPS URLs without credentials, query parameters, or fragments",
    );
  }
  return normalized;
}

function requireBoundedText(value: string, name: string, maximumBytes: number): void {
  if (!boundedString(value, 1, maximumBytes)) {
    throw new GatewayError("invalid_request", `${name} exceeds the bounded display text contract`);
  }
}

/** First-party inline Pi extension. Its only filesystem capability is the
 * Gateway-owned bounded artifact-ingestion closure. */
export function createTronDisplayExtension(input: {
  sessionId: () => string;
  cwd: () => string;
  artifacts: DisplayArtifactStore;
  liveViews?: BrowserLiveViewRegistry;
  internalFilesRoot?: () => Promise<string>;
}): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "display",
      label: "Display",
      description: "Present an artifact, public HTTPS webpage, or read-only live browser/Mac window view in Tron chat. Live views default to floating; other content defaults to a sheet. Inline and floating apply only to compatible content. source.kind=path uses a path relative to the session directory; internal_file uses a path relative to Tron's internal workspace files/ directory. Neither accepts absolute paths.",
      promptSnippet: "Proactively display useful visual results in Tron chat; prefer inline image previews when they help the user understand or judge the result.",
      promptGuidelines: [
        "Proactively use display for screenshots, UI/design previews, comparisons, charts, diagrams, or image results when seeing them helps the user understand or judge the result; do not wait to be asked. Prefer presentation.surface=inline for bounded image previews. Skip decorative or redundant images.",
        "Use actual result artifacts where available, crop to the useful area without hiding relevant context, and label mockups or simulator captures honestly. A still image is not proof of animation, interaction, or device validation.",
        "Use display for document, media, or webpage content when it materially improves the response.",
        "Always provide concise alt text and never include secrets or credential-bearing URLs.",
        "Live browser and native window views default to floating and expand into a sheet. Other content defaults to a sheet; use inline for bounded transcript content and floating for content worth keeping visible while chatting.",
        "Write generated HTML or media to a session file or an internal workspace files/ document before calling display; do not pass inline bytes or base64.",
        "For live browser viewing, use source.kind=browser_live with the opaque viewId and generation returned by agent_browser get cdp-url. Never invent a handle, supply a browser endpoint, or launch a browser from a historical display.",
        "For a Mac window use source.kind=native_live with the exact viewId/generation from native_capture view. Capture runs only while viewed; an ended reference cannot restart or select another window.",
      ],
      parameters,
      executionMode: "sequential",
      execute: async (_toolCallId, params: Parameters, signal) => {
        if (signal?.aborted) throw new Error("Display operation aborted");
        requireBoundedText(params.title, "Display title", 256);
        requireBoundedText(params.altText, "Display alt text", 2_048);
        if (params.caption) requireBoundedText(params.caption, "Display caption", 4_096);
        if (params.fallbackText) requireBoundedText(params.fallbackText, "Display fallback text", 4_096);
        const requestedSurface = params.presentation?.surface ?? (params.source.kind === "browser_live" || params.source.kind === "native_live" ? "floating" : "sheet");
        const inlineTapAction = params.presentation?.inlineTapAction ?? "sheet";
        const sessionID = input.sessionId();
        const displayID = randomUUID();
        let kind: DisplayKind;
        let artifact: DisplayProjection["artifact"];
        let remoteURL: string | undefined;
        let liveView: DisplayProjection["liveView"];
        const fallbackText = params.fallbackText ?? params.altText;
        if (params.source.kind === "path" || params.source.kind === "internal_file") {
          if (params.source.kind === "internal_file" && !input.internalFilesRoot) {
            throw new GatewayError("conflict", "Tron internal workspace is unavailable");
          }
          const root = params.source.kind === "path" ? input.cwd() : await input.internalFilesRoot!();
          if (signal?.aborted) throw new Error("Display operation aborted");
          artifact = await input.artifacts.ingest(root, params.source.path, sessionID);
          if (signal?.aborted) {
            await input.artifacts.revoke(artifact.id, sessionID);
            throw new Error("Display operation aborted");
          }
          kind = artifact.kind;
        } else if (params.source.kind === "browser_live" || params.source.kind === "native_live") {
          if (!input.liveViews) throw new GatewayError("conflict", "Live viewing is unavailable");
          liveView = input.liveViews.describe(sessionID, params.source.viewId, params.source.generation);
          const schema = params.source.kind === "native_live" ? NATIVE_LIVE_VIEW_SCHEMA : BROWSER_LIVE_VIEW_SCHEMA;
          if (liveView.schema !== schema) throw new GatewayError("invalid_request", "Live view producer kind differs from its reference");
          kind = params.source.kind;
        } else {
          remoteURL = publicURL(params.source.url);
          kind = params.source.media;
        }
        const display: DisplayProjection = {
          schema: DISPLAY_SCHEMA,
          displayId: displayID,
          revision: 1,
          title: params.title,
          ...(params.caption ? { caption: params.caption } : {}),
          altText: params.altText,
          kind,
          presentation: { requestedSurface, inlineTapAction },
          eligibleSurfaces: eligibleDisplaySurfaces(kind, artifact?.size),
          fallbackText,
          ...(artifact ? { artifact } : {}),
          ...(remoteURL ? { remoteURL } : {}),
          ...(liveView ? { liveView } : {}),
        };
        return {
          content: [{ type: "text", text: `Displayed “${params.title}”. ${fallbackText}` }],
          details: { display },
        };
      },
    });
  };
}
