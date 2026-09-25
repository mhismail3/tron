import { setTimeout as delay } from "node:timers/promises";
import { WebSocket } from "ws";

const MAXIMUM_FRAME_BYTES = 2 * 1_024 * 1_024;
const MAXIMUM_FRAME_EDGE = 2_560;
const MAXIMUM_FRAME_PIXELS = 4_000_000;
const MAXIMUM_PAYLOAD = Math.ceil(MAXIMUM_FRAME_BYTES * 4 / 3) + 65_536;
const COMMAND_TIMEOUT_MS = 5_000;
const FRAME_INTERVAL_MS = 200;
const MAXIMUM_TARGETS = 8;

/** Frame credit pacing must use the same monotonic clock as lifetime fences. */
function browserFrameDelay(now: number, lastCreditAt: number): number {
  return Math.max(0, FRAME_INTERVAL_MS - (now - lastCreditAt));
}

export interface CapturedBrowserFrame {
  data: Buffer;
  mimeType: "image/jpeg";
  width: number;
  height: number;
}

class DetachedBrowserTarget extends Error {}

function identifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 200;
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}

/** Inspect the JPEG's own SOF, not CDP viewport metadata (which can describe the
 * unscaled viewport). ImageIO remains the final decoder/admission on iOS. */
export function admitBrowserJPEG(data: Buffer): CapturedBrowserFrame | undefined {
  if (data.length < 12 || data.length > MAXIMUM_FRAME_BYTES
    || data.readUInt16BE(0) !== 0xffd8 || data.readUInt16BE(data.length - 2) !== 0xffd9) return;
  let offset = 2;
  while (offset + 4 <= data.length) {
    if (data[offset++] !== 0xff) return;
    while (data[offset] === 0xff) offset++;
    const marker = data[offset++];
    if (marker === undefined || marker === 0xda || marker === 0xd9 || offset + 2 > data.length) return;
    const size = data.readUInt16BE(offset);
    if (size < 2 || offset + size > data.length) return;
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      if (size < 8) return;
      const height = data.readUInt16BE(offset + 3);
      const width = data.readUInt16BE(offset + 5);
      if (width < 1 || height < 1 || width > MAXIMUM_FRAME_EDGE || height > MAXIMUM_FRAME_EDGE
        || width * height > MAXIMUM_FRAME_PIXELS) return;
      return { data, mimeType: "image/jpeg", width, height };
    }
    offset += size;
  }
}

/** One disposable, read-only CDP attachment. No browser launch/automation or
 * reconnect loop lives here. A failed attachment ends; only a new viewer open
 * can retry the exact original browser UUID endpoint. */
