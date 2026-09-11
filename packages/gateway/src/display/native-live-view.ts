import { setTimeout as delay } from "node:timers/promises";
import type { NativeCaptureBinding, NativeCaptureFrame, NativeCaptureJoin, NativeCaptureSource } from "../machine/native-capture-client.js";
import { openNativeCaptureClient } from "../machine/native-capture-client.js";
import type { CapturedBrowserFrame } from "./browser-live-cdp.js";

export const NATIVE_LIVE_VIEW_SCHEMA = "tron.native-live-view.v1" as const;
export const NATIVE_LIVE_VIEW_CAPABILITY = "native-live-view.v1" as const;
export interface NativeLiveClient {
  catalog(): Promise<readonly NativeCaptureSource[]>;
  start(handle: string, signal?: AbortSignal): Promise<void>;
  pull(): Promise<NativeCaptureFrame | undefined>;
  suspend(): Promise<NativeCaptureJoin>;
  close(): Promise<NativeCaptureJoin>;
}
export type NativeLiveClientFactory = (binding: NativeCaptureBinding) => Promise<NativeLiveClient>;
export const nativeLiveClientFactory: NativeLiveClientFactory = openNativeCaptureClient;

/** A visibility-owned read loop, not a second capture engine. Stop bypasses the
 * pending read/start and joins its exact stream suspension. The selected target
 * and connection remain with the registry until explicit/session retirement.
 * A rejected Stop never proves remote retirement; the Native Host retains it. */
export function observeNativeWindow(client: NativeLiveClient, handle: string,
  onFrame: (frame: CapturedBrowserFrame) => void): { stop(): void; done: Promise<void> } {
  const waiting = new AbortController();
  let closing: Promise<NativeCaptureJoin> | undefined;
  const stop = (): void => {
    waiting.abort();
    closing ??= client.suspend();
    // Stop can fail before an admitted start/read returns. The loop still joins
    // that exact promise in finally; do not create an unhandled-rejection gap.
    void closing.catch(() => {});
  };
  const done = (async () => {
    try {
      await client.start(handle, waiting.signal);
      while (!waiting.signal.aborted) {
        const frame = await client.pull();
        if (waiting.signal.aborted) break;
        if (frame) onFrame({ data: frame.jpeg, mimeType: "image/jpeg", width: frame.width, height: frame.height });
        await delay(200, undefined, { signal: waiting.signal, ref: false });
      }
    } catch (error) {
      if (!waiting.signal.aborted) throw error;
    } finally {
      stop();
      const result = await closing!;
      if (result.diagnostic) throw new Error("Native capture joined with a retirement diagnostic");
    }
  })();
  return { stop, done };
}
