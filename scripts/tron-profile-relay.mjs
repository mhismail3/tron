// The shaped loopback path the qualification profile puts one client on.
//
// A phone socket accepted here is forwarded to the fixture Gateway byte for
// byte, so the profile shapes the real TCP stream rather than WebSocket frames:
// a rate budget fills the Gateway's own socket buffers (its outbound capacity
// policy then decides), and a blackhole makes an established socket go silent
// without closing it. The bytes counted here are the ones the link carried.
//
// The module is separate from the driver so the shaping can be driven directly:
// a stream paired with a sink that never drains must pause the stream, not
// buffer the sender's bytes in this process.

import { connect as connectTcp, createServer as createTcpServer } from "node:net";

/**
 * One direction of a relayed path. Raw TCP bytes read from `source` are written
 * to `sink` and charged against `bitsPerSecond` (0 = unshaped); the source is
 * paused with real TCP backpressure whenever the sink refuses a write or the
 * rate budget is spent, and is resumed only on the sink's own `drain`. A hold
 * forwards nothing in this direction: a chunk already read waits until the path
 * returns, so a held direction never leaks bytes past the blackhole.
 */
export class RelayDirection {
  constructor(source, sink, clock, onBytes) {
    this.source = source;
    this.sink = sink;
    this.clock = clock;
    // Called with the bytes of every forwarded chunk.
    this.onBytes = onBytes;
    this.bitsPerSecond = 0;
    this.readyAt = 0;
    this.timer = null;
    this.held = false;
    // Set when the sink refused a write and cleared on `drain`. The sink's own
    // buffer is full, so the source stays paused until the sink says otherwise;
    // a timer cannot stand in for that signal.
    this.sinkBlocked = false;
    // Chunks read before the path was held, written in order on release.
    this.pending = [];
    source.on("data", (chunk) => this.data(chunk));
    sink.on("drain", () => { this.sinkBlocked = false; this.wake(); });
  }

  cap(bitsPerSecond) {
    this.bitsPerSecond = bitsPerSecond;
    this.readyAt = this.clock();
  }

  data(chunk) {
    if (this.held) { this.pending.push(chunk); return; }
    this.forward(chunk);
  }

  forward(chunk) {
    const accepted = this.sink.write(chunk);
    const nowMs = this.clock();
    if (this.bitsPerSecond > 0) {
      this.readyAt = Math.max(this.readyAt, nowMs) + (chunk.length * 8000) / this.bitsPerSecond;
    } else {
      this.readyAt = nowMs;
    }
    this.onBytes(chunk.length);
    if (!accepted) this.sinkBlocked = true;
    if (this.sinkBlocked || this.readyAt > nowMs) this.waitForReady();
  }

  waitForReady() {
    this.source.pause();
    this.schedule();
  }

  schedule() {
    if (this.timer !== null || this.sinkBlocked) return;
    this.timer = setTimeout(() => { this.timer = null; this.wake(); }, Math.max(0, this.readyAt - this.clock()));
    // A shaping timer is not work: it must never keep the driver alive.
    this.timer.unref?.();
  }

  wake() {
    if (this.held || this.sinkBlocked) return;
    if (this.readyAt > this.clock()) { this.schedule(); return; }
    this.source.resume();
  }

  /** Stop forwarding: the path is gone in this direction. */
  hold() {
    this.held = true;
    if (this.timer !== null) { clearTimeout(this.timer); this.timer = null; }
    this.source.pause();
    this.readyAt = this.clock();
  }

  release() {
    this.held = false;
    this.readyAt = this.clock();
    const pending = this.pending;
    this.pending = [];
    for (const chunk of pending) this.forward(chunk);
    this.wake();
  }

  close() {
    if (this.timer !== null) { clearTimeout(this.timer); this.timer = null; }
  }
}

