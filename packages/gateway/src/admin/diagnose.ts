import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { redact } from "../transport/logger.js";
import { resolveTronHome } from "../tron-home.js";

/**
 * Read-only diagnostic bundle for one incident. It collects the log streams in
 * the window, the newest device exports, payload selection and progress,
 * launchd's records for `com.tron.server`, `/health`, Tron processes with their
 * payload versions, `scripts/tron mac verify` and Tailscale's view of each
 * paired peer. It writes exactly one file, at `--out`, and never writes to the
 * Tron home, launchd or the Gateway.
 */

/** `--since` default: covers a failure the user noticed earlier today. */
const DEFAULT_SINCE = "2h";
/** `<count><unit>`; the same text is handed to `log show --last`. */
const DURATION_PATTERN = /^([1-9][0-9]{0,3})([smhd])$/u;
const UNIT_MS: Record<string, number> = { s: 1_000, m: 60_000, h: 3_600_000, d: 86_400_000 };
/** One shareable artifact: per-stream, per-section and total caps keep it bounded. */
const MAX_STREAM_BYTES = 1_024 * 1_024;
const MAX_LOGS_SECTION_BYTES = 4 * 1_024 * 1_024;
const MAX_SECTION_BYTES = 256 * 1_024;
const MAX_DEVICE_EXPORT_BYTES = 512 * 1_024;
const MAX_DEVICE_EXPORTS = 3;
const MAX_COMMAND_OUTPUT_BYTES = 8 * 1_024 * 1_024;
/** A two-hour `log show` measured about 20 s on a busy Mac. */
const LOG_SHOW_TIMEOUT_MS = 90_000;
const MAC_VERIFY_TIMEOUT_MS = 180_000;
const TAILSCALE_TIMEOUT_MS = 15_000;
const PROCESS_LIST_TIMEOUT_MS = 10_000;
const HEALTH_TIMEOUT_MS = 3_000;
/** `/usr/bin/log` explicitly: a shell's `log` builtin shadows the command. */
const LOG_TOOL = "/usr/bin/log";
const PROCESS_LIST_TOOL = "/bin/ps";
/** The documented Tailscale install, then a CLI-only install on `PATH`. */
const TAILSCALE_CLI_CANDIDATES = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale"] as const;
/** The macsys network extension owns Tailscale's endpoint decisions. */
const TAILSCALE_EXTENSION_PROCESS = "io.tailscale.ipn.macsys.network-extension";
/** Path-change evidence: magicsock lines name the endpoint a peer now uses. */
const TAILSCALE_PATH_LINE = /magicsock/iu;
/** Files written by the payload store, per channel. */
const PAYLOAD_DOCUMENTS = ["current.json", "previous.json", "deployment-state.json", "update-progress.json"] as const;
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");

export interface BoundedCommandResult {
  /** Exit code, or null when the command never ran to completion. */
  code: number | null;
  timedOut: boolean;
  output: string;
  error?: string;
}

export type BoundedCommand = (tool: string, args: readonly string[], timeoutMs: number) => Promise<BoundedCommandResult>;

export interface HealthResult {
  status?: number;
  body?: string;
  error?: string;
}

export type HealthReader = (url: string) => Promise<HealthResult>;

export interface DiagnosticBundleOptions {
  /** `<count><s|m|h|d>`; defaults to `2h`. */
  since?: string;
  /** Bundle path; defaults to a new file in the system temp directory. */
  out?: string;
  now?: Date;
  tronHome?: string;
  /** Injected so a test can run against a fixture home without external tools. */
  runCommand?: BoundedCommand;
  readHealth?: HealthReader;
}

interface Section {
  readonly name: string;
  readonly lines: readonly string[];
}

interface GatewayProcess {
  readonly pid: string;
  readonly host: string;
  readonly port: number | undefined;
}

interface TailscalePeer {
  readonly HostName?: unknown;
  readonly DNSName?: unknown;
  readonly Online?: unknown;
  readonly CurAddr?: unknown;
  readonly Relay?: unknown;
  readonly LastSeen?: unknown;
}

interface PairedDevice {
  readonly id: string;
  readonly names: readonly string[];
}

