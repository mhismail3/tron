import assert from "node:assert/strict";
import test from "node:test";

import {
  sanitizeVisibleUrl,
  validateHostRequest,
  validateNavigationUrl,
} from "../protocol.js";

test("closed protocol accepts the eight declared operations", () => {
  const actions = [
    { kind: "tabs" },
    { kind: "observe", tabId: 7 },
    { kind: "screenshot", tabId: 7 },
    { kind: "click", tabId: 7, observationId: "obs-1", elementRef: "element-1" },
    {
      kind: "type",
      tabId: 7,
      observationId: "obs-1",
      elementRef: "element-1",
      text: "hello",
      replace: true,
    },
    { kind: "key", tabId: 7, key: "Enter" },
    { kind: "scroll", tabId: 7, deltaX: 0, deltaY: 500 },
    { kind: "navigate", tabId: 7, url: "https://example.test/path" },
  ];
  for (const action of actions) {
    assert.doesNotThrow(() =>
      validateHostRequest({
        kind: "request",
        protocolVersion: 1,
        requestId: `request-${action.kind}`,
        action,
      }),
    );
  }
});

test("arbitrary JavaScript, cookies, headers, and extension commands are inexpressible", () => {
  const rejected = [
    { kind: "observe", tabId: 7, script: "document.cookie" },
    { kind: "cookies", tabId: 7 },
    { kind: "navigate", tabId: 7, url: "https://example.test", headers: { token: "x" } },
    { kind: "extension_api", command: "downloads.open" },
  ];
  for (const action of rejected) {
    assert.throws(() =>
      validateHostRequest({
        kind: "request",
        protocolVersion: 1,
        requestId: "request-1",
        action,
      }),
    );
  }
});

test("navigation admits HTTPS and loopback HTTP without embedded credentials", () => {
  assert.equal(validateNavigationUrl("https://example.test/a?q=1"), "https://example.test/a?q=1");
  assert.equal(validateNavigationUrl("http://127.0.0.1:3000/a"), "http://127.0.0.1:3000/a");
  for (const value of [
    "http://example.test",
    "file:///tmp/a",
    "javascript:alert(1)",
    "https://user:password@example.test",
  ]) {
    assert.throws(() => validateNavigationUrl(value));
  }
});

test("visible URL evidence drops credentials, query, and fragment", () => {
  assert.equal(
    sanitizeVisibleUrl("https://user:password@example.test/path?token=secret#value"),
    "https://example.test/path",
  );
});
