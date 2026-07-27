import {
  HOST_NAME,
  MAX_ELEMENTS,
  MAX_SCREENSHOT_BYTES,
  MAX_TABS,
  PROTOCOL_VERSION,
  safeError,
  sanitizeVisibleUrl,
  validateHostRequest,
} from "./protocol.js";

const CONSENT_KEY = "consentedTabId";
const INDICATOR_ID = "tron-browser-operator-consent-indicator";
const MAX_ACTIVE_REQUESTS = 16;
const CANCEL_TOMBSTONE_MILLISECONDS = 30_000;
const observations = new Map();
const requestStates = new Map();
let port;
let operationChain = Promise.resolve();

chrome.action.onClicked.addListener(async (tab) => {
  if (!tab.id || tab.incognito || !isWebUrl(tab.url)) {
    await setBadge(tab.id, "!", "#b42318");
    return;
  }
  const consentedTabId = await getConsentedTabId();
  if (consentedTabId === tab.id) {
    await disableConsent(tab.id);
    return;
  }
  if (consentedTabId) {
    await disableConsent(consentedTabId);
  }
  await chrome.storage.session.set({ [CONSENT_KEY]: tab.id });
  connectNativeHost();
  await setBadge(tab.id, "ON", "#008f68");
  await ensureConsentIndicator(tab.id);
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  if ((await getConsentedTabId()) === tabId) {
    await clearConsentState(tabId);
  }
  observations.delete(tabId);
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo) => {
  if (changeInfo.status !== "complete" || (await getConsentedTabId()) !== tabId) {
    return;
  }
  observations.delete(tabId);
  try {
    await ensureConsentIndicator(tabId);
    await setBadge(tabId, "ON", "#008f68");
  } catch {
    await clearConsentState(tabId);
  }
});

