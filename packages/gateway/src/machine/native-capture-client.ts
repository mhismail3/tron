import { randomUUID } from "node:crypto";
import { basename, dirname, isAbsolute, normalize } from "node:path";
import { openNativeCaptureTransport } from "./native-capture-transport.js";
import type { NativeCaptureTransport } from "./native-capture-transport.js";

const CONTROL_LIMIT = 65_536;
const JPEG_LIMIT = 2 * 1024 * 1024;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const errors = new Set(["invalidRequest", "unauthorized", "stale", "busy", "exhausted", "unavailable", "retirementFailed", "permissionUnavailable", "sourceUnavailable", "streamFailed"]);
export class NativeCaptureHostFailure extends Error {
  constructor(readonly status: string, operation: string) {
    super(`Native capture host rejected ${operation}: ${status}; remote retirement unconfirmed`);
  }
}
type RecordValue = Record<string, unknown>;
type Identity = { loadID: string; bootID: string; connectionID: string; sessionID: string };
export type NativeCaptureBinding = Readonly<{ canonicalSessionID: string; runtimeLoadID: string }>;
export type NativeCaptureSource = Readonly<{ handle: string; kind: "window" | "display"; applicationName: string; title: string; width: number; height: number }>;
export type NativeCaptureRegion = Readonly<{ x: number; y: number; width: number; height: number }>;
export function captureRegion(value: unknown): NativeCaptureRegion {
  const r = record(value); keys(r, ["x", "y", "width", "height"]);
  for (const key of ["x", "y", "width", "height"] as const) {
    if (typeof r[key] !== "number" || !Number.isFinite(r[key]) || r[key] < 0) throw new Error("Invalid native capture region");
  }
  if (r.width === 0 || r.height === 0) throw new Error("Native capture region must have positive extent");
  return Object.freeze({ x: r.x as number, y: r.y as number, width: r.width as number, height: r.height as number });
}
export type NativeCaptureFrame = Readonly<{
  generation: string; readSequence: number; sequence: string; width: number; height: number; jpeg: Buffer;
}>;
export type NativeCaptureJoin = Readonly<{ status: "joined"; diagnostic?: string }>;
export type NativeAutomationEndpoint = Readonly<{ socket: string; generation: string }>;

function record(value: unknown): RecordValue {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Invalid native capture object");
  return value as RecordValue;
}
function keys(value: RecordValue, expected: string[]): void {
  if (Object.keys(value).sort().join(",") !== expected.sort().join(",")) throw new Error("Invalid native capture reply fields");
}
function uuid(value: unknown): string {
  if (typeof value !== "string" || !uuidPattern.test(value)) throw new Error("Invalid native capture identity");
  return value.toLowerCase();
}
function text(value: unknown): string {
  if (typeof value !== "string" || Buffer.byteLength(value) > 256) throw new Error("Invalid native capture text");
  return value;
}
function dimension(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > 1280) throw new Error("Invalid native capture dimension");
  return value;
}
// Inspect the bounded encoded header before any future viewer allocates a
// decoder. This is image-size admission, not proof of successful image decode.
function jpegDimensions(jpeg: Buffer, width: number, height: number): void {
  if (jpeg.length < 4 || jpeg.readUInt16BE(0) !== 0xffd8 || jpeg.readUInt16BE(jpeg.length - 2) !== 0xffd9) {
    throw new Error("Invalid native capture JPEG");
  }
  let offset = 2;
  let found = false;
  while (offset < jpeg.length - 2) {
    if (jpeg[offset++] !== 0xff) throw new Error("Invalid native capture JPEG marker");
    while (jpeg[offset] === 0xff) offset++;
    const marker = jpeg[offset++];
    if (marker === undefined || marker === 0 || marker === 0xd8 || marker === 0xd9) break;
    if (offset + 2 > jpeg.length) break;
    const length = jpeg.readUInt16BE(offset);
    if (length < 2 || offset + length > jpeg.length - 2) break;
    if (marker === 0xda) {
      if (found) return;
      break;
    }
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      if (found || ![0xc0, 0xc1, 0xc2].includes(marker) || length < 8 || jpeg[offset + 2] !== 8 ||
          jpeg.readUInt16BE(offset + 3) !== height || jpeg.readUInt16BE(offset + 5) !== width ||
          length !== 8 + 3 * (jpeg[offset + 7] ?? 0)) throw new Error("Native capture JPEG dimensions/format differ from metadata");
      found = true;
    }
    offset += length;
  }
  throw new Error("Native capture JPEG header is incomplete");
}

