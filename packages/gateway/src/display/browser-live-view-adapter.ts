import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { browserCDPEndpoint, BrowserLiveViewRegistry } from "./browser-live-view.js";
import { sealBrowserToolReference } from "./browser-tool-reference.js";
import type { ExtensionOwner } from "../protocol/types.js";

interface RecordValue { [key: string]: unknown }

function record(value: unknown): RecordValue | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as RecordValue : undefined;
}

export function isTrustedBrowserExtensionSource(source: string): boolean {
  return source === "builtin:agent-browser";
}

export function observeTrustedAgentBrowserResult(input: {
  owner: ExtensionOwner;
  toolName: string;
  toolCallId: string;
  result: unknown;
  sessionId: string;
  runtimeGeneration: string;
  loadToken: string;
  views: BrowserLiveViewRegistry;
}): unknown {
  if (input.toolName !== "agent_browser" || !isTrustedBrowserExtensionSource(input.owner.source)
    || !input.views.isLoadActive(input.sessionId, input.loadToken)) return input.result;
  const result = record(input.result);
  const details = record(result?.details);
  const data = record(details?.data);
  if (!result || !Array.isArray(result.content) || !details || details.agentBrowserStarted !== true
    || result.isError === true || details.exitCode !== 0 || details.resultCategory !== "success"
    || details.command !== "get" || details.subcommand !== "cdp-url"
    || typeof details.sessionName !== "string" || !details.sessionName || typeof data?.cdpUrl !== "string") return input.result;
  try {
    const endpoint = browserCDPEndpoint(data.cdpUrl);
    const descriptor = input.views.register({
      sessionId: input.sessionId,
      viewId: randomUUID(),
      generation: `${input.runtimeGeneration}:${endpoint.pathname.slice("/devtools/browser/".length)}`,
      loadToken: input.loadToken,
      cdpUrl: data.cdpUrl,
      title: "Browser view",
      fallbackText: "The original browser is no longer available.",
    });
    const source = { kind: "browser_live", viewId: descriptor.viewId, generation: descriptor.generation };
    return { ...result,
      content: [...result.content, { type: "text", text: `Read-only live browser source for display: ${JSON.stringify(source)}` }],
      details: { ...details, browserLiveView: descriptor,
        tronBrowserReference: sealBrowserToolReference(input.sessionId, input.toolCallId, descriptor, true) },
    };
  } catch (error) {
    return error instanceof GatewayError ? { ...result, details: { ...details, browserLiveViewError: error.message } } : input.result;
  }
}
