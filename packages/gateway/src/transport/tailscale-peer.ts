import { classifyPeer, readTailscaleStatus, runBoundedCommand, type BoundedCommand, type TailscaleStatusRead } from "../platform/tailscale-status.js";

/**
 * Transport's bounded Tailscale peer-path lookup for inbound-silence records.
 * The platform probe supplies the same host facts used by diagnostics. It answers
 * "was the Tailscale path to that device up?" from the peer's own socket
 * address, without polling Tailscale on a timer and without blocking a
 * heartbeat: one read serves every socket that goes silent in the same window.
 */

/** One wall-clock bound for the whole status read, per candidate and in total.
 * The record is diagnostic, so an unreadable status becomes `unknown` instead
 * of a heartbeat that waits on a process. */
const TAILSCALE_LOOKUP_TIMEOUT_MS = 2_000;
/** Every lookup in this window reuses one result: a burst of silent sockets
 * costs one CLI run, not one per socket. */
const TAILSCALE_RESULT_REUSE_MS = 10_000;

export interface PeerPathLookup extends ReturnType<typeof classifyPeer> {
  peerPathSource: "tailscale-status" | "cli-failed" | "not-tailscale" | "not-in-status" | "timeout";
  peerLastHandshake?: string;
  peerRxBytes?: number;
  peerTxBytes?: number;
}

export interface PeerPathReader {
  lookup(remoteAddress: string): Promise<PeerPathLookup>;
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

export class TailscalePeerPaths implements PeerPathReader {
  private cached?: { at: number; status: TailscaleStatusRead } | undefined;
  private inFlight?: Promise<TailscaleStatusRead> | undefined;

  constructor(
    private readonly run: BoundedCommand = runBoundedCommand,
    private readonly now: () => number = () => performance.now(),
  ) {}

  async lookup(remoteAddress: string): Promise<PeerPathLookup> {
    // A dual-stack listener reports an IPv4 peer as `::ffff:100.x.y.z`.
    const address = remoteAddress.startsWith("::ffff:") ? remoteAddress.slice(7) : remoteAddress;
    if (!isTailscaleAddress(address)) return { peerPath: "unknown", peerPathSource: "not-tailscale", peerRelay: "" };
    const status = await this.status();
    if (!status.ok) {
      return { peerPath: "unknown", peerPathSource: status.reason, peerRelay: "" };
    }
    const peer = status.status.peers.find((candidate) => Array.isArray(candidate.TailscaleIPs) && candidate.TailscaleIPs.includes(address));
    if (peer === undefined) return { peerPath: "unknown", peerPathSource: "not-in-status", peerRelay: "" };
    const handshake = typeof peer.LastHandshake === "string"
      && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/u.test(peer.LastHandshake)
      && Number.isFinite(Date.parse(peer.LastHandshake)) ? new Date(peer.LastHandshake).toISOString() : undefined;
    return {
      ...classifyPeer(peer), peerPathSource: "tailscale-status",
      ...(handshake !== undefined ? { peerLastHandshake: handshake } : {}),
      ...(typeof peer.RxBytes === "number" && Number.isSafeInteger(peer.RxBytes) && peer.RxBytes >= 0 ? { peerRxBytes: peer.RxBytes } : {}),
      ...(typeof peer.TxBytes === "number" && Number.isSafeInteger(peer.TxBytes) && peer.TxBytes >= 0 ? { peerTxBytes: peer.TxBytes } : {}),
    };
  }

  /** One read per reuse window and one read in flight. The read is bounded by
   * one wall-clock timer, not by `execFile` settling: a killed child whose
   * grandchild holds the pipe open never fires the callback, and a read that
   * never settles would keep `inFlight` set and suppress every later silence
   * record for the life of the process. `execFile` also ends the child with
   * SIGKILL at its own timeout, so one ignored SIGTERM cannot leave a process
   * running per reuse window. A failed read is cached like a successful one, so
   * a missing CLI cannot spawn a process per silent socket. */
  private status(): Promise<TailscaleStatusRead> {
    const cached = this.cached;
    if (cached !== undefined && this.now() - cached.at < TAILSCALE_RESULT_REUSE_MS) return Promise.resolve(cached.status);
    if (this.inFlight !== undefined) return this.inFlight;
    const read = new Promise<TailscaleStatusRead>((resolve) => {
      const deadline = setTimeout(() => resolve({ ok: false, failures: ["status timed out"], reason: "timeout" }), TAILSCALE_LOOKUP_TIMEOUT_MS);
      deadline.unref();
      void this.read().then((status) => {
        clearTimeout(deadline);
        resolve(status);
      });
    }).then((status) => {
      this.cached = { at: this.now(), status };
      this.inFlight = undefined;
      return status;
    });
    this.inFlight = read;
    return read;
  }

  /** One candidate failing falls through to the next; the bounded read retains
   * failure categories so silence records distinguish a timeout from no CLI. */
  private async read(): Promise<TailscaleStatusRead> {
    return readTailscaleStatus(this.run, TAILSCALE_LOOKUP_TIMEOUT_MS);
  }
}
