import { execFile } from "node:child_process";

/** The documented Tailscale install, then a CLI-only install on `PATH`. */
const TAILSCALE_CLI_CANDIDATES = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale"] as const;

const MAXIMUM_STATUS_BYTES = 1_024 * 1_024;
const MAXIMUM_COMMAND_OUTPUT_BYTES = 8 * 1_024 * 1_024;

/** Tailscale's own path kinds. `offline` is a peer Tailscale knows but cannot
 * reach; `unknown` is no answer at all (no CLI, a timeout, or an address that
 * is not a Tailscale peer, such as the loopback or LAN listener). */
export type PeerPath = "direct" | "relay" | "offline" | "unknown";

export interface BoundedCommandResult {
  /** Exit code, or null when the command never ran to completion. */
  code: number | null;
  timedOut: boolean;
  output: string;
  error?: string;
}

export type BoundedCommand = (tool: string, args: readonly string[], timeoutMs: number,
  options?: { env?: NodeJS.ProcessEnv; maxBuffer?: number }) => Promise<BoundedCommandResult>;

/** The fields of one `tailscale status --json` peer that Tron reads. */
export interface TailscalePeer {
  readonly TailscaleIPs?: unknown;
  readonly HostName?: unknown;
  readonly DNSName?: unknown;
  readonly Online?: unknown;
  readonly CurAddr?: unknown;
  readonly Relay?: unknown;
  readonly LastSeen?: unknown;
  readonly LastHandshake?: unknown;
  readonly RxBytes?: unknown;
  readonly TxBytes?: unknown;
}

export interface TailscaleStatus {
  /** The CLI candidate that answered. */
  readonly cli: string;
  /** `Self.TailscaleIPs`, as the status document reported them. */
  readonly self: readonly string[];
  readonly running: boolean;
  /** `Self.DNSName`, the MagicDNS name (with Tailscale's trailing dot). */
  readonly selfDNSName?: string;
  readonly peers: readonly TailscalePeer[];
}

export type TailscaleStatusRead =
  | { readonly ok: true; readonly status: TailscaleStatus }
  | { readonly ok: false; readonly failures: readonly string[]; readonly reason: "timeout" | "cli-failed" };

function isPeer(value: unknown): value is TailscalePeer {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** One `tailscale status --json` read through the documented candidates, used
 * by every Tailscale status reader. `ok: false` carries why each candidate failed, for
 * the diagnostic bundle's "no usable Tailscale CLI" line. Never rejects. */
export async function readTailscaleStatus(run: BoundedCommand, timeoutMs: number): Promise<TailscaleStatusRead> {
  const failures: string[] = [];
  let timedOut = false;
  for (const candidate of TAILSCALE_CLI_CANDIDATES) {
    let result: BoundedCommandResult;
    try {
      // The app binary otherwise enters GUI mode under launchd (no TERM).
      // The status owner supplies this to every runner, including diagnose.
      result = await run(candidate, ["status", "--json"], timeoutMs, {
        env: { ...process.env, TAILSCALE_BE_CLI: "1" }, maxBuffer: MAXIMUM_STATUS_BYTES,
      });
    } catch {
      failures.push(`${candidate}: command failed`);
      continue;
    }
    if (result.code !== 0 || result.timedOut) {
      timedOut ||= result.timedOut;
      failures.push(`${candidate}: ${result.timedOut ? "timed out" : result.error ?? `exit ${result.code ?? "none"}`}`);
      continue;
    }
    try {
      const parsed: unknown = JSON.parse(result.output);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
      const document = parsed as { Self?: unknown; Peer?: unknown; BackendState?: unknown };
      const selfDocument = document.Self !== null && typeof document.Self === "object" && !Array.isArray(document.Self)
        ? document.Self as { TailscaleIPs?: unknown; DNSName?: unknown; Online?: unknown }
        : undefined;
      const selfValue = selfDocument?.TailscaleIPs;
      const selfDNSName = typeof selfDocument?.DNSName === "string" && selfDocument.DNSName.length > 0 ? selfDocument.DNSName : undefined;
      const peerValue = document.Peer;
      return {
        ok: true,
        status: {
          cli: candidate,
          running: document.BackendState === "Running" && selfDocument?.Online === true,
          self: Array.isArray(selfValue) ? selfValue.filter((address): address is string => typeof address === "string") : [],
          ...(selfDNSName ? { selfDNSName } : {}),
          peers: peerValue !== null && typeof peerValue === "object" && !Array.isArray(peerValue)
            ? Object.values(peerValue as Record<string, unknown>).filter(isPeer)
            : [],
        },
      };
    } catch {
      failures.push(`${candidate}: unreadable status document`);
    }
  }
  return { ok: false, failures, reason: timedOut ? "timeout" : "cli-failed" };
}

/** One peer's path, shared by the transport's silence records and the
 * diagnostic bundle so both describe the same peer the same way. `offline`
 * outranks a remembered address: a peer Tailscale cannot reach uses no path.
 * `peerRelay` names the relay actually carrying the path, or is empty when
 * there is no relay (direct, offline or unknown). */
export function classifyPeer(peer: TailscalePeer | undefined): { peerPath: PeerPath; peerRelay: string } {
  if (peer === undefined) return { peerPath: "unknown", peerRelay: "" };
  if (peer.Online === false) return { peerPath: "offline", peerRelay: "" };
  if (peer.Online !== true) return { peerPath: "unknown", peerRelay: "" };
  if (typeof peer.CurAddr === "string" && peer.CurAddr.length > 0) return { peerPath: "direct", peerRelay: "" };
  const relay = typeof peer.Relay === "string" ? peer.Relay : "";
  return relay.length > 0 ? { peerPath: "relay", peerRelay: relay } : { peerPath: "unknown", peerRelay: "" };
}

export const runBoundedCommand: BoundedCommand = (tool, args, timeoutMs, options) => {
  return new Promise((resolve) => {
    execFile(tool, [...args], { timeout: timeoutMs, killSignal: "SIGKILL",
      maxBuffer: MAXIMUM_COMMAND_OUTPUT_BYTES, ...options, encoding: "utf8" }, (error, stdout) => {
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
