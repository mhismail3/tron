import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { DISPLAY_SCHEMA, eligibleDisplaySurfaces, normalizePublicDisplayURL, type DisplayInlineTapAction, type DisplayKind, type DisplayProjection, type DisplaySurface } from "./display-contract.js";
import type { DisplayArtifactStore } from "./display-artifact-store.js";
import { GatewayError } from "../errors.js";

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
      kind: Type.Literal("public_url"),
      url: Type.String({ minLength: 1, maxLength: 8_192 }),
      media: Type.Union([Type.Literal("webpage"), Type.Literal("hls")]),
    }, { additionalProperties: false }),
  ]),
  presentation: Type.Optional(presentationSchema),
}, { additionalProperties: false });

type Parameters = {
  title: string;
  caption?: string;
  altText: string;
  fallbackText?: string;
  source: { kind: "path"; path: string } | { kind: "public_url"; url: string; media: "webpage" | "hls" };
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
  if (Buffer.byteLength(value) < 1 || Buffer.byteLength(value) > maximumBytes
    || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new GatewayError("invalid_request", `${name} exceeds the bounded display text contract`);
  }
}

/** First-party inline Pi extension. Its only filesystem capability is the
 * Gateway-owned bounded artifact-ingestion closure. */
export function createTronDisplayExtension(input: {
  sessionId: () => string;
  cwd: () => string;
  artifacts: DisplayArtifactStore;
}): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "display",
      label: "Display",
      description: "Present a project artifact or public HTTPS webpage in Tron chat. Sheet is the default; inline and floating are applied only to compatible content. Local paths must be relative to the session workspace.",
      promptSnippet: "Display visual or document content in Tron chat when it materially improves the response.",
      promptGuidelines: [
        "Use display at your discretion when visual, document, media, or webpage content materially improves the app experience.",
        "Always provide concise alt text and never include secrets or credential-bearing URLs.",
        "Prefer the default sheet surface; use inline for bounded content that belongs in transcript flow and floating for content worth keeping visible while chatting.",
        "Write generated HTML or media to a project file before displaying it; do not pass inline bytes or base64.",
      ],
      parameters,
      executionMode: "sequential",
      execute: async (_toolCallId, params: Parameters, signal) => {
        if (signal?.aborted) throw new Error("Display operation aborted");
        requireBoundedText(params.title, "Display title", 256);
        requireBoundedText(params.altText, "Display alt text", 2_048);
        if (params.caption) requireBoundedText(params.caption, "Display caption", 4_096);
        if (params.fallbackText) requireBoundedText(params.fallbackText, "Display fallback text", 4_096);
        const requestedSurface = params.presentation?.surface ?? "sheet";
        const inlineTapAction = params.presentation?.inlineTapAction ?? "sheet";
        const sessionID = input.sessionId();
        const displayID = randomUUID();
        let kind: DisplayKind;
        let artifact: DisplayProjection["artifact"];
        let remoteURL: string | undefined;
        if (params.source.kind === "path") {
          artifact = await input.artifacts.ingest(input.cwd(), params.source.path, sessionID);
          if (signal?.aborted) {
            await input.artifacts.revoke(artifact.id, sessionID);
            throw new Error("Display operation aborted");
          }
          kind = artifact.kind;
        } else {
          remoteURL = publicURL(params.source.url);
          kind = params.source.media;
        }
        const fallbackText = params.fallbackText ?? params.altText;
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
        };
        return {
          content: [{ type: "text", text: `Displayed “${params.title}”. ${fallbackText}` }],
          details: { display },
        };
      },
    });
  };
}
