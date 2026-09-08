import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { BrowserLiveViewRegistry } from "./browser-live-view.js";
import type { ExtensionOwner } from "../protocol/types.js";

interface RecordValue { [key: string]: unknown }

function record(value: unknown): RecordValue | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as RecordValue : undefined;
}

function successful(result: RecordValue, details: RecordValue): boolean {
  return result.isError !== true && details.exitCode === 0 && details.resultCategory === "success";
}

function browserIdentity(details: RecordValue): string | undefined {
  if (typeof details.sessionName !== "string" || details.sessionName.length === 0) return undefined;
  const namespace = typeof details.namespace === "string" ? details.namespace : "";
  return `${namespace.length}:${namespace}${details.sessionName}`;
}

function browserGeneration(cdpUrl: string, runtimeGeneration: string): string | undefined {
  try {
    const url = new URL(cdpUrl);
    const browserUUID = url.pathname.slice("/devtools/browser/".length);
    return browserUUID ? `${runtimeGeneration}:${browserUUID}` : undefined;
  } catch { return undefined; }
}

const TRUSTED_BROWSER_EXTENSION_SOURCES = new Set([
  "git:github.com/fitchmultz/pi-agent-browser-native",
  "git:github.com/fitchmultz/pi-agent-browser-native@d6cde09af8d7757bbfba5a4ffaf83381bb392683",
]);

function isTrustedBrowserOwner(owner: ExtensionOwner, toolName: string): boolean {
  return toolName === "agent_browser" && TRUSTED_BROWSER_EXTENSION_SOURCES.has(owner.source);
}

/**
 * Adapts only the exact trusted browser extension's structured `get cdp-url`
 * result into an opaque Gateway view. Model text, arbitrary URLs and stream
 * status ports never establish browser authority. The CDP UUID is retained as
 * the endpoint generation; the owning runtime generation is also required by
 * the caller and is never derived from the unsafe native launchHash number.
 */
export function observeTrustedAgentBrowserResult(input: {
  owner: ExtensionOwner;
  toolName: string;
  result: unknown;
  sessionId: string;
  runtimeGeneration: string;
  loadToken: string;
  views: BrowserLiveViewRegistry;
}): unknown {
  if (!isTrustedBrowserOwner(input.owner, input.toolName)
    || !input.views.isLoadActive(input.sessionId, input.loadToken)) return input.result;
  const result = record(input.result);
  const details = record(result?.details);
  if (!result || !Array.isArray(result.content) || !details || !successful(result, details)) return input.result;
  const sessionIdentity = browserIdentity(details);
  if (!sessionIdentity) return input.result;
  // Provider-normalized command metadata also covers explicit --session flags;
  // reparsing the caller's CLI/script/job shape would introduce a second parser.
  if (details.command === "close") {
    input.views.retireBrowser(input.sessionId, sessionIdentity);
    return input.result;
  }
  if (details.command !== "get" || details.subcommand !== "cdp-url"
    || details.resultCategory !== "success" || details.agentBrowserStarted !== true) return input.result;
  const data = record(details.data);
  const cdpUrl = typeof data?.cdpUrl === "string" ? data.cdpUrl : undefined;
  if (!cdpUrl) return input.result;
  const generation = browserGeneration(cdpUrl, input.runtimeGeneration);
  if (!generation || !input.views.isLoadActive(input.sessionId, input.loadToken)) return input.result;
  try {
    const descriptor = input.views.register({
      sessionId: input.sessionId,
      viewId: randomUUID(),
      generation,
      browserIdentity: sessionIdentity,
      loadToken: input.loadToken,
      cdpUrl,
      title: "Browser view",
      fallbackText: "The browser view is unavailable.",
    });
    // Pi sends tool content to the model; details alone only serves UI. Make
    // the opaque handle usable without asking the model to inspect host state.
    const source = { kind: "browser_live", viewId: descriptor.viewId, generation: descriptor.generation };
    return { ...result,
      content: [...result.content, { type: "text", text: `Read-only live browser source for display: ${JSON.stringify(source)}` }],
      details: { ...details, browserLiveView: descriptor },
    };
  } catch (error) {
    if (error instanceof GatewayError) return { ...result, details: { ...details, browserLiveViewError: error.message } };
    return input.result;
  }
}
