import { type StreamFn } from "@earendil-works/pi-agent-core";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { AssistantMessageEventStream, InMemoryCredentialStore, fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { describe, expect, it, vi } from "vitest";
import { abortAwareStream } from "./abort-aware-stream.js";

const model = fauxProvider().getModel();
const context = { messages: [] };

describe("abortAwareStream", () => {
  it("classifies a pre-aborted request through the real ModelRuntime setup as cancellation", async () => {
    const faux = fauxProvider();
    const runtime = await ModelRuntime.create({
      credentials: new InMemoryCredentialStore(), modelsPath: null, refreshOnCreate: false,
    });
    runtime.registerNativeProvider(faux.provider);
    const controller = new AbortController();
    controller.abort();
    const stream = await abortAwareStream(runtime.streamSimple.bind(runtime))(
      faux.getModel(), context, { signal: controller.signal },
    );
    const events = [];
    for await (const event of stream) events.push(event);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "error", reason: "aborted", error: { stopReason: "aborted" } });
    expect(await stream.result()).toBe(events[0]?.type === "error" ? events[0].error : undefined);
    expect(faux.state.callCount).toBe(0);
  });

  it.each([false, true])("normalizes cancelled setup rejection (async=%s)", async (asynchronous) => {
    const controller = new AbortController();
    const fail = () => { controller.abort(); controller.signal.throwIfAborted(); throw new Error("unreachable"); };
    const setup: StreamFn = asynchronous ? async () => fail() : () => fail();
    const stream = await abortAwareStream(setup)(model, context, { signal: controller.signal });
    expect(await stream.result()).toMatchObject({ stopReason: "aborted" });
  });

  it("forwards progress before completion and preserves terminal error content and usage", async () => {
    const source = new AssistantMessageEventStream();
    const controller = new AbortController();
    const options = { signal: controller.signal, temperature: 0.2 };
    const original = vi.fn(() => source);
    const stream = await abortAwareStream(original)(model, context, options);
    const iterator = stream[Symbol.asyncIterator]();
    const partial = fauxAssistantMessage("partial answer");
    const start = { type: "start" as const, partial };
    source.push(start);
    expect((await iterator.next()).value).toBe(start);
    const error = fauxAssistantMessage("partial answer", { stopReason: "error", errorMessage: "request cancelled" });
    controller.abort();
    source.push({ type: "error", reason: "error", error });
    source.end(error);
    const terminal = (await iterator.next()).value;
    expect(terminal).toEqual({ type: "error", reason: "aborted", error: { ...error, stopReason: "aborted" } });
    expect(await stream.result()).toBe(terminal.error);
    expect(error.stopReason).toBe("error");
    expect(original).toHaveBeenCalledExactlyOnceWith(model, context, options);
    expect((await iterator.next()).done).toBe(true);
  });

  it.each(["error", "stop"] as const)("preserves %s without inventing cancellation", async (stopReason) => {
    const source = new AssistantMessageEventStream();
    const controller = new AbortController();
    // A successful response remains successful even if Stop arrives before its delivery.
    if (stopReason === "stop") controller.abort();
    const message = fauxAssistantMessage("original", { stopReason, errorMessage: "This operation was aborted" });
    const event = stopReason === "error"
      ? { type: "error" as const, reason: "error" as const, error: message }
      : { type: "done" as const, reason: "stop" as const, message };
    const stream = await abortAwareStream(() => source)(model, context, { signal: controller.signal });
    source.push(event);
    source.end(message);
    const events = [];
    for await (const value of stream) events.push(value);
    expect(events).toEqual([event]);
    expect(events[0]).toBe(event);
    expect(await stream.result()).toBe(message);
  });

  it.each(["error", "stop"] as const)("preserves result-only streams (%s)", async (stopReason) => {
    const source = new AssistantMessageEventStream();
    const controller = new AbortController();
    controller.abort();
    const message = fauxAssistantMessage("result without a terminal event", { stopReason });
    const stream = await abortAwareStream(() => source)(model, context, { signal: controller.signal });
    source.end(message);
    expect(await stream.result()).toEqual({ ...message, stopReason: stopReason === "error" ? "aborted" : "stop" });
  });
});
