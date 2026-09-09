import { describe, expect, it, vi } from "vitest";
import { abortableRead } from "./abortable-read.js";

describe("disposable read wait", () => {
  it("does not start work after cancellation", async () => {
    const controller = new AbortController();
    controller.abort();
    const acquire = vi.fn(async () => 1);
    await expect(abortableRead(controller.signal, acquire)).rejects.toMatchObject({ name: "AbortError" });
    expect(acquire).not.toHaveBeenCalled();
  });

  it("settles an abandoned waiter and returns a late lease to its owner", async () => {
    const controller = new AbortController();
    let enter!: () => void, produce!: (value: number) => void, disposed!: () => void;
    const entered = new Promise<void>(resolve => { enter = resolve; });
    const pending = new Promise<number>(resolve => { produce = resolve; });
    const cleanup = new Promise<void>(resolve => { disposed = resolve; });
    const release = vi.fn(async (value: number) => { expect(value).toBe(7); disposed(); });
    const result = abortableRead(controller.signal, () => { enter(); return pending; }, release);
    void result.catch(() => {});
    try {
      await entered;
      controller.abort();
      await expect(result).rejects.toMatchObject({ name: "AbortError" });
      expect(release).not.toHaveBeenCalled();
      produce(7);
      await cleanup;
      expect(release).toHaveBeenCalledTimes(1);
    } finally { produce(7); await pending; }
  });
});