/**
 * The phone's path, shaped where the link really is: a loopback TCP relay that
 * forwards the client's byte stream to the Gateway under a per-direction rate
 * budget. Shaping raw bytes (rather than WebSocket frames) is what makes the
 * cap real — the Gateway's own socket buffers are the ones that fill, so its
 * outbound queue grows and its capacity policy is exercised — and it counts
 * what the link carried instead of what a decompressed frame said.
 *
 * A blackhole stops the relay forwarding and swallows new connections without
 * answering them: an established socket goes silent in both directions (the
 * Gateway sees silence, not a close) and an attempt made during the outage
 * hangs until the phone's own transport-open deadline gives up. Held
 * connections are deliberately never forwarded when the path returns. That is a
 * pessimistic model, not the phone's behaviour: an attempt still inside its
 * transport-open deadline has not been abandoned, and real TCP would retransmit
 * and connect within a second or two of the path returning. The model is kept
 * because it measures the worst case the case is about (the recovery of an
 * attempt that has to time out first), and it inflates the blackhole's recovery
 * baseline by the rest of that attempt's deadline.
 */
export class PathRelay {
  constructor(gatewayPort, clock) {
    this.gatewayPort = gatewayPort;
    this.clock = clock;
    this.port = null;
    this.blackholed = false;
    this.bitsPerSecond = 0;
    this.upBytes = 0;
    this.downBytes = 0;
    this.links = new Set();
    this.heldSockets = new Set();
    this.halfOpenUpstreams = new Set();
    this.server = createTcpServer((socket) => this.accept(socket));
  }

  async listen() {
    await new Promise((resolveListen, rejectListen) => {
      this.server.once("error", rejectListen);
      this.server.listen(0, "127.0.0.1", () => {
        this.port = this.server.address().port;
        resolveListen();
      });
    });
  }

  /** Apply one rate budget to every direction of the path, including links that
   * open while it is set (a reconnect during the capped leg is still capped). */
  cap(bitsPerSecond) {
    this.bitsPerSecond = bitsPerSecond;
    for (const link of this.links) { link.toGateway.cap(bitsPerSecond); link.toPhone.cap(bitsPerSecond); }
  }

  blackhole(on) {
    this.blackholed = on;
    for (const link of this.links) {
      if (on) { link.toGateway.hold(); link.toPhone.hold(); }
      else { link.toGateway.release(); link.toPhone.release(); }
    }
    if (!on) {
      // The phone abandoned these sockets while the path was gone; a returned
      // path does not resurrect them. The Gateway's half-open hold is over.
      for (const upstream of this.halfOpenUpstreams) upstream.destroy();
      this.halfOpenUpstreams.clear();
    }
  }

  accept(phone) {
    phone.on("error", () => {});
    if (this.blackholed) {
      // Held without an answer, as a dropping path holds a SYN: the phone's
      // TCP connection exists here and nothing ever comes back on it.
      this.heldSockets.add(phone);
      phone.on("close", () => this.heldSockets.delete(phone));
      return;
    }
    const gateway = connectTcp({ host: "127.0.0.1", port: this.gatewayPort });
    const link = { phone, gateway };
    const startForwarding = () => {
      link.toGateway = new RelayDirection(phone, gateway, this.clock, (bytes) => { this.upBytes += bytes; });
      link.toPhone = new RelayDirection(gateway, phone, this.clock, (bytes) => { this.downBytes += bytes; });
      link.toGateway.cap(this.bitsPerSecond);
      link.toPhone.cap(this.bitsPerSecond);
      if (this.blackholed) { link.toGateway.hold(); link.toPhone.hold(); }
      this.links.add(link);
      phone.resume();
    };
    gateway.on("connect", startForwarding);
    gateway.on("error", () => { link.toGateway?.close(); link.toPhone?.close(); this.links.delete(link); phone.destroy(); });
    gateway.on("close", () => {
      link.toGateway?.close();
      link.toPhone?.close();
      this.links.delete(link);
      phone.destroy();
    });
    phone.on("close", () => {
      // A phone that gives up on a frozen path says nothing to the Gateway: the
      // socket stays half-open until the Gateway's own heartbeat gives up,
      // which is what counts against its per-device socket cap.
      if (this.blackholed) { this.halfOpenUpstreams.add(gateway); return; }
      link.toGateway?.close();
      link.toPhone?.close();
      this.links.delete(link);
      gateway.destroy();
    });
    return link;
  }

  close() {
    for (const link of this.links) {
      link.toGateway?.close();
      link.toPhone?.close();
      link.gateway.destroy();
      link.phone.destroy();
    }
    this.links.clear();
    for (const socket of this.heldSockets) socket.destroy();
    this.heldSockets.clear();
    for (const upstream of this.halfOpenUpstreams) upstream.destroy();
    this.halfOpenUpstreams.clear();
    this.server.close();
  }
}
