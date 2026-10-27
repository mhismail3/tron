export const DISPLAY_SCHEMA = "tron.display.v1";
export const DISPLAY_CAPABILITY = "display-artifacts.v1";
export const BROWSER_LIVE_VIEW_SCHEMA = "tron.browser-live-view.v1" as const;
export const BROWSER_LIVE_VIEW_CAPABILITY = "browser-live-view.v1" as const;
export const NATIVE_LIVE_VIEW_SCHEMA = "tron.native-live-view.v1" as const;
export const NATIVE_LIVE_VIEW_CAPABILITY = "native-live-view.v1" as const;

export const DISPLAY_ARTIFACT_KINDS = [
  "image", "markdown", "text", "code", "pdf", "html",
  "video", "audio", "document",
] as const;

export type DisplayArtifactKind = (typeof DISPLAY_ARTIFACT_KINDS)[number];

export interface DisplayArtifactDescriptor {
  id: string;
  name: string;
  mimeType: string;
  size: number;
  kind: DisplayArtifactKind;
}

export interface DisplayMarkdownImage {
  destination: string;
  artifact: DisplayArtifactDescriptor;
}

export interface BrowserLiveViewDescriptor {
  schema: typeof BROWSER_LIVE_VIEW_SCHEMA;
  viewId: string;
  generation: string;
  title: string;
  fallbackText: string;
}
export interface NativeLiveViewDescriptor extends Omit<BrowserLiveViewDescriptor, "schema"> {
  schema: typeof NATIVE_LIVE_VIEW_SCHEMA;
}
export type LiveViewDescriptor = BrowserLiveViewDescriptor | NativeLiveViewDescriptor;

export type DisplaySurface = "sheet" | "inline" | "floating";
export type DisplayInlineTapAction = "sheet" | "none";
export type DisplayKind = DisplayArtifactKind | "webpage" | "hls" | "browser_live" | "native_live";

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
  markdownImages?: DisplayMarkdownImage[];
  remoteURL?: string;
  liveView?: LiveViewDescriptor;
}