function runBounded(tool: string, args: readonly string[], timeoutMs: number): Promise<BoundedCommandResult> {
  return new Promise((resolvePromise) => {
    execFile(tool, [...args], { timeout: timeoutMs, maxBuffer: MAX_COMMAND_OUTPUT_BYTES, encoding: "utf8" }, (error, stdout) => {
      if (!error) {
        resolvePromise({ code: 0, timedOut: false, output: stdout });
        return;
      }
      const failure = error as NodeJS.ErrnoException & { killed?: boolean };
      const code = typeof failure.code === "number" ? failure.code : null;
      resolvePromise({
        code,
        timedOut: failure.killed === true,
        output: stdout,
        ...(code === null ? { error: failure.message } : {}),
      });
    });
  });
}

async function readHealthBounded(url: string): Promise<HealthResult> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(HEALTH_TIMEOUT_MS) });
    return { status: response.status, body: (await response.text()).slice(0, MAX_SECTION_BYTES) };
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) };
  }
}

/** Keeps the newest bytes: a bundle is read for what just happened. */
function boundedTail(text: string, maximum: number): { text: string; truncated: boolean } {
  const bytes = Buffer.from(text, "utf8");
  if (bytes.byteLength <= maximum) return { text, truncated: false };
  const sliced = bytes.subarray(bytes.byteLength - maximum).toString("utf8");
  const firstNewline = sliced.indexOf("\n");
  return { text: firstNewline >= 0 ? sliced.slice(firstNewline + 1) : sliced, truncated: true };
}

async function readBoundedFile(path: string, maximum: number): Promise<{ text: string; bytes: number; truncated: boolean } | undefined> {
  try {
    const content = await readFile(path);
    return { ...boundedTail(content.toString("utf8"), maximum), bytes: content.byteLength };
  } catch {
    return undefined;
  }
}

function formatBytes(bytes: number): string {
  return bytes < 1_024 ? `${bytes} B` : `${(bytes / 1_024).toFixed(1)} KB`;
}

function recordTimestampMs(line: string): number | undefined {
  if (!line.startsWith("{")) return undefined;
  try {
    const parsed: unknown = JSON.parse(line);
    if (!parsed || typeof parsed !== "object") return undefined;
    const timestamp = (parsed as { timestamp?: unknown }).timestamp;
    if (typeof timestamp !== "string") return undefined;
    const value = Date.parse(timestamp);
    return Number.isNaN(value) ? undefined : value;
  } catch {
    return undefined;
  }
}

function commandLines(tool: string, args: readonly string[], result: BoundedCommandResult): string[] {
  const lines = [`$ ${[tool, ...args].join(" ")}`];
  if (result.timedOut) lines.push("timed out");
  else if (result.code !== 0) lines.push(`exit=${result.code ?? "none"}${result.error === undefined ? "" : ` ${result.error}`}`);
  else lines.push("exit=0");
  const output = boundedTail(result.output.trimEnd(), MAX_SECTION_BYTES);
  if (output.text.length > 0) lines.push(...output.text.split("\n"));
  else lines.push("(no output)");
  if (output.truncated) lines.push("(output truncated)");
  return lines;
}

function renderBundle(header: readonly string[], sections: readonly Section[]): string {
  const parts = [header.map(redact).join("\n")];
  for (const section of sections) {
    parts.push([`## ${section.name}`, ...section.lines.map(redact)].join("\n"));
  }
  return `${parts.join("\n\n")}\n`;
}

