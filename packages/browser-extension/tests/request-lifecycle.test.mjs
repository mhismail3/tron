import assert from "node:assert/strict";
import test from "node:test";

test("request lifecycle bounds admission and ignores late cancellation", async () => {
  const lifecycle = await import(
    `../request-lifecycle.js?request-lifecycle=${Date.now()}`
  );

  for (let index = 0; index < 16; index += 1) {
    assert.equal(lifecycle.admitRequest(`request-${index}`), true);
  }
  assert.equal(lifecycle.admitRequest("request-overflow"), false);
  assert.equal(lifecycle.browserOperatorTesting.activeRequestCount(), 16);

  lifecycle.cancelRequest({
    kind: "cancel",
    protocolVersion: 1,
    requestId: "request-0",
  });
  assert.throws(
    () => lifecycle.throwIfCancelled("request-0"),
    /browser_request_cancelled/,
  );
  lifecycle.finishRequest("request-0");

  lifecycle.cancelRequest({
    kind: "cancel",
    protocolVersion: 1,
    requestId: "request-0",
  });
  assert.equal(lifecycle.browserOperatorTesting.cancelledRequestCount(), 0);

  for (let index = 1; index < 16; index += 1) {
    lifecycle.finishRequest(`request-${index}`);
  }
  assert.equal(lifecycle.browserOperatorTesting.activeRequestCount(), 0);
});
