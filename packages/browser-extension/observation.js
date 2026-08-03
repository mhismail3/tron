import {
  MAX_ELEMENTS,
  MAX_SCREENSHOT_BYTES,
  MAX_TABS,
  sanitizeVisibleUrl,
} from "./protocol.js";
import {
  cancellableDelay,
  isRequestCancelled,
  throwIfCancelled,
} from "./request-lifecycle.js";
import {
  applyElementAction,
  applyFixedKey,
  collectObservation,
} from "./page-actions.js";

const observations = new Map();

export function removeObservation(tabId) {
  observations.delete(tabId);
}

export async function listTabs() {
  const tabs = await chrome.tabs.query({});
  const bounded = tabs
    .filter((tab) => !tab.incognito && tab.id && isWebUrl(tab.url))
    .slice(0, MAX_TABS)
    .map((tab) => ({
      tabId: tab.id,
      windowId: tab.windowId,
      active: Boolean(tab.active),
      title: String(tab.title ?? "").slice(0, 200),
      url: sanitizeVisibleUrl(tab.url ?? ""),
    }));
  return { tabs: bounded, truncated: tabs.length > bounded.length };
}

export async function observeTab(tabId) {
  const results = await chrome.scripting.executeScript({
    target: { tabId },
    func: collectObservation,
    args: [MAX_ELEMENTS],
  });
  const raw = results[0]?.result;
  if (!raw || !Array.isArray(raw.elements)) {
    throw new Error("observation_failed");
  }
  const observationId = `obs:${tabId}:${raw.documentToken}:${Date.now().toString(36)}`;
  const targets = new Map();
  const elements = raw.elements.map((element, index) => {
    const elementRef = `element:${index + 1}`;
    targets.set(elementRef, {
      selector: element.selector,
      documentToken: raw.documentToken,
    });
    return {
      elementRef,
      role: element.role,
      name: element.name,
      text: element.text,
      tag: element.tag,
      disabled: element.disabled,
      bounds: element.bounds,
    };
  });
  observations.set(tabId, { observationId, targets });
  return {
    observationId,
    tabId,
    title: String(raw.title ?? "").slice(0, 200),
    url: sanitizeVisibleUrl(raw.url ?? ""),
    viewport: raw.viewport,
    text: String(raw.text ?? "").slice(0, 6000),
    elements,
    truncated: Boolean(raw.truncated),
  };
}

export async function screenshotTab(requestId, tab) {
  throwIfCancelled(requestId);
  const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, {
    format: "jpeg",
    quality: 50,
  });
  throwIfCancelled(requestId);
  if (new TextEncoder().encode(dataUrl).length > MAX_SCREENSHOT_BYTES) {
    throw new Error("screenshot_oversized");
  }
  return {
    tabId: tab.id,
    mediaType: "image/jpeg",
    dataBase64: dataUrl.replace(/^data:image\/jpeg;base64,/, ""),
  };
}

export async function executeElementAction(requestId, tabId, action, kind) {
  const target = resolveTarget(tabId, action.observationId, action.elementRef);
  throwIfCancelled(requestId);
  const result = await chrome.scripting.executeScript({
    target: { tabId },
    func: applyElementAction,
    args: [target, kind, kind === "type" ? action.text : "", kind === "type" && action.replace],
  });
  throwIfCancelled(requestId);
  if (result[0]?.result !== "applied") {
    throw new Error(result[0]?.result ?? "element_action_failed");
  }
}

export async function executeKey(requestId, tabId, action) {
  const target =
    action.observationId && action.elementRef
      ? resolveTarget(tabId, action.observationId, action.elementRef)
      : undefined;
  throwIfCancelled(requestId);
  const result = await chrome.scripting.executeScript({
    target: { tabId },
    func: applyFixedKey,
    args: [target, action.key],
  });
  throwIfCancelled(requestId);
  if (result[0]?.result !== "applied") {
    throw new Error(result[0]?.result ?? "key_action_failed");
  }
}

export async function observeAfterAction(requestId, tabId) {
  await cancellableDelay(requestId, 150);
  throwIfCancelled(requestId);
  try {
    const result = {
      actionApplied: true,
      observation: await observeTab(tabId),
    };
    throwIfCancelled(requestId);
    return result;
  } catch (error) {
    if (isRequestCancelled(requestId)) {
      throw new Error("browser_request_cancelled");
    }
    throw new Error("observe_after_action_failed");
  }
}

function resolveTarget(tabId, observationId, elementRef) {
  const observation = observations.get(tabId);
  if (!observation || observation.observationId !== observationId) {
    throw new Error("stale_observation");
  }
  const target = observation.targets.get(elementRef);
  if (!target) {
    throw new Error("unknown_element");
  }
  return target;
}

function isWebUrl(raw) {
  return typeof raw === "string" && /^(https?):\/\//i.test(raw);
}