function connectNativeHost() {
  if (port) {
    return;
  }
  port = chrome.runtime.connectNative(HOST_NAME);
  port.onMessage.addListener((message) => {
    pruneRequestStates();
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
    if (requestStates.size >= MAX_ACTIVE_REQUESTS) {
      respond(request.requestId, false, undefined, "browser_request_queue_full");
      return;
    }
    requestStates.set(request.requestId, {
      cancelledAt: undefined,
      cancellationExpiresAt: undefined,
      cancellationHandlers: new Set(),
    });
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

async function executeAction(requestId, action) {
  throwIfCancelled(requestId);
  if (action.kind === "tabs") {
    return listTabs();
  }
  const tab = await requireForegroundConsent(action.tabId);
  await ensureConsentIndicator(tab.id);
  switch (action.kind) {
    case "observe":
      return observeTab(tab.id);
    case "screenshot":
      return screenshotTab(requestId, tab);
    case "click":
      await executeElementAction(requestId, tab.id, action, "click");
      return observeAfterAction(requestId, tab.id);
    case "type":
      await executeElementAction(requestId, tab.id, action, "type");
      return observeAfterAction(requestId, tab.id);
    case "key":
      await executeKey(requestId, tab.id, action);
      return observeAfterAction(requestId, tab.id);
    case "scroll":
      throwIfCancelled(requestId);
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: (deltaX, deltaY) => window.scrollBy({ left: deltaX, top: deltaY, behavior: "instant" }),
        args: [action.deltaX, action.deltaY],
      });
      throwIfCancelled(requestId);
      return observeAfterAction(requestId, tab.id);
    case "navigate": {
      const completed = waitForTabComplete(requestId, tab.id, 8000);
      throwIfCancelled(requestId);
      await chrome.tabs.update(tab.id, { url: action.url });
      await completed;
      return observeAfterAction(requestId, tab.id);
    }
    default:
      throw new Error("unsupported_action");
  }
}

async function listTabs() {
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

async function observeTab(tabId) {
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

async function screenshotTab(requestId, tab) {
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

async function executeElementAction(requestId, tabId, action, kind) {
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

async function executeKey(requestId, tabId, action) {
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

async function observeAfterAction(requestId, tabId) {
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

async function requireForegroundConsent(tabId) {
  if ((await getConsentedTabId()) !== tabId) {
    throw new Error("foreground_consent_required");
  }
  const active = (await chrome.tabs.query({ active: true, lastFocusedWindow: true }))[0];
  if (!active || active.id !== tabId || active.incognito || !isWebUrl(active.url)) {
    throw new Error("controlled_tab_not_foreground");
  }
  return active;
}

async function ensureConsentIndicator(tabId) {
  await chrome.scripting.executeScript({
    target: { tabId },
    func: (indicatorId) => {
      let indicator = document.getElementById(indicatorId);
      if (!indicator) {
        indicator = document.createElement("div");
        indicator.id = indicatorId;
        indicator.textContent = "Tron is controlling this tab";
        Object.assign(indicator.style, {
          position: "fixed",
          top: "12px",
          right: "12px",
          zIndex: "2147483647",
          padding: "8px 12px",
          borderRadius: "999px",
          background: "#008f68",
          color: "white",
          font: "600 13px -apple-system, BlinkMacSystemFont, sans-serif",
          boxShadow: "0 4px 18px rgba(0,0,0,.28)",
          pointerEvents: "none",
        });
        document.documentElement.appendChild(indicator);
      }
    },
    args: [INDICATOR_ID],
  });
}

async function disableConsent(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: (indicatorId) => document.getElementById(indicatorId)?.remove(),
      args: [INDICATOR_ID],
    });
  } catch {
    // Navigation or permission loss may already have removed the indicator.
  }
  await clearConsentState(tabId);
}

async function clearConsentState(tabId) {
  cancelAllRequests();
  await chrome.storage.session.remove(CONSENT_KEY);
  observations.delete(tabId);
  await setBadge(tabId, "", "#008f68");
}

async function getConsentedTabId() {
  const value = await chrome.storage.session.get(CONSENT_KEY);
  return Number.isSafeInteger(value[CONSENT_KEY]) ? value[CONSENT_KEY] : undefined;
}

async function setBadge(tabId, text, color) {
  if (!tabId) {
    return;
  }
  await chrome.action.setBadgeText({ tabId, text });
  await chrome.action.setBadgeBackgroundColor({ tabId, color });
  await chrome.action.setTitle({
    tabId,
    title: text === "ON" ? "Disable Tron for this tab" : "Enable Tron for this tab",
  });
}

function respond(requestId, ok, result, error) {
  port?.postMessage({
    kind: "response",
    requestId,
    ok,
    ...(ok ? { result } : { error }),
  });
}

function waitForTabComplete(requestId, tabId, timeoutMs) {
  return new Promise((resolve, reject) => {
    let timeout;
    let removeCancellationHandler = () => {};
    const finish = (operation) => {
      clearTimeout(timeout);
      chrome.tabs.onUpdated.removeListener(listener);
      removeCancellationHandler();
      operation();
    };
    timeout = setTimeout(() => {
      finish(() => reject(new Error("navigation_timed_out")));
    }, timeoutMs);
    const listener = (updatedTabId, changeInfo) => {
      if (updatedTabId === tabId && changeInfo.status === "complete") {
        finish(resolve);
      }
    };
    chrome.tabs.onUpdated.addListener(listener);
    removeCancellationHandler = addCancellationHandler(requestId, () => {
      finish(() => reject(new Error("browser_request_cancelled")));
    });
  });
}

function cancelRequest(message) {
  if (
    message.protocolVersion !== PROTOCOL_VERSION ||
    typeof message.requestId !== "string" ||
    !/^[A-Za-z0-9_:.-]{1,128}$/.test(message.requestId) ||
    Object.keys(message).some(
      (key) => !["kind", "protocolVersion", "requestId"].includes(key),
    )
  ) {
    return;
  }
  const state = requestStates.get(message.requestId);
  // A cancellation is meaningful only while its admitted request is queued or
  // running. Late cancellation after completion is ignored, so request IDs do
  // not become permanent tombstones in the service worker.
  if (!state) {
    return;
  }
  const now = performance.now();
  state.cancelledAt = now;
  state.cancellationExpiresAt = now + CANCEL_TOMBSTONE_MILLISECONDS;
  for (const handler of [...state.cancellationHandlers]) {
    handler();
  }
  pruneRequestStates(now);
}

function cancelAllRequests() {
  const now = performance.now();
  for (const state of requestStates.values()) {
    state.cancelledAt = now;
    state.cancellationExpiresAt = now + CANCEL_TOMBSTONE_MILLISECONDS;
    for (const handler of [...state.cancellationHandlers]) {
      handler();
    }
  }
}

function finishRequest(requestId) {
  const state = requestStates.get(requestId);
  state?.cancellationHandlers.clear();
  requestStates.delete(requestId);
}

function pruneRequestStates(now = performance.now()) {
  for (const [requestId, state] of requestStates) {
    if (
      state.cancellationExpiresAt !== undefined &&
      state.cancellationExpiresAt <= now
    ) {
      state.cancelledAt = undefined;
      state.cancellationExpiresAt = undefined;
      state.cancellationHandlers.clear();
      // An expired queued cancellation no longer needs a tombstone; the
      // request remains bounded by the engine deadline and will run normally.
      if (requestStates.size > MAX_ACTIVE_REQUESTS) {
        requestStates.delete(requestId);
      }
    }
  }
}

function isRequestCancelled(requestId) {
  const state = requestStates.get(requestId);
  if (!state?.cancelledAt) {
    return false;
  }
  if (state.cancellationExpiresAt <= performance.now()) {
    state.cancelledAt = undefined;
    state.cancellationExpiresAt = undefined;
    state.cancellationHandlers.clear();
    return false;
  }
  return true;
}

function throwIfCancelled(requestId) {
  if (isRequestCancelled(requestId)) {
    throw new Error("browser_request_cancelled");
  }
}

function addCancellationHandler(requestId, handler) {
  const state = requestStates.get(requestId);
  if (!state) {
    return () => {};
  }
  if (isRequestCancelled(requestId)) {
    handler();
    return () => {};
  }
  state.cancellationHandlers.add(handler);
  return () => state.cancellationHandlers.delete(handler);
}

function cancellableDelay(requestId, milliseconds) {
  return new Promise((resolve, reject) => {
    let removeCancellationHandler = () => {};
    const timeout = setTimeout(() => {
      removeCancellationHandler();
      resolve();
    }, milliseconds);
    removeCancellationHandler = addCancellationHandler(requestId, () => {
      clearTimeout(timeout);
      removeCancellationHandler();
      reject(new Error("browser_request_cancelled"));
    });
  });
}

export const browserOperatorTesting = Object.freeze({
  activeRequestCount: () => requestStates.size,
  cancelledRequestCount: () =>
    [...requestStates.values()].filter((state) => state.cancelledAt !== undefined).length,
});

function isWebUrl(raw) {
  return typeof raw === "string" && /^(https?):\/\//i.test(raw);
}

function collectObservation(maxElements) {
  const documentToken = Math.round(performance.timeOrigin).toString(36);
  const sensitive = (element) => {
    const type = String(element.getAttribute("type") ?? "").toLowerCase();
    const autocomplete = String(element.getAttribute("autocomplete") ?? "").toLowerCase();
    return type === "password" || autocomplete.includes("password");
  };
  const visible = (element) => {
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return (
      style.visibility !== "hidden" &&
      style.display !== "none" &&
      rect.width > 0 &&
      rect.height > 0
    );
  };
  const cssPath = (element) => {
    if (element.id && /^[A-Za-z][\w:.-]*$/.test(element.id)) {
      return `#${CSS.escape(element.id)}`;
    }
    const parts = [];
    let current = element;
    while (current && current.nodeType === Node.ELEMENT_NODE && parts.length < 8) {
      let part = current.tagName.toLowerCase();
      if (current.parentElement) {
        const siblings = [...current.parentElement.children].filter(
          (sibling) => sibling.tagName === current.tagName,
        );
        if (siblings.length > 1) {
          part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
        }
      }
      parts.unshift(part);
      current = current.parentElement;
    }
    return parts.join(" > ");
  };
  const candidates = [
    ...document.querySelectorAll(
      'a[href],button,input:not([type="hidden"]),textarea,select,[role="button"],[role="link"],[role="textbox"],[tabindex]:not([tabindex="-1"]),[contenteditable="true"]',
    ),
  ].filter((element) => visible(element) && !sensitive(element));
  const elements = candidates.slice(0, maxElements).map((element) => {
    const rect = element.getBoundingClientRect();
    const name =
      element.getAttribute("aria-label") ||
      element.getAttribute("placeholder") ||
      element.getAttribute("title") ||
      "";
    return {
      selector: cssPath(element),
      role: String(element.getAttribute("role") || element.tagName.toLowerCase()).slice(0, 40),
      name: String(name).trim().slice(0, 200),
      text: String(element.innerText || element.textContent || "").trim().slice(0, 300),
      tag: element.tagName.toLowerCase(),
      disabled: Boolean(element.disabled || element.getAttribute("aria-disabled") === "true"),
      bounds: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      },
    };
  });
  return {
    documentToken,
    title: document.title,
    url: location.href,
    viewport: { width: innerWidth, height: innerHeight, scrollX, scrollY },
    text: String(document.body?.innerText ?? "").slice(0, 6000),
    elements,
    truncated: candidates.length > elements.length,
  };
}

function applyElementAction(target, kind, text, replace) {
  if (Math.round(performance.timeOrigin).toString(36) !== target.documentToken) {
    return "stale_document";
  }
  const element = document.querySelector(target.selector);
  if (!element) {
    return "element_missing";
  }
  const type = String(element.getAttribute("type") ?? "").toLowerCase();
  const autocomplete = String(element.getAttribute("autocomplete") ?? "").toLowerCase();
  if (type === "password" || autocomplete.includes("password")) {
    return "credential_field_rejected";
  }
  element.scrollIntoView({ block: "center", inline: "center" });
  element.focus();
  if (kind === "click") {
    element.click();
    return "applied";
  }
  if (!("value" in element) && !element.isContentEditable) {
    return "element_not_editable";
  }
  if (element.isContentEditable) {
    if (replace) {
      element.textContent = "";
    }
    document.execCommand("insertText", false, text);
  } else {
    const prototype = Object.getPrototypeOf(element);
    const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
    const nextValue = replace ? text : `${element.value ?? ""}${text}`;
    setter ? setter.call(element, nextValue) : (element.value = nextValue);
  }
  element.dispatchEvent(new Event("input", { bubbles: true }));
  element.dispatchEvent(new Event("change", { bubbles: true }));
  return "applied";
}

function applyFixedKey(target, key) {
  if (
    target &&
    Math.round(performance.timeOrigin).toString(36) !== target.documentToken
  ) {
    return "stale_document";
  }
  const element = target ? document.querySelector(target.selector) : document.activeElement;
  if (!element) {
    return "element_missing";
  }
  element.focus();
  const actualKey = key === "Space" ? " " : key;
  for (const type of ["keydown", "keyup"]) {
    element.dispatchEvent(
      new KeyboardEvent(type, {
        key: actualKey,
        bubbles: true,
        cancelable: true,
      }),
    );
  }
  if (key === "Enter") {
    if (element instanceof HTMLButtonElement || element.getAttribute("role") === "button") {
      element.click();
    } else if (element.form) {
      element.form.requestSubmit();
    }
  }
  return "applied";
}