/** One canonical owner/load and one retained target. Streams may resume only
 * after clean suspension; terminal close retires the target and connection.
 * There is no reconnect, replay, timer, viewer cache, input grant or registry.
 */
class NativeCaptureClient {
  readonly binding: NativeCaptureBinding;
  #transport: NativeCaptureTransport;
  #identity: Identity | undefined;
  #generation: string | undefined;
  #handles = new Map<string, NativeCaptureSource>();
  #selection: { handle: string; region: NativeCaptureRegion | undefined } | undefined;
  #catalogued = false;
  #started = false;
  #ordinary: { done: Promise<void>; settle: () => void } | undefined;
  #suspending = false;
  #suspension: Promise<NativeCaptureJoin> | undefined;
  #readSequence = 0;
  #nativeSequence = -1n;
  #closing = false;
  #close: Promise<NativeCaptureJoin> | undefined;
  #localClose: Promise<void> | undefined;

  private constructor(binding: NativeCaptureBinding, transport: NativeCaptureTransport) {
    this.binding = Object.freeze({ ...binding });
    this.#transport = transport;
  }
  static async open(binding: NativeCaptureBinding): Promise<NativeCaptureClient> {
    const client = new NativeCaptureClient(binding, openNativeCaptureTransport());
    await client.#hello();
    return client;
  }
  async #hello(): Promise<void> {
    const reply = await this.#exchange("hello", "ready");
    this.#identity = {
      loadID: uuid(reply.loadID), bootID: uuid(reply.bootID),
      connectionID: uuid(reply.connectionID), sessionID: uuid(reply.sessionID),
    };
  }
  #retireLocal(): Promise<void> {
    this.#localClose ??= this.#transport.closeLocal();
    return this.#localClose;
  }
  async #retireAfterFailure(cause: unknown): Promise<never> {
    try { await this.#retireLocal(); }
    catch (cleanup) { throw new AggregateError([cause, cleanup], "Native capture failed and local cleanup failed"); }
    throw cause;
  }
  async #exchange(operation: string, expected: string, fields: RecordValue = {}): Promise<RecordValue> {
    const commandID = operation === "pull" ? undefined : randomUUID();
    const stopping = operation === "stop" || operation === "suspend";
    const request = {
      version: 1, operation, loadID: this.binding.runtimeLoadID, ...this.#identity,
      ...(commandID ? { commandID } : {}), ...fields,
    };
    const wire = Buffer.from(JSON.stringify(request));
    if (wire.length > CONTROL_LIMIT) throw new Error("Native capture request exceeds bounds");
    try {
      const { control, jpeg } = await this.#transport.request(wire);
      if (!Buffer.isBuffer(control) || !control.length || control.length > CONTROL_LIMIT ||
          (jpeg !== null && (!Buffer.isBuffer(jpeg) || !jpeg.length || jpeg.length > JPEG_LIMIT))) {
        throw new Error("Native capture reply exceeds bounds");
      }
      const reply = record(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(control)));
      if (reply.version !== 1 || typeof reply.status !== "string") throw new Error("Invalid native capture reply version/status");
      if (errors.has(reply.status) && Object.keys(reply).length === 2) {
        keys(reply, ["version", "status"]);
        if (jpeg) throw new Error("Native capture error carried pixels");
        throw new NativeCaptureHostFailure(reply.status, operation);
      }
      const extra = expected === "catalog" ? ["sources"] : expected === "started" ? ["generation"] :
        expected === "automationEndpoint" ? ["socket", "generation"] :
        operation === "pull" ? (reply.status === "empty" ? ["readSequence"] : ["readSequence", "generation", "sequence", "width", "height"]) :
        stopping && "diagnostic" in reply ? ["diagnostic"] : [];
      keys(reply, ["version", "status", "loadID", "bootID", "connectionID", "sessionID", ...(commandID ? ["commandID"] : []), ...extra]);
      if (uuid(reply.loadID) !== this.binding.runtimeLoadID || (commandID && uuid(reply.commandID) !== commandID)) {
        throw new Error("Native capture reply belongs to another request/load");
      }
      for (const name of ["bootID", "connectionID", "sessionID"] as const) {
        if (this.#identity && uuid(reply[name]) !== this.#identity[name]) throw new Error("Native capture connection identity changed");
        uuid(reply[name]);
      }
      if (stopping && reply.status === "retirementFailed") throw new Error("Native capture host retirement failed; remote resource remains host-owned");
      if (reply.status !== expected && !(operation === "pull" && reply.status === "empty")) throw new Error("Unexpected native capture reply status");
      if (reply.status !== "frame" && jpeg !== null) throw new Error("Native capture non-frame carried pixels");
      if (expected === "started") uuid(reply.generation);
      if (operation === "pull") {
        if (reply.readSequence !== fields.readSequence) throw new Error("Stale native capture read reply");
        if (reply.status === "frame") {
          if (uuid(reply.generation) !== this.#generation || typeof reply.sequence !== "string" ||
              !/^(0|[1-9][0-9]{0,19})$/.test(reply.sequence) || BigInt(reply.sequence) > 18_446_744_073_709_551_615n ||
              BigInt(reply.sequence) <= this.#nativeSequence || !jpeg) throw new Error("Stale/invalid native capture frame");
          jpegDimensions(jpeg, dimension(reply.width), dimension(reply.height));
          this.#nativeSequence = BigInt(reply.sequence);
          reply.generation = this.#generation;
          reply.jpeg = jpeg;
        }
      }
      return reply;
    } catch (cause) {
      // Suspend owns the interrupted ordinary request and its cleanup. Its
      // joined receipt, not a stale read/start reply, decides resumability.
      if (this.#suspending && !stopping) throw cause;
      this.#closing = true;
      this.#handles.clear();
      // An ordinary failure must not invalidate a concurrent accepted Stop.
      // The Stop owner, not the failed presentation read, retires transport.
      if (operation !== "stop" && !this.#close) return this.#retireAfterFailure(cause);
      throw cause;
    }
  }
  #admit(): void {
    if (this.#closing || this.#suspending || !this.#identity) throw new Error("Native capture connection closed or suspended");
    if (this.#ordinary) throw new Error("One native capture catalog/start/pull may be pending");
    let settle!: () => void;
    const done = new Promise<void>((resolve) => { settle = resolve; });
    this.#ordinary = { done, settle };
  }
  #finishOrdinary(): void { this.#ordinary?.settle(); this.#ordinary = undefined; }
  async catalog(): Promise<readonly NativeCaptureSource[]> {
    this.#admit();
    try {
      if (this.#catalogued) throw new Error("Native capture catalog is single-use");
      this.#catalogued = true;
      const reply = await this.#exchange("catalog", "catalog");
      if (this.#closing) throw new Error("Native capture catalog retired before publication");
      if (!Array.isArray(reply.sources) || reply.sources.length > 32) throw new Error("Invalid native capture catalog size");
      const sources = reply.sources.map((value: unknown) => {
        const source = record(value); keys(source, ["handle", "kind", "applicationName", "title", "width", "height"]);
        const handle = uuid(source.handle);
        if (this.#handles.has(handle)) throw new Error("Duplicate native capture source");
        if (source.kind !== "window" && source.kind !== "display") throw new Error("Invalid native source kind");
        if (typeof source.width !== "number" || !Number.isFinite(source.width) || source.width <= 0
          || typeof source.height !== "number" || !Number.isFinite(source.height) || source.height <= 0) throw new Error("Invalid native source dimensions");
        const entry = Object.freeze({ handle, kind: source.kind, applicationName: text(source.applicationName), title: text(source.title), width: source.width, height: source.height });
        this.#handles.set(handle, entry);
        return entry;
      });
      return Object.freeze(sources);
    } catch (cause) {
      // Invalid catalog data is terminal too; no partially accepted handles.
      this.#handles.clear();
      if (!this.#closing) { this.#closing = true; return this.#retireAfterFailure(cause); }
      throw cause;
    } finally { this.#finishOrdinary(); }
  }
  async automationEndpoint(): Promise<NativeAutomationEndpoint> {
    this.#admit();
    try {
      const reply = await this.#exchange("automationEndpoint", "automationEndpoint");
      if (this.#closing) throw new Error("Native automation endpoint retired before publication");
      const generation = uuid(reply.generation), socket = reply.socket;
      if (typeof socket !== "string" || !isAbsolute(socket) || normalize(socket) !== socket || Buffer.byteLength(socket) >= 104
          || /[\u0000-\u001f\u007f]/u.test(socket) || basename(socket) !== "s" || basename(dirname(socket)) !== `tron-cua-${generation}`) {
        throw new Error("Invalid native automation socket");
      }
      return Object.freeze({ socket, generation });
    } finally { this.#finishOrdinary(); }
  }
  async start(handle: string, signal?: AbortSignal, region?: NativeCaptureRegion): Promise<void> {
    region = region === undefined ? undefined : captureRegion(region);
    if (this.#suspension) await this.#suspension;
    signal?.throwIfAborted();
    this.#admit();
    try {
      handle = uuid(handle);
      const source = this.#handles.get(handle);
      if (this.#started || !source) throw new Error("Native capture source unavailable or already used");
      if (region && (source.kind !== "display" || region.x > source.width || region.y > source.height
        || region.width > source.width - region.x || region.height > source.height - region.y)) throw new Error("Region must stay inside its selected display");
      if (this.#selection && (this.#selection.handle !== handle || JSON.stringify(this.#selection.region) !== JSON.stringify(region))) throw new Error("Native capture resume cannot change its selection or crop");
      this.#selection = { handle, region };
      this.#started = true; // Never replay an uncertain start.
      this.#handles = new Map([[handle, source]]); // Resume only this exact source and crop.
      const reply = await this.#exchange("start", "started", { handle, ...(region ? { region } : {}) });
      const generation = uuid(reply.generation);
      if (this.#closing || this.#suspending) throw new Error("Native capture start retired before publication");
      this.#generation = generation;
    } finally { this.#finishOrdinary(); }
  }
  async pull(): Promise<NativeCaptureFrame | undefined> {
    this.#admit();
    try {
      if (!this.#generation || this.#readSequence === Number.MAX_SAFE_INTEGER) throw new Error("Native capture producer/read sequence unavailable");
      const reply = await this.#exchange("pull", "frame", { generation: this.#generation, readSequence: ++this.#readSequence });
      if (this.#closing || this.#suspending) throw new Error("Native capture frame retired before publication");
      if (reply.status === "empty") return undefined;
      return Object.freeze({ generation: this.#generation, readSequence: this.#readSequence,
        sequence: reply.sequence as string, width: reply.width as number, height: reply.height as number, jpeg: reply.jpeg as Buffer });
    } finally { this.#finishOrdinary(); }
  }
  suspend(): Promise<NativeCaptureJoin> {
    if (this.#close) return this.#close;
    if (this.#suspension) return this.#suspension;
    if (this.#closing) return Promise.reject(new Error("Native capture connection closed"));
    if (!this.#started) return Promise.resolve({ status: "joined" }); // No stream was admitted.
    this.#suspending = true;
    const ordinary = this.#ordinary?.done;
    this.#suspension = (async () => {
      try {
        const reply = await this.#exchange("suspend", "joined");
        await ordinary; // XPC can deliver the joined receipt before a read callback.
        if ("diagnostic" in reply) throw new Error("Native capture suspension had a retirement diagnostic");
        this.#started = false; this.#generation = undefined; this.#nativeSequence = -1n;
        return { status: "joined" as const };
      } catch (cause) {
        this.#closing = true; this.#handles.clear();
        if (this.#close) throw cause;
        return this.#retireAfterFailure(cause);
      } finally { this.#suspending = false; this.#suspension = undefined; }
    })();
    return this.#suspension;
  }
  /** Stop bypasses ordinary admission and joins the host's exact pending work.
   * A local error/disconnect is rejection, never a remote joined result.
   */
  close(): Promise<NativeCaptureJoin> {
    if (this.#close) return this.#close;
    const wasClosing = this.#closing;
    this.#closing = true;
    this.#handles.clear();
    this.#close = (async () => {
      let joined: NativeCaptureJoin;
      try {
        // Suspend already owns the reserved native control lane and requests
        // immediate stream Stop. Terminal close joins it before retiring scope.
        if (this.#suspension) await this.#suspension;
        if (wasClosing || !this.#identity) throw new Error("Native capture remote retirement unconfirmed");
        const reply = await this.#exchange("stop", "joined");
        const diagnostic = "diagnostic" in reply ? text(reply.diagnostic) : undefined;
        joined = Object.freeze({ status: "joined" as const, ...(diagnostic !== undefined ? { diagnostic } : {}) });
      } catch (cause) { return this.#retireAfterFailure(cause); }
      // Even malformed Stop metadata must retire local callbacks. Ordinary
      // reads never invalidate this transport while the Stop owner is joining.
      await this.#retireLocal();
      return joined;
    })();
    return this.#close;
  }
}

export async function openNativeCaptureClient(binding: NativeCaptureBinding): Promise<NativeCaptureClient> {
  if (!binding.canonicalSessionID || Buffer.byteLength(binding.canonicalSessionID) > 256) throw new Error("Native capture requires a canonical session owner");
  const normalized = { canonicalSessionID: binding.canonicalSessionID, runtimeLoadID: uuid(binding.runtimeLoadID) };
  return NativeCaptureClient.open(normalized);
}
