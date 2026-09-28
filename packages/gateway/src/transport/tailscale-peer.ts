import { execFile } from "node:child_process";

/**
 * Bounded Tailscale peer-path lookup, shared by the diagnostic bundle
 * (`admin/diagnose.ts`) and the transport's inbound-silence records. It answers
 * "was the Tailscale path to that device up?" from the peer's own socket
 * address, without polling Tailscale on a timer and without blocking a
 * heartbeat: one read serves every socket that goes silent in the same window.
 */

/** The documented Tailscale install, then a CLI-only install on `PATH`. */
export const TAILSCALE_CLI_CANDIDATES = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale"] as const;

/** One wall-clock bound for the whole status read, per candidate and in total.
 * The record is diagnostic, so an unreadable status becomes `unknown` instead
 * of a heartbeat that waits on a process. */
export const TAILSCALE_LOOKUP_TIMEOUT_MS = 2_000;
/** Every lookup in this window reuses one result: a burst of silent sockets
 * costs one CLI run, not one per socket. */
const TAILSCALE_RESULT_REUSE_MS = 10_000;
const MAXIMUM_STATUS_BYTES = 1_024 * 1_024;

/** Tailscale's own path kinds. `offline` is a peer Tailscale knows but cannot
 * reach; `unknown` is no answer at all (no CLI, a timeout, or an address that
 * is not a Tailscale peer, such as the loopback or LAN listener). */
export type PeerPath = "direct" | "relay" | "offline" | "unknown";

export interface PeerPathLookup {
  peerPath: PeerPath;
  /** The relay actually carrying the path, or empty when the peer is not
   * using one (direct or offline). */
  peerRelay: string;
}

export interface PeerPathReader {
  lookup(remoteAddress: string): Promise<PeerPathLookup>;
}

export interface TailscaleStatusResult {
  /** Exit code, or null when the command never ran to completion. */
  code: number | null;
  timedOut: boolean;
  output: string;
  error?: string;
}

export type TailscaleStatusCommand = (tool: string, args: readonly string[], timeoutMs: number) => Promise<TailscaleStatusResult>;

/** The fields of one `tailscale status --json` peer that Tron reads. */
export interface TailscalePeer {
  readonly TailscaleIPs?: unknown;
  readonly HostName?: unknown;
  readonly DNSName?: unknown;
  readonly Online?: unknown;
  readonly CurAddr?: unknown;
  readonly Relay?: unknown;
  readonly LastSeen?: unknown;
}

export interface TailscaleStatus {
  /** The CLI candidate that answered. */
  readonly cli: string;
  /** `Self.TailscaleIPs`, as the status document reported them. */
  readonly self: readonly string[];
  readonly peers: readonly TailscalePeer[];
}

export type TailscaleStatusRead =
  | { readonly ok: true; readonly status: TailscaleStatus }
  | { readonly ok: false; readonly failures: readonly string[] };

