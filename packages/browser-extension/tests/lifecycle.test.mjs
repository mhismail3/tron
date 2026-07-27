import assert from "node:assert/strict";
import test from "node:test";

class MockEvent {
  listeners = [];

  addListener(listener) {
    this.listeners.push(listener);
  }

  removeListener(listener) {
    this.listeners = this.listeners.filter((candidate) => candidate !== listener);
  }

  get listenerCount() {
    return this.listeners.length;
  }

  async emit(...arguments_) {
    await Promise.all(this.listeners.map((listener) => listener(...arguments_)));
  }
}

function createChromeMock() {
  const actionClicked = new MockEvent();
  const tabsRemoved = new MockEvent();
  const tabsUpdated = new MockEvent();
  const nativeMessages = new MockEvent();
  const nativeDisconnect = new MockEvent();
  const session = new Map();
  const responses = [];
  const scriptCalls = [];
  const badge = new Map();
  const tab = {
    id: 7,
    windowId: 3,
    active: true,
    incognito: false,
    title: "Fixture",
    url: "https://example.test/start",
  };
  let nextElementResult = "applied";
  let capture;

  const port = {
    onMessage: nativeMessages,
    onDisconnect: nativeDisconnect,
    postMessage(message) {
      if (message.kind === "response") {
        responses.push(message);
      }
    },
  };

  const api = {
    action: {
      onClicked: actionClicked,
      async setBadgeText({ tabId, text }) {
        badge.set(tabId, { ...(badge.get(tabId) ?? {}), text });
      },
      async setBadgeBackgroundColor({ tabId, color }) {
        badge.set(tabId, { ...(badge.get(tabId) ?? {}), color });
      },
      async setTitle({ tabId, title }) {
        badge.set(tabId, { ...(badge.get(tabId) ?? {}), title });
      },
    },
    runtime: {
      connectNative() {
        return port;
      },
    },
    scripting: {
      async executeScript(options) {
        const functionName = options.func.name;
        scriptCalls.push(functionName || "consentIndicator");
        if (functionName === "collectObservation") {
          return [{
            result: {
              documentToken: Math.round(performance.timeOrigin).toString(36),
              title: tab.title,
              url: tab.url,
              viewport: { width: 900, height: 700, scrollX: 0, scrollY: 0 },
              text: "Fixture page",
              elements: [{
                selector: "#action",
                role: "button",
                name: "Action",
                text: "Action",
                tag: "button",
                disabled: false,
                bounds: { x: 10, y: 10, width: 80, height: 30 },
              }],
              truncated: false,
            },
          }];
        }
        if (functionName === "applyElementAction") {
          if (nextElementResult === "execute_password_rejection") {
            nextElementResult = "applied";
            const previousDocument = globalThis.document;
            globalThis.document = {
              querySelector() {
                return {
                  getAttribute(name) {
                    return name === "type" ? "password" : "";
                  },
                };
              },
            };
            try {
              return [{ result: options.func(...options.args) }];
            } finally {
              globalThis.document = previousDocument;
            }
          }
          const result = nextElementResult;
          nextElementResult = "applied";
          return [{ result }];
        }
        if (functionName === "applyFixedKey") {
          return [{ result: "applied" }];
        }
        return [{ result: undefined }];
      },
    },
    storage: {
      session: {
        async get(key) {
          return { [key]: session.get(key) };
        },
        async set(value) {
          for (const [key, item] of Object.entries(value)) {
            session.set(key, item);
          }
        },
        async remove(key) {
          session.delete(key);
        },
      },
    },
    tabs: {
      onRemoved: tabsRemoved,
      onUpdated: tabsUpdated,
      async query(query) {
        if (query.active) {
          return tab.active ? [{ ...tab }] : [];
        }
        return [{ ...tab }];
      },
      async update(tabId, update) {
        assert.equal(tabId, tab.id);
        tab.url = update.url;
        queueMicrotask(() => {
          void tabsUpdated.emit(tab.id, { status: "complete" }, { ...tab });
        });
        return { ...tab };
      },
      async captureVisibleTab() {
        if (capture) {
          return capture.promise;
        }
        return "data:image/jpeg;base64,YWJj";
      },
    },
  };

  return {
    api,
    actionClicked,
    badge,
    nativeMessages,
    responses,
    scriptCalls,
    session,
    tab,
    tabsUpdated,
    beginDeferredCapture() {
      let resolve;
      let startedResolve;
      const started = new Promise((innerResolve) => {
        startedResolve = innerResolve;
      });
      const promise = new Promise((innerResolve) => {
        resolve = innerResolve;
      });
      capture = {
        promise: (async () => {
          startedResolve();
          return promise;
        })(),
      };
      return {
        started,
        resolve(value = "data:image/jpeg;base64,YWJj") {
          resolve(value);
          capture = undefined;
        },
      };
    },
    setNextElementResult(value) {
      nextElementResult = value;
    },
    async responseFor(requestId) {
      const deadline = performance.now() + 2_000;
      while (performance.now() < deadline) {
        const index = responses.findIndex(
          (message) => message.requestId === requestId,
        );
        if (index >= 0) {
          return responses.splice(index, 1)[0];
        }
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      throw new Error(`response timed out: ${requestId}`);
    },
    request(requestId, action) {
      return nativeMessages.emit({
        kind: "request",
        protocolVersion: 1,
        requestId,
        action,
      });
    },
    cancel(requestId) {
      return nativeMessages.emit({
        kind: "cancel",
        protocolVersion: 1,
        requestId,
      });
    },
  };
}

test("mocked Chrome lifecycle keeps consent, actuation, and cancellation bounded", async () => {
  const chromeMock = createChromeMock();
  globalThis.chrome = chromeMock.api;
  const { browserOperatorTesting } = await import(
    `../service-worker.js?lifecycle=${Date.now()}`
  );

  await chromeMock.actionClicked.emit({ ...chromeMock.tab });
  assert.equal(chromeMock.session.get("consentedTabId"), chromeMock.tab.id);
  assert.equal(chromeMock.badge.get(chromeMock.tab.id).text, "ON");

  await chromeMock.request("navigate-1", {
    kind: "navigate",
    tabId: chromeMock.tab.id,
    url: "https://example.test/next",
  });
  const navigation = await chromeMock.responseFor("navigate-1");
  assert.equal(navigation.ok, true);
  assert.equal(navigation.result.actionApplied, true);
  assert.equal(navigation.result.observation.url, "https://example.test/next");
  assert.equal(
    chromeMock.tabsUpdated.listenerCount,
    1,
    "the per-navigation completion listener must be removed",
  );

  await chromeMock.request("observe-1", {
    kind: "observe",
    tabId: chromeMock.tab.id,
  });
  const observation = await chromeMock.responseFor("observe-1");
  assert.equal(observation.ok, true);
  const collectCountBeforeClick = chromeMock.scriptCalls.filter(
    (name) => name === "collectObservation",
  ).length;

  await chromeMock.request("click-1", {
    kind: "click",
    tabId: chromeMock.tab.id,
    observationId: observation.result.observationId,
    elementRef: observation.result.elements[0].elementRef,
  });
  const click = await chromeMock.responseFor("click-1");
  assert.equal(click.ok, true);
  assert.equal(click.result.actionApplied, true);
  assert.ok(
    chromeMock.scriptCalls.filter((name) => name === "collectObservation").length
      > collectCountBeforeClick,
    "a mutation must return a fresh observation",
  );

  chromeMock.setNextElementResult("execute_password_rejection");
  await chromeMock.request("password-1", {
    kind: "type",
    tabId: chromeMock.tab.id,
    observationId: click.result.observation.observationId,
    elementRef: click.result.observation.elements[0].elementRef,
    text: "not-a-secret",
    replace: true,
  });
  const password = await chromeMock.responseFor("password-1");
  assert.equal(password.ok, false);
  assert.equal(password.error, "credential_field_rejected");

  const capture = chromeMock.beginDeferredCapture();
  await chromeMock.request("cancel-1", {
    kind: "screenshot",
    tabId: chromeMock.tab.id,
  });
  await capture.started;
  await chromeMock.cancel("cancel-1");
  capture.resolve();
  const cancelled = await chromeMock.responseFor("cancel-1");
  assert.equal(cancelled.ok, false);
  assert.equal(cancelled.error, "browser_request_cancelled");
  assert.equal(browserOperatorTesting.activeRequestCount(), 0);
  assert.equal(browserOperatorTesting.cancelledRequestCount(), 0);

  // A late cancellation after completion is ignored instead of creating a
  // tombstone that survives until the Manifest V3 worker is reclaimed.
  await chromeMock.cancel("cancel-1");
  assert.equal(browserOperatorTesting.activeRequestCount(), 0);
  assert.equal(browserOperatorTesting.cancelledRequestCount(), 0);

  const boundedCapture = chromeMock.beginDeferredCapture();
  for (let index = 0; index < 17; index += 1) {
    await chromeMock.request(`bounded-${index}`, {
      kind: "screenshot",
      tabId: chromeMock.tab.id,
    });
  }
  await boundedCapture.started;
  const overflow = await chromeMock.responseFor("bounded-16");
  assert.equal(overflow.ok, false);
  assert.equal(overflow.error, "browser_request_queue_full");
  assert.equal(browserOperatorTesting.activeRequestCount(), 16);
  for (let index = 0; index < 16; index += 1) {
    await chromeMock.cancel(`bounded-${index}`);
  }
  boundedCapture.resolve();
  for (let index = 0; index < 16; index += 1) {
    const response = await chromeMock.responseFor(`bounded-${index}`);
    assert.equal(response.ok, false);
    assert.equal(response.error, "browser_request_cancelled");
  }
  assert.equal(browserOperatorTesting.activeRequestCount(), 0);
  assert.equal(browserOperatorTesting.cancelledRequestCount(), 0);

  await chromeMock.actionClicked.emit({ ...chromeMock.tab });
  assert.equal(chromeMock.session.has("consentedTabId"), false);
  assert.equal(chromeMock.badge.get(chromeMock.tab.id).text, "");
});
