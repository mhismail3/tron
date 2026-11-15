import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { BrowserAttachError } from "./browser-live-cdp.js";
import { browserCDPEndpoint, BrowserLiveViewRegistry } from "./browser-live-view.js";
import { sealBrowserToolReference } from "./browser-tool-reference.js";
import type { ExtensionOwner } from "../protocol/types.js";
import type { BrowserLiveViewDescriptor } from "../modules/display/contract.js";

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
    const browserUUID = url.pathname === "/devtools/browser" ? randomUUID() : url.pathname.slice("/devtools/browser/".length);
    return browserUUID ? `${runtimeGeneration}:${browserUUID}` : undefined;
  } catch { return undefined; }
}

const TRUSTED_BROWSER_EXTENSION_SOURCES = new Set([
  "git:github.com/fitchmultz/pi-agent-browser-native",
  "git:github.com/fitchmultz/pi-agent-browser-native@6346982c0fec9e00b9f3ef6997cfb2d6f6893c6d",
]);

export function isTrustedBrowserExtensionSource(source: string): boolean {
  return TRUSTED_BROWSER_EXTENSION_SOURCES.has(source);
}

function isTrustedBrowserOwner(owner: ExtensionOwner, toolName: string): boolean {
  return toolName === "agent_browser" && isTrustedBrowserExtensionSource(owner.source);
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
  if (!isTrustedBrowserOwner(input.owner, input.toolName)
    || !input.views.isLoadActive(input.sessionId, input.loadToken)) return input.result;
  const result = record(input.result);
  const details = record(result?.details);
  if (!result || !Array.isArray(result.content) || !details || details.agentBrowserStarted !== true) return input.result;
  const content = result.content;
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
  const publish = (descriptor: BrowserLiveViewDescriptor): unknown => {
    const source = { kind: "browser_live", viewId: descriptor.viewId, generation: descriptor.generation };
    return { ...result,
      content: explicitGet
        ? [...content, { type: "text", text: `Read-only live browser source for display: ${JSON.stringify(source)}` }]
        : content,
      details: { ...details, browserLiveView: descriptor,
        tronBrowserReference: sealBrowserToolReference(input.sessionId, input.toolCallId, descriptor, !bound || binding.state === "active") },
    };
  };
  const failed = (error: unknown): unknown => {
    if (!input.views.isLoadActive(input.sessionId, input.loadToken)) return input.result;
    return error instanceof GatewayError || error instanceof BrowserAttachError
      ? { ...result, details: { ...details, browserLiveViewError: error.message } }
      : input.result;
  };
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
    if (browserCDPEndpoint(cdpUrl).pathname === "/devtools/browser") {
      if (bound && binding.state === "closed") return input.result;
      return input.views.registerAttached(registration).then(publish, failed);
    }
    return publish(bound && binding.state === "closed" ? input.views.retireBrowser(registration) : input.views.register(registration));
  } catch (error) { return failed(error); }
}
