import {
  HOST_NAME,
  PROTOCOL_VERSION,
  safeError,
  validateHostRequest,
} from "./protocol.js";
import { executeAction } from "./actions.js";
import {
  clearConsentState,
  getConsentedTabId,
} from "./consent.js";
import {
  admitRequest,
  cancelAllRequests,
  cancelRequest,
  finishRequest,
  throwIfCancelled,
} from "./request-lifecycle.js";

let port;
let operationChain = Promise.resolve();

export function connectNativeHost() {
  if (port) {
    return;
  }
  port = chrome.runtime.connectNative(HOST_NAME);
  port.onMessage.addListener((message) => {
    if (message?.kind === "cancel") {
      cancelRequest(message);
      return;
    }
    let request;
    try {
      request = validateHostRequest(message);
    } catch (error) {
      respond(message?.requestId ?? "invalid", false, undefined, safeError(error));
      return;
    }
    if (!admitRequest(request.requestId)) {
      respond(request.requestId, false, undefined, "browser_request_queue_full");
      return;
    }
    operationChain = operationChain
      .then(() => handleHostRequest(request))
      .catch(() => undefined);
  });
  port.onDisconnect.addListener(async () => {
    cancelAllRequests();
    port = undefined;
    const tabId = await getConsentedTabId();
    if (tabId) {
      await clearConsentState(tabId);
    }
  });
  port.postMessage({ kind: "ready", protocolVersion: PROTOCOL_VERSION });
}

async function handleHostRequest(message) {
  const { requestId, action } = message;
  try {
    throwIfCancelled(requestId);
    const result = await executeAction(requestId, action);
    throwIfCancelled(requestId);
    respond(requestId, true, result);
  } catch (error) {
    respond(requestId, false, undefined, safeError(error));
  } finally {
    finishRequest(requestId);
  }
}

function respond(requestId, ok, result, error) {
  port?.postMessage({
    kind: "response",
    requestId,
    ok,
    ...(ok ? { result } : { error }),
  });
}
