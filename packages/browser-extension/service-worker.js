import { connectNativeHost } from "./native-connection.js";
import {
  clearConsentState,
  ensureConsentIndicator,
  getConsentedTabId,
  handleConsentClick,
  setBadge,
} from "./consent.js";
import { removeObservation } from "./observation.js";
export { browserOperatorTesting } from "./request-lifecycle.js";

// Manifest V3 entry point. Imported modules own their bounded concerns; this
// file owns only Chrome event registration.

chrome.action.onClicked.addListener(async (tab) => {
  await handleConsentClick(tab, connectNativeHost);
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  if ((await getConsentedTabId()) === tabId) {
    await clearConsentState(tabId);
  }
  removeObservation(tabId);
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo) => {
  if (changeInfo.status !== "complete" || (await getConsentedTabId()) !== tabId) {
    return;
  }
  removeObservation(tabId);
  try {
    await ensureConsentIndicator(tabId);
    await setBadge(tabId, "ON", "#008f68");
  } catch {
    await clearConsentState(tabId);
  }
});