async function logsSection(logsDirectory: string, windowStartMs: number): Promise<Section> {
  let entries: string[];
  try {
    entries = await readdir(logsDirectory);
  } catch {
    return { name: "logs", lines: [`no log directory at ${logsDirectory}`] };
  }
  const files: Array<{ path: string; name: string; mtimeMs: number }> = [];
  for (const entry of entries) {
    const path = join(logsDirectory, entry);
    const info = await lstat(path).catch(() => undefined);
    if (info?.isFile()) files.push({ path, name: entry, mtimeMs: info.mtimeMs });
  }
  if (files.length === 0) return { name: "logs", lines: ["no log streams present"] };
  files.sort((left, right) => right.mtimeMs - left.mtimeMs);
  const lines: string[] = [];
  let written = 0;
  for (const file of files) {
    if (written >= MAX_LOGS_SECTION_BYTES) {
      lines.push("(remaining streams omitted: bundle size bound)");
      break;
    }
    const stream = await readBoundedFile(file.path, MAX_STREAM_BYTES);
    if (!stream) continue;
    const heading = `### ${file.name} (${formatBytes(stream.bytes)}${stream.truncated ? ", newest kept" : ""})`;
    const content = stream.text.split("\n").filter((line) => line.trim() !== "");
    const timestamped = content.filter((line) => recordTimestampMs(line) !== undefined);
    if (content.length === 0) {
      lines.push(heading, "(empty)");
    } else if (timestamped.length === 0) {
      // A stream without record timestamps (launcher or stderr text) is bounded
      // by the file's own modification time instead.
      if (file.mtimeMs >= windowStartMs) lines.push(heading, ...content);
      else lines.push(heading, "(not modified in the window)");
    } else {
      const kept = timestamped.filter((line) => (recordTimestampMs(line) ?? 0) >= windowStartMs);
      lines.push(heading, `(${kept.length} of ${content.length} lines in the window)`, ...kept);
    }
    written += Buffer.byteLength(lines.join("\n"));
  }
  return { name: "logs", lines };
}

async function deviceExportsSection(logsDirectory: string): Promise<Section> {
  const directory = join(logsDirectory, "device-exports");
  let entries: string[];
  try {
    entries = await readdir(directory);
  } catch {
    return { name: "device-exports", lines: [`no device export directory at ${directory}`] };
  }
  const files: Array<{ path: string; name: string; mtimeMs: number }> = [];
  for (const entry of entries) {
    const path = join(directory, entry);
    const info = await lstat(path).catch(() => undefined);
    if (info?.isFile()) files.push({ path, name: entry, mtimeMs: info.mtimeMs });
  }
  files.sort((left, right) => right.mtimeMs - left.mtimeMs);
  if (files.length === 0) return { name: "device-exports", lines: [`no device exports in ${directory}`] };
  const lines: string[] = [];
  for (const file of files.slice(0, MAX_DEVICE_EXPORTS)) {
    const stream = await readBoundedFile(file.path, MAX_DEVICE_EXPORT_BYTES);
    if (!stream) continue;
    lines.push(`### ${file.name} (${formatBytes(stream.bytes)}${stream.truncated ? ", newest kept" : ""})`);
    lines.push(...stream.text.split("\n").filter((line) => line.trim() !== ""));
  }
  if (files.length > MAX_DEVICE_EXPORTS) lines.push(`(${files.length - MAX_DEVICE_EXPORTS} older exports omitted)`);
  return { name: "device-exports", lines };
}

async function payloadSelectionSection(payloadsDirectory: string): Promise<Section> {
  let channels: string[];
  try {
    const entries = await readdir(payloadsDirectory, { withFileTypes: true });
    channels = entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
  } catch {
    return { name: "payload-selection", lines: [`no payload store at ${payloadsDirectory}`] };
  }
  if (channels.length === 0) return { name: "payload-selection", lines: [`no payload channels at ${payloadsDirectory}`] };
  const lines: string[] = [];
  for (const channel of channels) {
    for (const document of PAYLOAD_DOCUMENTS) {
      const stream = await readBoundedFile(join(payloadsDirectory, channel, document), MAX_SECTION_BYTES);
      if (!stream) {
        lines.push(`### ${channel}/${document} — missing`);
        continue;
      }
      lines.push(`### ${channel}/${document}`, stream.text.trim());
    }
  }
  return { name: "payload-selection", lines };
}

/** Gateway payload processes, the installed app and the native host. Other
 * processes under the Tron home (agents) are excluded: their arguments can
 * carry prompt text. */
function isTronProcess(command: string, tronHome: string): boolean {
  return command.includes(`${join(tronHome, "gateway", "payloads")}/`) || command.includes("/Applications/Tron.app") || command.includes("TronNativeHost");
}

