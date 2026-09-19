import { createRequire } from "node:module";

/** Local transport retirement is NOT evidence of host Stop/native retirement. */
export interface NativeCaptureTransport {
  request(control: Buffer): Promise<{ control: Buffer; jpeg: Buffer | null }>;
  closeLocal(): Promise<void>;
}

export const NATIVE_CAPTURE_OPERATION_TIMEOUT_MS = 10_000;

function boundedCallback<T>(
  operation: string,
  invoke: (done: (error: Error | null, value: T) => void) => void,
  timeout = NATIVE_CAPTURE_OPERATION_TIMEOUT_MS,
): Promise<T> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error(`Native capture ${operation} did not settle before its bounded deadline`));
    }, timeout);
    invoke((error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error); else resolve(value);
    });
  });
}

/** Import is inert; only this explicit operation loads/opens the fixed addon. */
export function openNativeCaptureTransport(): NativeCaptureTransport {
  if (process.platform !== "darwin" || !["arm64", "x64"].includes(process.arch)) {
    throw new Error("Native capture requires the installed signed Mac runtime");
  }
  let addon: unknown;
  try {
    addon = createRequire(import.meta.url)(
      "/Applications/Tron.app/Contents/Library/Native/tron-native-capture.node",
    );
    if (typeof addon !== "object" || addon === null || !("apiVersion" in addon) || addon.apiVersion !== 4
        || !("open" in addon) || typeof addon.open !== "function") {
      throw new Error("Invalid native capture addon");
    }
  } catch (cause) {
    throw new Error("Native capture unavailable: a manual signed Mac app update is required; source-only Gateway updates cannot install native code", { cause });
  }
  // Capacity, peer admission and other explicit-open errors are runtime
  // failures, not instructions to replace an already valid signed binary.
  type Reply = { control: Buffer; jpeg: Buffer | null };
  type NativeClient = {
    request(control: Buffer, done: (error: Error | null, value: Reply) => void): void;
    closeLocal(done: (error: Error | null) => void): void;
  };
  const native = (addon as { open(): NativeClient }).open();
  let closing: Promise<void> | undefined;
  // V8 owns these Promises. Native code retains only disposable callback refs,
  // not opaque napi_deferred handles that cannot be freed during forced exit.
  return {
    request: (control) => boundedCallback("request", (done) => native.request(control, done)),
    closeLocal: () => closing ??= boundedCallback<void>("local retirement", (done) => native.closeLocal((error) => done(error, undefined))),
  };
}
