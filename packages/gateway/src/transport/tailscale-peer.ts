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

/** One silent socket waits at most this long for the CLI. The record is
 * diagnostic, so an unreadable status becomes `unknown` instead of a heartbeat
 * that waits on a process. */
const TAILSCALE_LOOKUP_TIMEOUT_MS = 2_000;
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
  /** The relay's region code, or empty when the peer uses no relay. */
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

interface TailscalePeer {
  readonly TailscaleIPs?: unknown;
  readonly CurAddr?: unknown;
  readonly Relay?: unknown;
  readonly Online?: unknown;
}

function runStatus(tool: string, args: readonly string[], timeoutMs: number): Promise<TailscaleStatusResult> {
  return new Promise((resolve) => {
    execFile(tool, [...args], { timeout: timeoutMs, maxBuffer: MAXIMUM_STATUS_BYTES, encoding: "utf8" }, (error, stdout) => {
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
    const peers = await this.status();
    // A dual-stack listener reports an IPv4 peer as `::ffff:100.x.y.z`.
    const address = remoteAddress.startsWith("::ffff:") ? remoteAddress.slice(7) : remoteAddress;
    const peer = peers.find((candidate) => Array.isArray(candidate.TailscaleIPs) && candidate.TailscaleIPs.includes(address));
    if (peer === undefined) return { peerPath: "unknown", peerRelay: "" };
    const relay = typeof peer.Relay === "string" ? peer.Relay : "";
    if (peer.Online !== true) return { peerPath: "offline", peerRelay: relay };
    if (typeof peer.CurAddr === "string" && peer.CurAddr.length > 0) return { peerPath: "direct", peerRelay: relay };
    // A peer using a relay carries no current direct address.
    return relay.length > 0 ? { peerPath: "relay", peerRelay: relay } : { peerPath: "unknown", peerRelay: "" };
  }

  /** One read per reuse window and one read in flight. A failed read is cached
   * like a successful one, so a missing CLI cannot spawn a process per silent
   * socket. */
  private status(): Promise<readonly TailscalePeer[]> {
    const cached = this.cached;
    if (cached !== undefined && this.now() - cached.at < TAILSCALE_RESULT_REUSE_MS) return Promise.resolve(cached.peers);
    if (this.inFlight !== undefined) return this.inFlight;
    const read = this.read().then((peers) => {
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
    for (const candidate of TAILSCALE_CLI_CANDIDATES) {
      let result: TailscaleStatusResult;
      try {
        result = await this.run(candidate, ["status", "--json"], TAILSCALE_LOOKUP_TIMEOUT_MS);
      } catch {
        continue;
      }
      if (result.code !== 0 || result.timedOut) continue;
      try {
        const document: unknown = JSON.parse(result.output);
        const peers = document !== null && typeof document === "object"
          ? (document as { Peer?: unknown }).Peer
          : undefined;
        if (peers === null || typeof peers !== "object" || Array.isArray(peers)) continue;
        return Object.values(peers as Record<string, TailscalePeer>);
      } catch {
        continue;
      }
    }
    return [];
  }
}
