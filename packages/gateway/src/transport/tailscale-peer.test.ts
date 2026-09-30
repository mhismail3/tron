import { afterEach, describe, expect, it, vi } from "vitest";
import {
  TAILSCALE_CLI_CANDIDATES, TAILSCALE_LOOKUP_TIMEOUT_MS, TailscalePeerPaths,
  type TailscaleStatusCommand, type TailscaleStatusResult,
} from "./tailscale-peer.js";

// Failure modes this file exists to catch, before any code above:
// 1. A peer Tailscale reports as direct is read as relay or unknown (the join
//    between a socket's remote address and the peer's Tailscale address).
// 2. A peer that is offline is given a path instead of `offline`.
// 3. A missing, slow or failing CLI is read as a path instead of `unknown`.
// 4. A silent socket whose address is not a Tailscale peer (loopback or LAN) is
//    given a path instead of `unknown`, or spawns the CLI for an address that
//    cannot appear in `status` at all.
// 5. A burst of silent sockets in one window spawns one CLI run per socket, and
//    a failed read is retried per socket instead of being reused.
// 6. An IPv4-mapped IPv6 remote address does not match the peer's Tailscale
//    IPv4 address.
// 7. A malformed status document, or a first candidate that fails, is not
//    retried on the next candidate.
// 8. A CLI that never settles (a child that ignores SIGTERM, or a grandchild
//    holding the pipe) leaves the read in flight forever and suppresses every
//    later silence record.
// 9. A null value where a peer is expected rejects the whole lookup.
// 10. A direct or offline peer reports a relay it is not using.

const STATUS = JSON.stringify({
  Self: { TailscaleIPs: ["100.64.0.1", "fd7a:115c:a1e0::1"] },
  Peer: {
    "node-direct": { TailscaleIPs: ["100.64.0.23"], CurAddr: "192.168.4.23:41641", Relay: "sfo", Online: true },
    "node-relayed": { TailscaleIPs: ["100.64.0.9"], Relay: "sea", Online: true },
    "node-offline": { TailscaleIPs: ["100.64.0.77"], Relay: "sfo", Online: false },
  },
});

const OK: TailscaleStatusResult = { code: 0, timedOut: false, output: STATUS };
const MISSING: TailscaleStatusResult = { code: 127, timedOut: false, output: "", error: "spawn ENOENT" };
const SLOW: TailscaleStatusResult = { code: null, timedOut: true, output: "" };

afterEach(() => {
  vi.useRealTimers();
});

function ok(): TailscaleStatusCommand {
  return vi.fn(async (): Promise<TailscaleStatusResult> => OK);
}

