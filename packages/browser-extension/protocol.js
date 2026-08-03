export const PROTOCOL_VERSION = 1;
export const HOST_NAME = "com.tron.browser_operator";
export const MAX_TABS = 32;
export const MAX_ELEMENTS = 200;
export const MAX_SCREENSHOT_BYTES = 4_000_000;

const ACTIONS = new Set([
  "tabs",
  "observe",
  "screenshot",
  "click",
  "type",
  "key",
  "scroll",
  "navigate",
]);

const KEYS = new Set([
  "Enter",
  "Tab",
  "Escape",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "PageUp",
  "PageDown",
  "Home",
  "End",
  "Backspace",
  "Delete",
  "Space",
]);

export function validateHostRequest(message) {
  if (!isPlainObject(message) || message.kind !== "request") {
    throw new Error("invalid_request_envelope");
  }
  if (message.protocolVersion !== PROTOCOL_VERSION) {
    throw new Error("protocol_version_mismatch");
  }
  if (!identifier(message.requestId, 128) || !isPlainObject(message.action)) {
    throw new Error("invalid_request_identity");
  }
  const action = message.action;
  if (!ACTIONS.has(action.kind)) {
    throw new Error("unsupported_action");
  }
  assertExactKeys(action, actionKeys(action.kind));
  if (action.kind !== "tabs") {
    assertTabId(action.tabId);
  }
  if (["click", "type"].includes(action.kind)) {
    if (!identifier(action.observationId, 96) || !identifier(action.elementRef, 128)) {
      throw new Error("invalid_element_target");
    }
  }
  if (action.kind === "type") {
    if (typeof action.text !== "string" || utf8Length(action.text) > 4000) {
      throw new Error("typed_text_oversized");
    }
    if (typeof action.replace !== "boolean") {
      throw new Error("invalid_replace_flag");
    }
  }
  if (action.kind === "key") {
    if (!KEYS.has(action.key)) {
      throw new Error("unsupported_key");
    }
    const targeted = action.observationId !== undefined || action.elementRef !== undefined;
    if (
      targeted &&
      (!identifier(action.observationId, 96) || !identifier(action.elementRef, 128))
    ) {
      throw new Error("invalid_element_target");
    }
  }
  if (action.kind === "scroll") {
    for (const delta of [action.deltaX, action.deltaY]) {
      if (!Number.isInteger(delta) || Math.abs(delta) > 2000) {
        throw new Error("invalid_scroll_delta");
      }
    }
    if (action.deltaX === 0 && action.deltaY === 0) {
      throw new Error("invalid_scroll_delta");
    }
  }
  if (action.kind === "navigate") {
    validateNavigationUrl(action.url);
  }
  return message;
}

export function validateNavigationUrl(raw) {
  if (typeof raw !== "string" || utf8Length(raw) > 2048) {
    throw new Error("invalid_navigation_url");
  }
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error("invalid_navigation_url");
  }
  if (url.username || url.password) {
    throw new Error("credential_url_rejected");
  }
  const loopback =
    url.protocol === "http:" &&
    ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (url.protocol !== "https:" && !loopback) {
    throw new Error("unsafe_navigation_scheme");
  }
  return url.href;
}

export function sanitizeVisibleUrl(raw) {
  try {
    const url = new URL(raw);
    if (!["https:", "http:"].includes(url.protocol)) {
      return `${url.protocol}//`;
    }
    url.username = "";
    url.password = "";
    url.search = "";
    url.hash = "";
    return `${url.origin}${url.pathname}`;
  } catch {
    return "unavailable";
  }
}

export function safeError(error) {
  const value = error instanceof Error ? error.message : String(error);
  const known = value
    .replace(/[^\w:.-]/g, "_")
    .slice(0, 160);
  return known || "browser_action_failed";
}

function actionKeys(kind) {
  switch (kind) {
    case "tabs":
      return ["kind"];
    case "observe":
    case "screenshot":
      return ["kind", "tabId"];
    case "click":
      return ["kind", "tabId", "observationId", "elementRef"];
    case "type":
      return ["kind", "tabId", "observationId", "elementRef", "text", "replace"];
    case "key":
      return ["kind", "tabId", "key", "observationId", "elementRef"];
    case "scroll":
      return ["kind", "tabId", "deltaX", "deltaY"];
    case "navigate":
      return ["kind", "tabId", "url"];
    default:
      return [];
  }
}

function assertExactKeys(value, allowed) {
  const allowedKeys = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!allowedKeys.has(key)) {
      throw new Error("undeclared_action_field");
    }
  }
  for (const key of allowed) {
    if (
      !["observationId", "elementRef"].includes(key) &&
      !Object.hasOwn(value, key)
    ) {
      throw new Error("missing_action_field");
    }
  }
  if (
    (Object.hasOwn(value, "observationId") && !Object.hasOwn(value, "elementRef")) ||
    (!Object.hasOwn(value, "observationId") && Object.hasOwn(value, "elementRef"))
  ) {
    throw new Error("invalid_element_target");
  }
}

function assertTabId(value) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error("invalid_tab_id");
  }
}

function identifier(value, max) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    utf8Length(value) <= max &&
    /^[A-Za-z0-9_:.-]+$/.test(value)
  );
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function utf8Length(value) {
  return new TextEncoder().encode(value).length;
}