async function processesSection(tronHome: string, runCommand: BoundedCommand): Promise<{ section: Section; gateway: GatewayProcess | undefined }> {
  const args = ["-ww", "-axo", "pid=,etime=,command="];
  const result = await runCommand(PROCESS_LIST_TOOL, args, PROCESS_LIST_TIMEOUT_MS);
  if (result.code !== 0 || result.timedOut) {
    return { section: { name: "processes", lines: commandLines(PROCESS_LIST_TOOL, args, result) }, gateway: undefined };
  }
  const lines: string[] = [];
  let gateway: GatewayProcess | undefined;
  for (const raw of result.output.split("\n")) {
    const match = /^\s*(\d+)\s+(\S+)\s+(.*)$/u.exec(raw.trimEnd());
    if (!match) continue;
    const [, pid, elapsed, command] = match;
    if (pid === undefined || elapsed === undefined || command === undefined || !isTronProcess(command, tronHome)) continue;
    const payload = /payloads\/([^/\s]+)\/versions\/([^/\s]+)\//u.exec(command);
    const channel = payload?.[1] === undefined ? "" : ` channel=${payload[1]}`;
    const version = payload?.[2] === undefined ? "" : ` payloadVersion=${payload[2]}`;
    lines.push(`pid=${pid} elapsed=${elapsed}${channel}${version}`, command);
    if (gateway === undefined && command.includes("/app/dist/index.js")) {
      const port = /--port\s+(\d+)/u.exec(command);
      gateway = { pid, host: /--host\s+(\S+)/u.exec(command)?.[1] ?? "loopback", port: port?.[1] === undefined ? undefined : Number(port[1]) };
    }
  }
  if (lines.length === 0) lines.push("no Tron process found");
  return { section: { name: "processes", lines }, gateway };
}

async function launchdSection(since: string, runCommand: BoundedCommand): Promise<Section> {
  const args = ["show", "--style", "compact", "--last", since, "--predicate", 'process == "launchd" AND eventMessage CONTAINS "com.tron.server"'];
  const result = await runCommand(LOG_TOOL, args, LOG_SHOW_TIMEOUT_MS);
  return { name: "launchd", lines: commandLines(LOG_TOOL, args, result) };
}

function normalizedName(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/gu, "");
}

