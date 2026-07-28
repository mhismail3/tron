import {
  executeElementAction,
  executeKey,
  listTabs,
  observeAfterAction,
  observeTab,
  screenshotTab,
} from "./observation.js";
import {
  ensureConsentIndicator,
  requireForegroundConsent,
} from "./consent.js";
import {
  addCancellationHandler,
  throwIfCancelled,
} from "./request-lifecycle.js";

export async function executeAction(requestId, action) {
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
