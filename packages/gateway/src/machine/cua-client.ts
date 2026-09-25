import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";
import { constants } from "node:fs";
import { mkdtemp, open as openFile, realpath, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { openNativeCaptureClient, type NativeAutomationEndpoint, type NativeCaptureBinding } from "./native-capture-client.js";

const execFileAsync = promisify(execFile);
const DRIVER = "/Applications/Tron.app/Contents/Library/Native/cua-driver";
const OUTPUT_LIMIT = 2 * 1024 * 1024;
const OBSERVATIONS = new Set(["help", "list_apps", "list_windows", "get_window_state", "get_desktop_state", "get_accessibility_tree", "get_cursor_position", "verify_state"]);
const IMAGES = new Set(["get_window_state", "get_desktop_state"]);
const ACTIONS = new Set(["launch_app", "set_window_frame", "bring_to_front", "click", "double_click", "right_click", "type_text", "press_key", "hotkey", "scroll", "drag", "move_cursor", "set_value"]);
const RESERVED = new Set(["session", "_session_id", "socket", "endpoint", "env", "screenshot_out_file"]);
type CuaComputerResult = Readonly<{
  status: "completed" | "refused" | "outcomeUnknown";
  output: unknown;
  endpointGeneration: string;
  image?: { type: "image"; data: string; mimeType: "image/png" };
}>;

function parseCuaOutput(stdout: string, endpointGeneration: string, kind: "observation" | "action" = "observation"): CuaComputerResult {
  if (Buffer.byteLength(stdout) > OUTPUT_LIMIT) throw new Error("Cua output exceeds bounds");
  const output: unknown = JSON.parse(stdout);
  if (!output || typeof output !== "object" || Array.isArray(output)) throw new Error("Invalid Cua result");
  const object = output as Record<string, unknown>;
  const refused = object.status === "refused" || object.status === "background_unavailable" || object.effect === "refused" || object.refusal !== undefined
    || (typeof object.code === "string" && object.activated !== true && object.effect !== "confirmed" && object.status !== "completed");
  const affirmative = object.effect === "confirmed" || object.activated === true || object.success === true
    || ["completed", "success", "confirmed"].includes(String(object.status));
  const uncertain = (kind === "action" && !affirmative) || object.isError === true || object.error !== undefined || object.success === false
    || (typeof object.status === "string" && !["ok", "completed", "success", "activated", "passed", "matched", "verified", "confirmed", "refused"].includes(object.status))
    || ["unverifiable", "partial", "suspected_noop", "suspectedNoop"].includes(String(object.effect));
  return { status: refused ? "refused" : uncertain ? "outcomeUnknown" : "completed", output, endpointGeneration };
}

/** One extension load owns one endpoint binding and one accepted CLI await.
 * The Native Host owns the daemon. A lost endpoint cannot redirect an action to
 * a successor; only an explicit observation may establish a fresh binding. */
export class CuaComputerClient {
  private endpoint: NativeAutomationEndpoint | undefined;
  private pending: Promise<CuaComputerResult> | undefined;
  private closing: Promise<void> | undefined;
  private closed = false;
  private observed = false;
  private desktopObserved = false;
  private pixelObserved = false;
  private refreshEndpoint = false;
  private windowReferences: { pid: number; window: number; tokens: Set<string> } | undefined;

  constructor(private readonly binding: NativeCaptureBinding) {}

  invalidateObservation(): void {
    this.observed = false; this.desktopObserved = false; this.pixelObserved = false; this.windowReferences = undefined;
  }

  invoke(tool: string, arguments_: Record<string, unknown>, signal?: AbortSignal): Promise<CuaComputerResult> {
    signal?.throwIfAborted();
    if (this.closed) throw new Error("Computer session ended");
    if (this.pending) throw new Error("One computer operation may be pending");
    const observation = OBSERVATIONS.has(tool);
    if (!observation && !ACTIONS.has(tool)) throw new Error("This computer tool is not available through Tron");
    if (!arguments_ || typeof arguments_ !== "object" || Array.isArray(arguments_)
      || Object.keys(arguments_).some((name) => name.startsWith("_") || RESERVED.has(name))
      || Buffer.byteLength(JSON.stringify(arguments_)) > 64 * 1024) throw new Error("Invalid or reserved computer arguments");
    if (!observation && !this.observed) throw new Error("Observe the current desktop/window before another action");
    const target = arguments_.target as { kind?: unknown; pid?: unknown; window_id?: unknown } | undefined;
    const pid = arguments_.pid ?? target?.pid, window = arguments_.window_id ?? target?.window_id;
    if (!observation && arguments_.from_zoom === true) throw new Error("Use the current full-window screenshot, not an unowned zoom context");
    if (!observation && ("element_token" in arguments_ || "element_index" in arguments_)) {
      const token = typeof arguments_.element_token === "string" ? arguments_.element_token : `${arguments_.snapshot_id}:${arguments_.element_index}`;
      const refs = this.windowReferences;
      if (!refs || !refs.tokens.has(token) || (pid !== undefined && pid !== refs.pid)
        || (window !== undefined && window !== refs.window) || target?.kind === "desktop") throw new Error("Element reference does not belong to this session's latest window observation");
    }
    const foreground = arguments_.delivery_mode === "foreground" || arguments_.scope === "desktop" || target?.kind === "desktop" || tool === "bring_to_front";
    if (!observation && foreground && !this.desktopObserved) throw new Error("Inspect the full desktop for system dialogs before foreground input");
    if (tool === "set_window_frame" && (!this.windowReferences || pid !== this.windowReferences.pid || window !== this.windowReferences.window)) {
      throw new Error("Window geometry requires the exact observed window");
    }
    if (!observation && tool !== "set_window_frame" && ("x" in arguments_ || "from_x" in arguments_)) {
      const desktop = arguments_.scope === "desktop" || target?.kind === "desktop";
      if (desktop ? !this.desktopObserved : !this.pixelObserved) throw new Error("Capture and inspect pixels before coordinate input");
      if (!desktop && (!this.windowReferences || pid !== this.windowReferences.pid || window !== this.windowReferences.window)) throw new Error("Pixel coordinates require the exact observed window");
    }
    if (!observation) this.invalidateObservation();
    else if (tool === "get_window_state") { this.observed = false; this.pixelObserved = false; this.windowReferences = undefined; }
    else if (tool === "get_desktop_state") { this.observed = false; this.desktopObserved = false; }
    const accepted = JSON.parse(JSON.stringify(arguments_)) as Record<string, unknown>;
    const work = this.execute(tool, accepted, observation, signal);
    this.pending = work;
    void work.then(() => { if (this.pending === work) this.pending = undefined; }, () => { if (this.pending === work) this.pending = undefined; });
    return work;
  }

  private async execute(tool: string, arguments_: Record<string, unknown>, observation: boolean, signal?: AbortSignal): Promise<CuaComputerResult> {
    let directory: string | undefined;
    try {
      if (tool === "help") {
        if (Object.keys(arguments_).some((key) => key !== "tool")) throw new Error("Help accepts only an optional tool name");
        const name = arguments_.tool;
        if (name === undefined) return { status: "completed", output: { tools: [...OBSERVATIONS, ...ACTIONS] }, endpointGeneration: "metadata" };
        if (typeof name !== "string" || (!OBSERVATIONS.has(name) && !ACTIONS.has(name)) || name === "help") throw new Error("Unsupported computer help topic");
        const { stdout } = await execFileAsync(DRIVER, ["describe", name], { env: this.environment(), maxBuffer: OUTPUT_LIMIT, encoding: "utf8", windowsHide: true });
        signal?.throwIfAborted();
        if (this.closed) throw new Error("Computer session ended before help publication");
        return { status: "completed", output: { documentation: stdout }, endpointGeneration: "metadata" };
      }
      if (!this.endpoint || (observation && this.refreshEndpoint)) {
        if (!observation) throw new Error("Observe before establishing a computer endpoint");
        const native = await openNativeCaptureClient(this.binding);
        let endpoint: NativeAutomationEndpoint;
        try { endpoint = await native.automationEndpoint(); }
        finally { await native.close(); }
        signal?.throwIfAborted();
        if (this.closed) throw new Error("Computer session ended during bootstrap");
        this.endpoint = endpoint; this.refreshEndpoint = false;
      }
      const endpoint = this.endpoint!;
      if (observation) {
        // Cua expires idle CLI sessions. Only a fresh observation may revive
        // this load's exact session; never revive or replay an input action.
        const { stdout } = await execFileAsync(DRIVER, ["call", "start_session", JSON.stringify({ session: this.binding.runtimeLoadID }), "--socket", endpoint.socket],
          { env: this.environment(), maxBuffer: OUTPUT_LIMIT, encoding: "utf8", windowsHide: true });
        const activation = parseCuaOutput(stdout, endpoint.generation);
        const state = activation.output as Record<string, unknown>;
        if (activation.status !== "completed" || state.active !== true || typeof state.revived !== "boolean") throw new Error("Cua session activation was not confirmed");
        if (state.revived) this.invalidateObservation();
        signal?.throwIfAborted();
        if (this.closed) throw new Error("Computer session ended during activation");
      }
      const args: Record<string, unknown> = { ...arguments_, session: this.binding.runtimeLoadID };
      if (tool === "get_window_state") {
        for (const [field, fallback, maximum] of [["max_elements", 160, 200], ["max_depth", 12, 16]] as const) {
          const value = args[field] ?? fallback;
          if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) throw new Error("Invalid computer observation bound");
          args[field] = Math.min(value, maximum);
        }
      }
      let imagePath: string | undefined;
      if (IMAGES.has(tool) && args.include_screenshot !== false) {
        directory = await mkdtemp(join(tmpdir(), "tron-computer-"));
        // Cua returns canonical paths. Resolve our owned directory before
        // dispatch so macOS /var → /private/var does not discard valid images.
        directory = await realpath(directory);
        imagePath = join(directory, "observation.png");
        args.screenshot_out_file = imagePath;
      }
      signal?.throwIfAborted();
      if (this.closed) throw new Error("Computer session ended before dispatch");
      // No waiter signal/timeout: do not kill an accepted native invocation.
      // Overflow/transport failure is uncertainty; it never triggers replay.
      const { stdout } = await execFileAsync(DRIVER, ["call", tool, JSON.stringify(args), "--socket", endpoint.socket], {
        env: this.environment(), maxBuffer: OUTPUT_LIMIT, encoding: "utf8", windowsHide: true,
      });
      const result = parseCuaOutput(stdout, endpoint.generation, observation ? "observation" : "action");
      if (signal?.aborted || this.closed) throw new Error("Computer operation interrupted; it may have completed. Do not replay it");
      let image: CuaComputerResult["image"];
      const output = result.output as Record<string, unknown>;
      if (imagePath && output.screenshot_file_path === imagePath && (tool === "get_desktop_state" || output.screenshot_frame_valid === true)) {
        const file = await openFile(imagePath, constants.O_RDONLY | constants.O_NOFOLLOW);
        try {
          const info = await file.stat(), size = info.size;
          if (!info.isFile() || size < 24 || size > 16 * 1024 * 1024) throw new Error("Computer image exceeds bounds");
          const storage = Buffer.allocUnsafe(size + 1);
          let count = 0;
          while (count < storage.length) {
            const read = await file.read(storage, count, storage.length - count, count);
            if (read.bytesRead === 0) break;
            count += read.bytesRead;
          }
          if (count !== size) throw new Error("Computer image changed while reading");
          const bytes = storage.subarray(0, count);
          const width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20);
          if (!bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])) || width < 1 || height < 1
            || width > 8192 || height > 8192 || width * height > 32_000_000 || width !== output.screenshot_width || height !== output.screenshot_height) throw new Error("Invalid computer PNG dimensions");
          image = { type: "image", data: bytes.toString("base64"), mimeType: "image/png" };
        } finally { await file.close(); }
        delete output.screenshot_file_path; // The temporary file is not durable authority.
      }
      if (directory) { await rm(directory, { recursive: true, force: true }); directory = undefined; }
      signal?.throwIfAborted();
      if (this.closed) throw new Error("Computer session ended before publication");
      if (observation && result.status === "completed" && (tool === "get_window_state" || tool === "get_desktop_state")) {
        this.observed = true;
        if (tool === "get_desktop_state" && image) this.desktopObserved = true;
        if (tool === "get_window_state") {
          this.pixelObserved = image !== undefined;
          this.windowReferences = typeof output.pid === "number" && typeof output.window_id === "number"
            ? { pid: output.pid, window: output.window_id, tokens: new Set((Array.isArray(output.elements) ? output.elements : []).slice(0, 200).flatMap((value) =>
                value && typeof value === "object" && typeof value.element_token === "string" ? [value.element_token] : [])) }
            : undefined;
        }
      }
      return { ...result, ...(image ? { image } : {}) };
    } catch (error) {
      this.invalidateObservation();
      // Keep the old descriptor for shutdown; only an explicit observation may
      // rebind after a failed invocation, never an action or automatic retry.
      this.refreshEndpoint = true;
      throw new Error(`Computer operation unavailable or uncertain; observe before acting again. ${error instanceof Error ? error.message : String(error)}`);
    } finally { if (directory) await rm(directory, { recursive: true, force: true }); }
  }

  private environment(): NodeJS.ProcessEnv {
    return { HOME: homedir(), PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR: tmpdir(), LANG: "en_US.UTF-8",
      CUA_DRIVER_RS_TELEMETRY_ENABLED: "false", CUA_TELEMETRY_ENABLED: "false" };
  }

  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.closed = true;
    this.closing = (async () => {
      await this.pending?.catch(() => {}); // Invocation reports its own result/error.
      const endpoint = this.endpoint; this.endpoint = undefined;
      if (!endpoint) return;
      for (;;) {
        const { stdout } = await execFileAsync(DRIVER, ["call", "end_session", JSON.stringify({ session: this.binding.runtimeLoadID }), "--socket", endpoint.socket],
          { env: this.environment(), maxBuffer: OUTPUT_LIMIT, encoding: "utf8", windowsHide: true });
        const result = JSON.parse(stdout) as Record<string, unknown>;
        if (result.code === "session_cleanup_pending") {
          // The driver's documented idempotent cleanup operation is still
          // joining native work. Poll that receipt, never repeat the action.
          await delay(100); continue;
        }
        if (result.active !== false || result.code !== undefined || result.error !== undefined) throw new Error("Cua session cleanup was not confirmed");
        break;
      }
    })();
    return this.closing;
  }
}