export function observeBrowserCDP(input: {
  endpoint: string;
  connect: (endpoint: string, maximumPayload: number) => WebSocket;
  onFrame: (frame: CapturedBrowserFrame) => void;
  onReset: () => void;
}): { stop: () => void; done: Promise<void> } {
  const socket = input.connect(input.endpoint, MAXIMUM_PAYLOAD);
  const controller = new AbortController();
  const pending = new Map<number, { resolve: (value: Record<string, unknown>) => void; reject: (error: Error) => void; timer: NodeJS.Timeout; sessionId?: string; targetId?: string }>();
  const sessions = new Map<string, string>();
  let nextID = 0;
  let activeSession: string | undefined;
  let stopped = false;
  let frameTimer: NodeJS.Timeout | undefined;
  // Start with one available credit; subsequent pacing uses only monotonic time.
  let lastCreditAt = performance.now() - FRAME_INTERVAL_MS;
  let latestEncoded: string | undefined;
  let firstFrameDeadline: number | undefined;
  const acknowledgements: number[] = [];
  let complete!: () => void;
  const done = new Promise<void>((resolve) => { complete = resolve; });
  let readyResolve!: () => void;
  let readyReject!: (error: Error) => void;
  const ready = new Promise<void>((resolve, reject) => { readyResolve = resolve; readyReject = reject; });

  function resetFrames(): void {
    if (frameTimer) clearTimeout(frameTimer);
    frameTimer = undefined;
    latestEncoded = undefined;
    firstFrameDeadline = undefined;
    acknowledgements.length = 0;
    input.onReset();
  }

  function stop(): void {
    if (stopped) return;
    stopped = true;
    clearTimeout(connectTimer);
    controller.abort();
    resetFrames();
    const error = new Error("Browser observer ended");
    readyReject(error);
    for (const command of pending.values()) {
      clearTimeout(command.timer);
      command.reject(error);
    }
    pending.clear();
    if (socket.readyState === WebSocket.OPEN && activeSession) {
      socket.send(JSON.stringify({ id: ++nextID, method: "Page.stopScreencast", sessionId: activeSession }));
    }
    socket.terminate();
    complete();
  }

  function attached(sessionId: string): boolean { return [...sessions.values()].includes(sessionId); }

  function request(method: string, params: Record<string, unknown> = {}, sessionId?: string): Promise<Record<string, unknown>> {
    if (sessionId && !attached(sessionId)) return Promise.reject(new DetachedBrowserTarget());
    if (stopped || socket.readyState !== WebSocket.OPEN || pending.size >= 32) {
      stop();
      return Promise.reject(new Error("Browser observer is unavailable"));
    }
    return new Promise((resolve, reject) => {
      const id = ++nextID;
      const timer = setTimeout(stop, COMMAND_TIMEOUT_MS);
      timer.unref();
      pending.set(id, { resolve, reject, timer, ...(sessionId ? { sessionId } : {}),
        ...(method === "Target.attachToTarget" && identifier(params.targetId) ? { targetId: params.targetId } : {}),
      });
      socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }), (error) => {
        if (error) stop();
      });
    });
  }

  function detachSession(sessionId: string): void {
    for (const [target, session] of sessions) if (session === sessionId) sessions.delete(target);
    for (const [id, command] of pending) {
      if (command.sessionId !== sessionId) continue;
      clearTimeout(command.timer);
      pending.delete(id);
      command.reject(new DetachedBrowserTarget());
    }
    if (activeSession === sessionId) { activeSession = undefined; resetFrames(); }
  }

  function drainFrames(): void {
    frameTimer = undefined;
    if (stopped || !activeSession) return;
    const encoded = latestEncoded;
    latestEncoded = undefined;
    if (encoded !== undefined) {
      const frame = admitBrowserJPEG(Buffer.from(encoded, "base64"));
      if (!frame) { stop(); return; }
      firstFrameDeadline = undefined;
      input.onFrame(frame);
    }
    const frameID = acknowledgements.shift();
    if (frameID !== undefined) {
      lastCreditAt = performance.now();
      void targetRequest(activeSession, "Page.screencastFrameAck", { sessionId: frameID }).catch(stop);
    }
    if (acknowledgements.length > 0) frameTimer = setTimeout(drainFrames, FRAME_INTERVAL_MS);
  }

  const connectTimer = setTimeout(stop, COMMAND_TIMEOUT_MS);
  connectTimer.unref();
  socket.once("open", () => { clearTimeout(connectTimer); readyResolve(); });
  socket.once("close", stop);
  socket.once("error", stop);
  socket.on("message", (raw: Buffer) => {
    if (stopped) return;
    let message: Record<string, unknown> | undefined;
    try { message = record(JSON.parse(raw.toString("utf8"))); } catch { stop(); return; }
    if (!message) { stop(); return; }
    if (Number.isSafeInteger(message.id)) {
      const id = message.id as number;
      const command = pending.get(id);
      if (!command) return;
      if (command.sessionId !== message.sessionId) { stop(); return; }
      pending.delete(id);
      clearTimeout(command.timer);
      if (message.error || !record(message.result)) {
        command.reject(new Error("Browser observer command failed"));
      } else {
        const result = message.result as Record<string, unknown>;
        // Publish attachment ownership before resolving the await: a detach
        // event in the same socket batch must invalidate that exact result.
        if (command.targetId && identifier(result.sessionId)) sessions.set(command.targetId, result.sessionId);
        command.resolve(result);
      }
      return;
    }
    const params = record(message.params);
    if (message.method === "Target.detachedFromTarget" && typeof params?.sessionId === "string") {
      detachSession(params.sessionId);
      return;
    }
    if (message.method !== "Page.screencastFrame" || !activeSession || message.sessionId !== activeSession) return;
    if (!params || !Number.isSafeInteger(params.sessionId) || (params.sessionId as number) < 0
      || typeof params.data !== "string" || params.data.length > Math.ceil(MAXIMUM_FRAME_BYTES * 4 / 3)
      || acknowledgements.length >= 4) { stop(); return; }
    // Chrome has a small in-flight window. Release one credit per 200ms, not
    // every incoming frame; replace encoded frames before allocating JPEG bytes.
    acknowledgements.push(params.sessionId as number);
    latestEncoded = params.data;
    if (!frameTimer) frameTimer = setTimeout(drainFrames, browserFrameDelay(performance.now(), lastCreditAt));
  });

  async function targetExists(targetId: string): Promise<boolean> {
    const targets = (await request("Target.getTargets")).targetInfos;
    if (!Array.isArray(targets)) throw new Error("Invalid browser targets");
    return targets.some((target) => record(target)?.targetId === targetId);
  }

  async function targetRequest(session: string, method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown> | undefined> {
    const target = [...sessions].find(([, id]) => id === session)?.[0];
    try { return await request(method, params, session); }
    catch (error) {
      if (!stopped && (error instanceof DetachedBrowserTarget || !attached(session))) return;
      // A CDP error may precede its detach notification. Confirm disappearance
      // with the browser rather than guessing from error text or ending peers.
      if (!stopped && target && !await targetExists(target)) {
        detachSession(session);
        return;
      }
      throw error;
    }
  }

  async function selectVisiblePage(): Promise<string | undefined> {
    const targets = (await request("Target.getTargets")).targetInfos;
    if (!Array.isArray(targets)) throw new Error("Invalid browser targets");
    const pages = targets.map(record).filter((target) => target?.type === "page");
    if (pages.length > MAXIMUM_TARGETS || pages.some((target) => !identifier(target?.targetId))) {
      throw new Error("Browser target selection exceeds its bound");
    }
    const ids = pages.map((page) => page!.targetId as string);
    for (const [target, session] of sessions) if (!ids.includes(target)) detachSession(session);
    const visible = await Promise.all(ids.map(async (target) => {
      let session = sessions.get(target);
      if (!session) {
        let result: Record<string, unknown>;
        try { result = await request("Target.attachToTarget", { targetId: target, flatten: true }); }
        catch (error) {
          if (!stopped && !await targetExists(target)) return;
          throw error;
        }
        if (!identifier(result.sessionId)) throw new Error("Invalid browser target attachment");
        session = result.sessionId;
        if (sessions.get(target) !== session) return;
      }
      const result = await targetRequest(session, "Runtime.evaluate", { expression: "document.visibilityState", returnByValue: true });
      return record(result?.result)?.value === "visible" && attached(session) ? session : undefined;
    }));
    const candidates = visible.filter((session): session is string => session !== undefined && attached(session));
    if (candidates.length > 1) throw new Error("Browser target selection is ambiguous");
    return candidates[0];
  }

  void (async () => {
    await ready;
    let lastVisibleAt = performance.now();
    while (!stopped) {
      // Successful setup is not frame delivery. Bound only the first frame of
      // each selected target; an already painted static page needs no heartbeat.
      if (firstFrameDeadline !== undefined && performance.now() >= firstFrameDeadline) {
        throw new Error("Browser did not produce its first frame");
      }
      const candidate = await selectVisiblePage();
      const selected = candidate && attached(candidate) ? candidate : undefined;
      if (selected) lastVisibleAt = performance.now();
      else if (performance.now() - lastVisibleAt >= COMMAND_TIMEOUT_MS) throw new Error("No visible browser page");
      if (selected !== activeSession) {
        const previous = activeSession;
        activeSession = undefined;
        resetFrames();
        if (previous) await targetRequest(previous, "Page.stopScreencast");
        if (selected && await targetRequest(selected, "Page.enable") && attached(selected)) {
          activeSession = selected;
          firstFrameDeadline = performance.now() + COMMAND_TIMEOUT_MS;
          if (!await targetRequest(selected, "Page.startScreencast", { format: "jpeg", quality: 70, maxWidth: 1280, maxHeight: 1280 })) {
            activeSession = undefined;
            resetFrames();
          }
        }
      }
      await delay(500, undefined, { signal: controller.signal });
    }
  })().catch(stop);
  return { stop, done };
}