describe("Tailscale peer path lookup", () => {
  it("reads a current direct address as direct and a relay-only peer as relay", async () => {
    const paths = new TailscalePeerPaths(ok(), () => 0);
    // Only a relay path names a relay region: a direct peer is not using one.
    expect(await paths.lookup("100.64.0.23")).toEqual({ peerPath: "direct", peerRelay: "" });
    expect(await paths.lookup("100.64.0.9")).toEqual({ peerPath: "relay", peerRelay: "sea" });
  });

  it("matches an IPv4-mapped remote address to the peer's Tailscale IPv4", async () => {
    const paths = new TailscalePeerPaths(ok(), () => 0);
    expect(await paths.lookup("::ffff:100.64.0.23")).toEqual({ peerPath: "direct", peerRelay: "" });
  });

  it("reads a known but offline peer as offline", async () => {
    const paths = new TailscalePeerPaths(ok(), () => 0);
    expect(await paths.lookup("100.64.0.77")).toEqual({ peerPath: "offline", peerRelay: "" });
  });

  it.each([undefined, null, "false", 0])("keeps a peer with an unknown Online value unknown (%s)", async (online) => {
    const status = JSON.stringify({ Peer: { peer: { TailscaleIPs: ["100.64.0.88"], Online: online } } });
    const run = vi.fn(async (): Promise<TailscaleStatusResult> => ({ code: 0, timedOut: false, output: status }));
    expect(await new TailscalePeerPaths(run, () => 0).lookup("100.64.0.88"))
      .toEqual({ peerPath: "unknown", peerRelay: "" });
  });

  it("reads loopback and LAN addresses, which are not Tailscale peers, as unknown without a CLI run", async () => {
    const run = ok();
    const paths = new TailscalePeerPaths(run, () => 0);
    expect(await paths.lookup("127.0.0.1")).toEqual({ peerPath: "unknown", peerRelay: "" });
    expect(await paths.lookup("192.168.4.23")).toEqual({ peerPath: "unknown", peerRelay: "" });
    expect(run).not.toHaveBeenCalled();
  });

  it("reads a null peer value as no peer instead of rejecting the lookup", async () => {
    const nullPeer = JSON.stringify({ Peer: { "node-broken": null, "node-direct": { TailscaleIPs: ["100.64.0.23"], CurAddr: "192.168.4.23:41641", Online: true } } });
    const paths = new TailscalePeerPaths(vi.fn(async (): Promise<TailscaleStatusResult> => ({ code: 0, timedOut: false, output: nullPeer })), () => 0);
    expect(await paths.lookup("100.64.0.23")).toEqual({ peerPath: "direct", peerRelay: "" });
    expect(await paths.lookup("100.64.0.88")).toEqual({ peerPath: "unknown", peerRelay: "" });
  });

  it("reads a missing CLI, a timeout and a malformed document as unknown", async () => {
    const malformed = vi.fn(async (): Promise<TailscaleStatusResult> => ({ code: 0, timedOut: false, output: "not json" }));
    expect(await new TailscalePeerPaths(vi.fn(async () => MISSING), () => 0).lookup("100.64.0.23")).toEqual({ peerPath: "unknown", peerRelay: "" });
    expect(await new TailscalePeerPaths(vi.fn(async () => SLOW), () => 0).lookup("100.64.0.23")).toEqual({ peerPath: "unknown", peerRelay: "" });
    expect(await new TailscalePeerPaths(malformed, () => 0).lookup("100.64.0.23")).toEqual({ peerPath: "unknown", peerRelay: "" });
    // Every documented candidate is tried before giving up.
    expect(malformed).toHaveBeenCalledTimes(TAILSCALE_CLI_CANDIDATES.length);
  });

  it("falls through a failing candidate to a working one", async () => {
    const run = vi.fn(async (tool: string): Promise<TailscaleStatusResult> => tool === TAILSCALE_CLI_CANDIDATES[0] ? MISSING : OK);
    const paths = new TailscalePeerPaths(run, () => 0);
    expect(await paths.lookup("100.64.0.23")).toEqual({ peerPath: "direct", peerRelay: "" });
    expect(run).toHaveBeenCalledTimes(2);
  });

  it("abandons a read the CLI never settles and reads again for the next socket", async () => {
    vi.useFakeTimers();
    const run = vi.fn((): Promise<TailscaleStatusResult> => new Promise(() => {}));
    let now = 0;
    const paths = new TailscalePeerPaths(run, () => now);
    const first = paths.lookup("100.64.0.23");
    await vi.advanceTimersByTimeAsync(TAILSCALE_LOOKUP_TIMEOUT_MS);
    expect(await first).toEqual({ peerPath: "unknown", peerRelay: "" });
    // The hung read is not left in flight: the next socket reads on its own
    // once the reuse window has passed.
    now += 20_000;
    const second = paths.lookup("100.64.0.9");
    await vi.advanceTimersByTimeAsync(TAILSCALE_LOOKUP_TIMEOUT_MS);
    expect(await second).toEqual({ peerPath: "unknown", peerRelay: "" });
    expect(run).toHaveBeenCalledTimes(2);
  });

  it("shares one read between concurrent and later lookups in the reuse window", async () => {
    let release!: (result: TailscaleStatusResult) => void;
    const gate = new Promise<TailscaleStatusResult>((resolve) => { release = resolve; });
    const run = vi.fn((): Promise<TailscaleStatusResult> => gate);
    let now = 1_000;
    const paths = new TailscalePeerPaths(run, () => now);
    const both = Promise.all([paths.lookup("100.64.0.23"), paths.lookup("100.64.0.9")]);
    release(OK);
    expect(await both).toEqual([
      { peerPath: "direct", peerRelay: "" },
      { peerPath: "relay", peerRelay: "sea" },
    ]);
    now += 9_000;
    expect(await paths.lookup("100.64.0.23")).toEqual({ peerPath: "direct", peerRelay: "" });
    expect(run).toHaveBeenCalledTimes(1);
    // Past the reuse window the answer is read again.
    now += 2_000;
    await paths.lookup("100.64.0.23");
    expect(run).toHaveBeenCalledTimes(2);
  });

  it("reuses a failed read so a missing CLI cannot spawn one process per socket", async () => {
    const run = vi.fn(async (): Promise<TailscaleStatusResult> => MISSING);
    const paths = new TailscalePeerPaths(run, () => 0);
    expect(await paths.lookup("100.64.0.23")).toEqual({ peerPath: "unknown", peerRelay: "" });
    const afterFirst = run.mock.calls.length;
    expect(await paths.lookup("100.64.0.9")).toEqual({ peerPath: "unknown", peerRelay: "" });
    expect(run.mock.calls.length).toBe(afterFirst);
  });
});
