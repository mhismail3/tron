import { cancelAllRequests } from "./request-lifecycle.js";
import { removeObservation } from "./observation.js";

const CONSENT_KEY = "consentedTabId";
const INDICATOR_ID = "tron-browser-operator-consent-indicator";

export async function handleConsentClick(tab, connectNativeHost) {
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
}

export async function requireForegroundConsent(tabId) {
  if ((await getConsentedTabId()) !== tabId) {
    throw new Error("foreground_consent_required");
  }
  const active = (await chrome.tabs.query({ active: true, lastFocusedWindow: true }))[0];
  if (!active || active.id !== tabId || active.incognito || !isWebUrl(active.url)) {
    throw new Error("controlled_tab_not_foreground");
  }
  return active;
}

export async function ensureConsentIndicator(tabId) {
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

export async function disableConsent(tabId) {
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

export async function clearConsentState(tabId) {
  cancelAllRequests();
  await chrome.storage.session.remove(CONSENT_KEY);
  removeObservation(tabId);
  await setBadge(tabId, "", "#008f68");
}

export async function getConsentedTabId() {
  const value = await chrome.storage.session.get(CONSENT_KEY);
  return Number.isSafeInteger(value[CONSENT_KEY]) ? value[CONSENT_KEY] : undefined;
}

export async function setBadge(tabId, text, color) {
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

function isWebUrl(raw) {
  return typeof raw === "string" && /^(https?):\/\//i.test(raw);
}
