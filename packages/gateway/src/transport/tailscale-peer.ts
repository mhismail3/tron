import { classifyPeer, readTailscaleStatus, runBoundedCommand, type BoundedCommand, type TailscaleStatusRead } from "../platform/tailscale-status.js";

const TAILSCALE_LOOKUP_TIMEOUT_MS = 2_000;
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

  private async read(): Promise<TailscaleStatusRead> {
    return readTailscaleStatus(this.run, TAILSCALE_LOOKUP_TIMEOUT_MS);
  }
}
