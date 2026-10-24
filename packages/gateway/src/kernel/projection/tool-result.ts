import type { ExtensionOwner, TranscriptItem } from "../../protocol/types.js";

export interface ToolReferences {
  artifacts: readonly string[];
  liveViews: ReadonlySet<string>;
}

/** Module policy over canonical tool details and their retained resources, resolved at each call site. */
export interface ToolResultProjection {
  beginBrowserLoad(sessionId: string, runtimeGeneration: string): BrowserResultObservation | undefined;
  references(entries: readonly unknown[], sessionId: string): ToolReferences;
  initializeStorage(): Promise<void>;
  reconcile(entries: readonly unknown[], sessionId: string): Promise<void>;
  display(toolName: string | undefined, details: unknown, toolCallId: unknown, sessionId?: string): Extract<TranscriptItem, { kind: "message" }>["display"];
  observeBrowserResult(input: {
    owner: ExtensionOwner;
    toolName: string;
    toolCallId: string;
    result: unknown;
    sessionId: string;
    runtimeGeneration: string;
    loadToken: string;
  }): unknown;
}

export type ToolDisplayProjection = ToolResultProjection["display"];

export type BrowserResultObservation = Pick<Parameters<ToolResultProjection["observeBrowserResult"]>[0],
  "sessionId" | "runtimeGeneration" | "loadToken"> & { observeResult: ToolResultProjection["observeBrowserResult"] };
