// These pure functions execute inside the controlled page through
// chrome.scripting. They must remain self-contained: imported helpers are not
// available in the page execution world.

export function collectObservation(maxElements) {
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

export function applyElementAction(target, kind, text, replace) {
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

export function applyFixedKey(target, key) {
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
