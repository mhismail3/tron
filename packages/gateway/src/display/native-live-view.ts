import { setTimeout as delay } from "node:timers/promises";
import type { NativeCaptureBinding, NativeCaptureFrame, NativeCaptureJoin, NativeCaptureRegion, NativeCaptureSource } from "../machine/native-capture-client.js";
import { NativeCaptureHostFailure, openNativeCaptureClient } from "../machine/native-capture-client.js";
import type { CapturedBrowserFrame } from "./browser-live-cdp.js";

export const NATIVE_LIVE_VIEW_SCHEMA = "tron.native-live-view.v1" as const;
export const NATIVE_LIVE_VIEW_CAPABILITY = "native-live-view.v1" as const;
export type NativeLiveFailure = "permission_required" | "source_unavailable" | "capture_busy" | "capture_unavailable" | "first_frame_timeout";
/** Only finite classifications cross into viewer diagnostics, never native paths or exception text. */
export function nativeLiveFailure(error: unknown): NativeLiveFailure {
  const outer = error instanceof AggregateError ? error.errors.slice(0, 2) : [error];
  const causes = outer.flatMap((cause: unknown) => cause instanceof AggregateError ? cause.errors.slice(0, 2) : [cause]);
  for (const cause of causes) if (cause instanceof NativeCaptureHostFailure) {
    if (cause.status === "permissionUnavailable") return "permission_required";
    if (cause.status === "sourceUnavailable") return "source_unavailable";
    if (cause.status === "busy" || cause.status === "exhausted") return "capture_busy";
  }
  return "capture_unavailable";
}
export interface NativeLiveClient {
  catalog(): Promise<readonly NativeCaptureSource[]>;
  start(handle: string, signal?: AbortSignal, region?: NativeCaptureRegion): Promise<void>;
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
  onFrame: (frame: CapturedBrowserFrame) => void, region?: NativeCaptureRegion): { stop(): void; done: Promise<void> } {
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
    let failed = false, failure: unknown;
    try {
      await client.start(handle, waiting.signal, region);
      while (!waiting.signal.aborted) {
        const frame = await client.pull();
        if (waiting.signal.aborted) break;
        if (frame) onFrame({ data: frame.jpeg, mimeType: "image/jpeg", width: frame.width, height: frame.height });
        await delay(200, undefined, { signal: waiting.signal, ref: false });
      }
    } catch (error) {
      if (!waiting.signal.aborted) { failed = true; failure = error; }
    } finally {
      stop();
      try {
        const result = await closing!;
        if (result.diagnostic) throw new Error("Native capture joined with a retirement diagnostic");
      } catch (cleanup) {
        // Preserve the capture cause without concealing uncertain retirement.
        if (failed) throw new AggregateError([failure, cleanup], "Native capture and retirement failed");
        throw cleanup;
      }
    }
    if (failed) throw failure;
  })();
  return { stop, done };
}