function peerField(peer: TailscalePeer, field: keyof TailscalePeer): string | undefined {
  const value = peer[field];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function matchPeer(peers: readonly TailscalePeer[], names: readonly string[]): TailscalePeer | undefined {
  const wanted = names.map(normalizedName);
  return peers.find((peer) => {
    const candidates = [peerField(peer, "HostName"), peerField(peer, "DNSName")?.split(".")[0]]
      .filter((candidate): candidate is string => candidate !== undefined)
      .map(normalizedName);
    return candidates.some((candidate) => wanted.includes(candidate));
  });
}

async function pairedDevices(tronHome: string): Promise<PairedDevice[]> {
  const content = await readFile(join(tronHome, "gateway", "devices.json"), "utf8").catch(() => undefined);
  if (content === undefined) return [];
  try {
    const parsed: unknown = JSON.parse(content);
    if (!parsed || typeof parsed !== "object") return [];
    const records = (parsed as { devices?: unknown }).devices;
    if (!Array.isArray(records)) return [];
    return records.flatMap((record) => {
      if (!record || typeof record !== "object") return [];
      const entry = record as Record<string, unknown>;
      const id = typeof entry.id === "string" ? entry.id : undefined;
      const names = [entry.customLabel, entry.observedName, entry.name].filter((value): value is string => typeof value === "string");
      if (id === undefined || names.length === 0) return [];
      return [{ id, names }];
    });
  } catch {
    return [];
  }
}

async function tailscaleSection(tronHome: string, since: string, runCommand: BoundedCommand): Promise<{ section: Section; selfAddress: string | undefined }> {
  const lines: string[] = [];
  const failures: string[] = [];
  let cli: string | undefined;
  let document: { Self?: unknown; Peer?: unknown } | undefined;
  for (const candidate of TAILSCALE_CLI_CANDIDATES) {
    const result = await runCommand(candidate, ["status", "--json"], TAILSCALE_TIMEOUT_MS);
    if (result.code !== 0 || result.timedOut) {
      failures.push(`${candidate}: ${result.timedOut ? "timed out" : result.error ?? `exit ${result.code ?? "none"}`}`);
      continue;
    }
    try {
      const parsed: unknown = JSON.parse(result.output);
      if (parsed && typeof parsed === "object") {
        cli = candidate;
        document = parsed as { Self?: unknown; Peer?: unknown };
        break;
      }
      failures.push(`${candidate}: unreadable status document`);
    } catch {
      failures.push(`${candidate}: unreadable status document`);
    }
  }
  if (document === undefined || cli === undefined) {
    return { section: { name: "tailscale", lines: [`no usable Tailscale CLI (${failures.join("; ")})`] }, selfAddress: undefined };
  }
  const self = document.Self && typeof document.Self === "object" ? (document.Self as { TailscaleIPs?: unknown }).TailscaleIPs : undefined;
  const selfAddress = Array.isArray(self) ? self.find((address): address is string => typeof address === "string" && !address.includes(":")) : undefined;
  const peers = document.Peer && typeof document.Peer === "object" ? Object.values(document.Peer as Record<string, TailscalePeer>) : [];
  lines.push(`cli: ${cli}`, `self: ${selfAddress ?? "no Tailscale IPv4 address"}`);
  lines.push("### paired devices");
  const devices = await pairedDevices(tronHome);
  if (devices.length === 0) lines.push("no paired devices recorded");
  for (const device of devices) {
    const peer = matchPeer(peers, device.names);
    const endpoint = peer === undefined ? undefined : peerField(peer, "CurAddr") ?? peerField(peer, "Relay");
    const path = peer === undefined ? "unknown" : peerField(peer, "CurAddr") !== undefined ? "direct" : peerField(peer, "Relay") !== undefined ? "relay" : "unknown";
    lines.push([
      `deviceIdHash=${createHash("sha256").update(device.id).digest("hex").slice(0, 12)}`,
      `peer=${peer === undefined ? "none" : peerField(peer, "DNSName")?.split(".")[0] ?? peerField(peer, "HostName") ?? "unnamed"}`,
      `online=${peer === undefined ? "unknown" : peer.Online === true}`,
      `path=${path}`,
      `endpoint=${endpoint ?? "unknown"}`,
      `lastSeen=${peer === undefined ? "unknown" : peerField(peer, "LastSeen") ?? "unknown"}`,
    ].join(" "));
  }
  lines.push("### network-extension path lines");
  const extensionArgs = ["show", "--style", "compact", "--last", since, "--predicate", `process == "${TAILSCALE_EXTENSION_PROCESS}"`];
  const extension = await runCommand(LOG_TOOL, extensionArgs, LOG_SHOW_TIMEOUT_MS);
  lines.push(`$ ${[LOG_TOOL, ...extensionArgs].join(" ")}`);
  if (extension.timedOut || extension.code !== 0) {
    lines.push(`exit=${extension.code ?? "none"}${extension.error === undefined ? "" : ` ${extension.error}`}`);
  }
  const pathLines = extension.output.split("\n").filter((line) => TAILSCALE_PATH_LINE.test(line));
  if (pathLines.length === 0) lines.push("no path-change lines in the window");
  else lines.push(...boundedTail(pathLines.join("\n"), MAX_SECTION_BYTES).text.split("\n"));
  return { section: { name: "tailscale", lines }, selfAddress };
}

async function healthSection(gateway: GatewayProcess | undefined, selfAddress: string | undefined, readHealth: HealthReader): Promise<Section> {
  if (gateway === undefined) return { name: "health", lines: ["no running Gateway process; /health not probed"] };
  if (gateway.port === undefined) return { name: "health", lines: [`Gateway pid=${gateway.pid} has no --port argument; /health not probed`] };
  const address = gateway.host === "tailscale" ? selfAddress : gateway.host === "loopback" ? "127.0.0.1" : gateway.host;
  if (address === undefined) return { name: "health", lines: ["--host tailscale address unresolved; /health not probed"] };
  const url = `http://${address}:${gateway.port}/health`;
  const result = await readHealth(url);
  if (result.error !== undefined) return { name: "health", lines: [`GET ${url}`, `error: ${result.error}`] };
  return { name: "health", lines: [`GET ${url}`, `status: ${result.status ?? "none"}`, ...(result.body === undefined ? [] : result.body.trimEnd().split("\n"))] };
}

async function macVerifySection(runCommand: BoundedCommand): Promise<Section> {
  const tool = join(REPO_ROOT, "scripts", "tron");
  const args = ["mac", "verify"];
  const present = await lstat(tool).catch(() => undefined);
  if (present === undefined) return { name: "mac-verify", lines: [`not available: no ${tool} in this checkout`] };
  const result = await runCommand(tool, args, MAC_VERIFY_TIMEOUT_MS);
  return { name: "mac-verify", lines: commandLines(tool, args, result) };
}

function parseDuration(value: string): number | undefined {
  const match = DURATION_PATTERN.exec(value);
  if (!match || match[1] === undefined || match[2] === undefined) return undefined;
  return Number(match[1]) * (UNIT_MS[match[2]] ?? 0);
}

export async function collectDiagnosticBundle(options: DiagnosticBundleOptions = {}): Promise<{ path: string }> {
  const since = options.since ?? DEFAULT_SINCE;
  const sinceMs = parseDuration(since);
  if (sinceMs === undefined) throw new Error(`invalid --since value: ${since}`);
  const now = options.now ?? new Date();
  const windowStartMs = now.getTime() - sinceMs;
  const tronHome = options.tronHome ?? resolveTronHome();
  const runCommand = options.runCommand ?? runBounded;
  const readHealth = options.readHealth ?? readHealthBounded;
  const logsDirectory = join(tronHome, "logs");
  const logs = await logsSection(logsDirectory, windowStartMs);
  const deviceExports = await deviceExportsSection(logsDirectory);
  const payloadSelection = await payloadSelectionSection(join(tronHome, "gateway", "payloads"));
  const processes = await processesSection(tronHome, runCommand);
  const launchd = await launchdSection(since, runCommand);
  const tailscale = await tailscaleSection(tronHome, since, runCommand);
  const health = await healthSection(processes.gateway, tailscale.selfAddress, readHealth);
  const macVerify = await macVerifySection(runCommand);
  const header = [
    "# Tron diagnostic bundle",
    `generatedAt: ${now.toISOString()}`,
    `since: ${since} (from ${new Date(windowStartMs).toISOString()})`,
    `tronHome: ${tronHome}`,
    `collector: node ${process.version}`,
  ];
  const path = options.out ?? join(tmpdir(), `tron-diagnose-${now.toISOString().replace(/[:.]/gu, "-")}.txt`);
  const bundle = renderBundle(header, [logs, deviceExports, payloadSelection, processes.section, launchd, tailscale.section, health, macVerify]);
  try {
    await writeFile(path, bundle, { encoding: "utf8", flag: "wx", mode: 0o600 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error(`output already exists: ${path}`);
    throw error;
  }
  return { path };
}

const USAGE = "Usage: scripts/tron diagnose [--since <1..9999><s|m|h|d>] [--out <path>]";

function usage(): never {
  console.error(USAGE);
  process.exit(64);
}

function parseArguments(args: readonly string[]): DiagnosticBundleOptions {
  let since: string | undefined;
  let out: string | undefined;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--help" || argument === "-h") {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    } else if (argument === "--since") {
      const raw = args[++index];
      if (raw === undefined || parseDuration(raw) === undefined) usage();
      since = raw;
    } else if (argument === "--out") {
      const raw = args[++index];
      if (raw === undefined || raw.length === 0) usage();
      out = resolve(raw);
    } else usage();
  }
  return { ...(since === undefined ? {} : { since }), ...(out === undefined ? {} : { out }) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const result = await collectDiagnosticBundle(parseArguments(process.argv.slice(2)));
    process.stdout.write(`Tron diagnostic bundle written to ${result.path}\n`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
