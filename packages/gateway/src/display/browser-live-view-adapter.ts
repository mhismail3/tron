import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { browserCDPEndpoint, BrowserLiveViewRegistry } from "./browser-live-view.js";
import { sealBrowserToolReference } from "./browser-tool-reference.js";
import type { ExtensionOwner } from "../protocol/types.js";

interface RecordValue { [key: string]: unknown }

function record(value: unknown): RecordValue | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as RecordValue : undefined;
}

function successful(result: RecordValue, details: RecordValue): boolean {
  return result.isError !== true && details.exitCode === 0 && details.resultCategory === "success";
}

function browserGeneration(cdpUrl: string, runtimeGeneration: string): string | undefined {
  try {
    const url = browserCDPEndpoint(cdpUrl);
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
 * Adapts the trusted provider's native browser binding (including failed actions
 * and exact retirement), or its explicit structured `get cdp-url`, into a view. Model text, arbitrary URLs and stream
 * status ports never establish browser authority. The CDP UUID is retained as
 * the endpoint generation; the owning runtime generation is also required by
 * the caller and is never derived from the unsafe native launchHash number.
 */
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
  if (!isTrustedBrowserOwner(input.owner, input.toolName)
    || !input.views.isLoadActive(input.sessionId, input.loadToken)) return input.result;
  const result = record(input.result);
  const details = record(result?.details);
  if (!result || !Array.isArray(result.content) || !details || details.agentBrowserStarted !== true) return input.result;
  // Provider-normalized metadata covers args, semantic, batch and isolated
  // script results without a second parser or a hidden, potentially launching CLI call.
  const binding = record(details.browserBinding);
  const bound = binding?.schema === "agent-browser.browser-binding.v1"
    && (binding.state === "active" || (binding.state === "closed" && binding.owned === true))
    && typeof binding.owned === "boolean" && typeof binding.cdpUrl === "string"
    && typeof binding.session === "string" && binding.session.length > 0 && Buffer.byteLength(binding.session) <= 393
    && !/[\u0000-\u001f\u007f]/.test(binding.session);
  const explicitGet = details.command === "get" && details.subcommand === "cdp-url" && successful(result, details)
    && typeof details.sessionName === "string" && details.sessionName.length > 0;
  if (details.browserBinding !== undefined && !bound) return input.result;
  const data = record(details.data);
  const cdpUrl = bound ? binding.cdpUrl
    : explicitGet && typeof data?.cdpUrl === "string" ? data.cdpUrl : undefined;
  if (typeof cdpUrl !== "string") return input.result;
  const generation = browserGeneration(cdpUrl, input.runtimeGeneration);
  if (!generation || !input.views.isLoadActive(input.sessionId, input.loadToken)) return input.result;
  try {
    const registration = {
      sessionId: input.sessionId,
      viewId: randomUUID(),
      generation,
      loadToken: input.loadToken,
      cdpUrl,
      title: "Browser view",
      fallbackText: "The original browser is no longer available.",
    };
    // A delayed close affects only its exact endpoint/generation, never a scope alias.
    const descriptor = bound && binding.state === "closed"
      ? input.views.retireBrowser(registration)
      : input.views.register(registration);
    // Pi sends tool content to the model; details alone only serves UI. Make
    // the opaque handle usable without asking the model to inspect host state.
    const source = { kind: "browser_live", viewId: descriptor.viewId, generation: descriptor.generation };
    return { ...result,
      content: explicitGet
        ? [...result.content, { type: "text", text: `Read-only live browser source for display: ${JSON.stringify(source)}` }]
        : result.content,
      details: { ...details, browserLiveView: descriptor,
        tronBrowserReference: sealBrowserToolReference(input.sessionId, input.toolCallId, descriptor, !bound || binding.state === "active") },
    };
  } catch (error) {
    if (error instanceof GatewayError) return { ...result, details: { ...details, browserLiveViewError: error.message } };
    return input.result;
  }
}
