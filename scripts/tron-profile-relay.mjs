// The shaped loopback path the qualification profile puts one client on.
import { connect as connectTcp, createServer as createTcpServer } from "node:net";

export class RelayDirection {
  constructor(source, sink, clock, onBytes) {
    this.source = source;
    this.sink = sink;
    this.clock = clock;
    this.onBytes = onBytes;
    this.bitsPerSecond = 0;
    this.readyAt = 0;
    this.timer = null;
    this.held = false;
    this.sinkBlocked = false;
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
    this.timer.unref?.();
  }

  wake() {
    if (this.held || this.sinkBlocked) return;
    if (this.readyAt > this.clock()) { this.schedule(); return; }
    this.source.resume();
  }

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
      for (const upstream of this.halfOpenUpstreams) upstream.destroy();
      this.halfOpenUpstreams.clear();
    }
  }

  accept(phone) {
    phone.on("error", () => {});
    if (this.blackholed) {
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
