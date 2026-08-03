import { PROTOCOL_VERSION } from "./protocol.js";

const MAX_ACTIVE_REQUESTS = 16;
const CANCEL_TOMBSTONE_MILLISECONDS = 30_000;
const requestStates = new Map();

export function admitRequest(requestId) {
  pruneRequestStates();
  if (requestStates.size >= MAX_ACTIVE_REQUESTS) {
    return false;
  }
  requestStates.set(requestId, {
    cancelledAt: undefined,
    cancellationExpiresAt: undefined,
    cancellationHandlers: new Set(),
  });
  return true;
}

export function cancelRequest(message) {
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
  // Cancellation is meaningful only for an admitted queued/running request.
  // Late cancellation cannot create a service-worker tombstone.
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

export function cancelAllRequests() {
  const now = performance.now();
  for (const state of requestStates.values()) {
    state.cancelledAt = now;
    state.cancellationExpiresAt = now + CANCEL_TOMBSTONE_MILLISECONDS;
    for (const handler of [...state.cancellationHandlers]) {
      handler();
    }
  }
}

export function finishRequest(requestId) {
  const state = requestStates.get(requestId);
  state?.cancellationHandlers.clear();
  requestStates.delete(requestId);
}

export function throwIfCancelled(requestId) {
  if (isRequestCancelled(requestId)) {
    throw new Error("browser_request_cancelled");
  }
}

export function addCancellationHandler(requestId, handler) {
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

export function cancellableDelay(requestId, milliseconds) {
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

export function isRequestCancelled(requestId) {
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

export function pruneRequestStates(now = performance.now()) {
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

export const browserOperatorTesting = Object.freeze({
  activeRequestCount: () => requestStates.size,
  cancelledRequestCount: () =>
    [...requestStates.values()].filter((state) => state.cancelledAt !== undefined).length,
});