function isPeer(value: unknown): value is TailscalePeer {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** One `tailscale status --json` read through the documented candidates, used
 * by both owning readers. `ok: false` carries why each candidate failed, for
 * the diagnostic bundle's "no usable Tailscale CLI" line. Never rejects. */
export async function readTailscaleStatus(run: TailscaleStatusCommand, timeoutMs: number): Promise<TailscaleStatusRead> {
  const failures: string[] = [];
  for (const candidate of TAILSCALE_CLI_CANDIDATES) {
    let result: TailscaleStatusResult;
    try {
      result = await run(candidate, ["status", "--json"], timeoutMs);
    } catch {
      failures.push(`${candidate}: command failed`);
      continue;
    }
    if (result.code !== 0 || result.timedOut) {
      failures.push(`${candidate}: ${result.timedOut ? "timed out" : result.error ?? `exit ${result.code ?? "none"}`}`);
      continue;
    }
    try {
      const parsed: unknown = JSON.parse(result.output);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
      const document = parsed as { Self?: unknown; Peer?: unknown };
      const selfValue = document.Self !== null && typeof document.Self === "object" && !Array.isArray(document.Self)
        ? (document.Self as { TailscaleIPs?: unknown }).TailscaleIPs
        : undefined;
      const peerValue = document.Peer;
      return {
        ok: true,
        status: {
          cli: candidate,
          self: Array.isArray(selfValue) ? selfValue.filter((address): address is string => typeof address === "string") : [],
          peers: peerValue !== null && typeof peerValue === "object" && !Array.isArray(peerValue)
            ? Object.values(peerValue as Record<string, unknown>).filter(isPeer)
            : [],
        },
      };
    } catch {
      failures.push(`${candidate}: unreadable status document`);
    }
  }
  return { ok: false, failures };
}

/** One peer's path, shared by the transport's silence records and the
 * diagnostic bundle so both describe the same peer the same way. `offline`
 * outranks a remembered address: a peer Tailscale cannot reach uses no path. */
export function classifyPeer(peer: TailscalePeer | undefined): PeerPathLookup {
  if (peer === undefined) return { peerPath: "unknown", peerRelay: "" };
  if (peer.Online !== true) return { peerPath: "offline", peerRelay: "" };
  if (typeof peer.CurAddr === "string" && peer.CurAddr.length > 0) return { peerPath: "direct", peerRelay: "" };
  const relay = typeof peer.Relay === "string" ? peer.Relay : "";
  return relay.length > 0 ? { peerPath: "relay", peerRelay: relay } : { peerPath: "unknown", peerRelay: "" };
}

/** Tailscale hands out 100.64.0.0/10 and fd7a:115c:a1e0::/48. Any other
 * address — the loopback a local client uses, or the phone's LAN address on the
 * pinned direct endpoint — cannot appear in `status`, so it is `unknown`
 * without spawning the CLI for it. */
function isTailscaleAddress(address: string): boolean {
  if (address.startsWith("fd7a:115c:a1e0:")) return true;
  const octets = address.split(".");
  if (octets.length !== 4) return false;
  const numbers = octets.map((octet) => (octet === "" ? Number.NaN : Number(octet)));
  if (!numbers.every((value) => Number.isInteger(value) && value >= 0 && value <= 255)) return false;
  const second = numbers[1]!;
  return numbers[0] === 100 && second >= 64 && second <= 127;
}

function runStatus(tool: string, args: readonly string[], timeoutMs: number): Promise<TailscaleStatusResult> {
  return new Promise((resolve) => {
    execFile(tool, [...args], { timeout: timeoutMs, killSignal: "SIGKILL", maxBuffer: MAXIMUM_STATUS_BYTES, encoding: "utf8" }, (error, stdout) => {
      if (!error) {
        resolve({ code: 0, timedOut: false, output: stdout });
        return;
      }
      const failure = error as NodeJS.ErrnoException & { killed?: boolean };
      const code = typeof failure.code === "number" ? failure.code : null;
      resolve({
        code,
        timedOut: failure.killed === true,
        output: stdout,
        ...(code === null ? { error: failure.message } : {}),
      });
    });
  });
}

export class TailscalePeerPaths implements PeerPathReader {
  private cached?: { at: number; peers: readonly TailscalePeer[] } | undefined;
  private inFlight?: Promise<readonly TailscalePeer[]> | undefined;

  constructor(
    private readonly run: TailscaleStatusCommand = runStatus,
    private readonly now: () => number = () => performance.now(),
  ) {}

  async lookup(remoteAddress: string): Promise<PeerPathLookup> {
    // A dual-stack listener reports an IPv4 peer as `::ffff:100.x.y.z`.
    const address = remoteAddress.startsWith("::ffff:") ? remoteAddress.slice(7) : remoteAddress;
    if (!isTailscaleAddress(address)) return { peerPath: "unknown", peerRelay: "" };
    const peers = await this.status();
    return classifyPeer(peers.find((candidate) => Array.isArray(candidate.TailscaleIPs) && candidate.TailscaleIPs.includes(address)));
  }

  /** One read per reuse window and one read in flight. The read is bounded by
   * one wall-clock timer, not by `execFile` settling: a killed child whose
   * grandchild holds the pipe open never fires the callback, and a read that
   * never settles would keep `inFlight` set and suppress every later silence
   * record for the life of the process. `execFile` also ends the child with
   * SIGKILL at its own timeout, so one ignored SIGTERM cannot leave a process
   * running per reuse window. A failed read is cached like a successful one, so
   * a missing CLI cannot spawn a process per silent socket. */
  private status(): Promise<readonly TailscalePeer[]> {
    const cached = this.cached;
    if (cached !== undefined && this.now() - cached.at < TAILSCALE_RESULT_REUSE_MS) return Promise.resolve(cached.peers);
    if (this.inFlight !== undefined) return this.inFlight;
    const read = new Promise<readonly TailscalePeer[]>((resolve) => {
      const deadline = setTimeout(() => resolve([]), TAILSCALE_LOOKUP_TIMEOUT_MS);
      deadline.unref();
      void this.read().then((peers) => {
        clearTimeout(deadline);
        resolve(peers);
      });
    }).then((peers) => {
      this.cached = { at: this.now(), peers };
      this.inFlight = undefined;
      return peers;
    });
    this.inFlight = read;
    return read;
  }

  /** Never rejects: every failure is an empty peer list, which reads as
   * `unknown`. One candidate failing falls through to the next. */
  private async read(): Promise<readonly TailscalePeer[]> {
    const outcome = await readTailscaleStatus(this.run, TAILSCALE_LOOKUP_TIMEOUT_MS);
    return outcome.ok ? outcome.status.peers : [];
  }
}
