#!/usr/bin/env node
// Isolated integration fixture only. No production module imports this proxy.
// The caller owns the loopback Gateway and supplies an ephemeral control token.
import { createServer, Server, request as upstreamRequest } from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createRequire } from "node:module";
import { writeFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
const { WebSocket, WebSocketServer } = createRequire(new URL("../packages/gateway/package.json", import.meta.url))("ws");
const maximumBytes = 1_048_576;
const maximumFrames = 16;

// The exported unit-fixture API requires a live Server owned by this process,
// not a caller-supplied port. External Gateways enter only through CLI proof.
export async function startFaultProxyForServer(upstream, { token }) {
  if (!(upstream instanceof Server)) throw new Error("Fixture must own its upstream Server");
  const address = upstream.address();
  if (!upstream.listening || !address || typeof address === "string" || address.address !== "127.0.0.1") throw new Error("Fixture upstream is not bound to loopback");
  const verifyTarget = async () => {
    if (!upstream.listening || upstream.address()?.port !== address.port) throw new Error("Fixture upstream retired");
  };
  return startFaultProxy({ targetPort: address.port, token, verifyTarget });
}

async function startFaultProxy({ targetPort, token, verifyTarget, restartGateway }) {
  if (!Number.isInteger(targetPort) || targetPort < 1024 || targetPort > 65535 || typeof token !== "string" || token.length < 32) {
    throw new Error("Fault proxy requires an owned loopback target and control token");
  }
  await verifyTarget();
  let verifyingConnections = 0;
  const checkTarget = async () => {
    if (verifyingConnections >= 12) throw new Error("Fixture verification capacity reached");
    verifyingConnections++;
    try { await verifyTarget(); } finally { verifyingConnections--; }
  };
  const bridges = new Set();
  const sockets = new Set();
  const waiters = new Set();
  let policy = { mode: "pass" };
  let intercepted = false;
  let closing = false;
  // One fixture-wide FIFO carries both parsed HTTP streams and WebSocket
  // messages/control frames. This is an application-payload schedule, not a
  // claim about OS/TCP or compressed WebSocket wire-byte accounting.
  let shaper;
  let scheduleTail = Promise.resolve();
  const proxyStartedAt = process.hrtime.bigint();
  const elapsedMilliseconds = () => Math.round(Number(process.hrtime.bigint() - proxyStartedAt) / 1_000_000);
  const linkStats = {
    forwardedWebSocketPings: 0, forwardedWebSocketPongs: 0, uploadBodyBytes: 0,
    uploadBodyTransfers: [], clientHeartbeatTimeline: [],
    scheduledBytes: 0, scheduledHTTPBytes: 0, scheduledWebSocketBytes: 0,
    queuedPayloadBytes: 0, queueHighWaterBytes: 0,
    scheduleOverflows: 0, dispatchedRPCs: 0, settledRPCs: 0,
    originalAuthority: null, heartbeatRoundTripMilliseconds: [],
    logsExportRequestBytes: null, logsExportResponseBytes: null,
  };
  const logsExportRequestIDs = new Set();
  const outstandingClientPings = [];
  let clientPingSequence = 0;
  let heldHTTP = false;
  let releaseHTTP;
  let httpHoldTimer;
  let httpHeldWaiter;
  const schedule = (kind, bytes, forward) => {
    if (!shaper) return Promise.resolve().then(forward);
    const amount = Math.max(0, bytes);
    if (linkStats.queuedPayloadBytes + amount > shaper.maximumQueuedBytes) {
      linkStats.scheduleOverflows++;
      return Promise.reject(new Error("shared link schedule queue exceeded its bound"));
    }
    linkStats.queuedPayloadBytes += amount;
    linkStats.queueHighWaterBytes = Math.max(linkStats.queueHighWaterBytes, linkStats.queuedPayloadBytes);
    linkStats.scheduledBytes += amount;
    if (kind.startsWith("http-")) linkStats.scheduledHTTPBytes += amount;
    else if (kind.startsWith("websocket-")) linkStats.scheduledWebSocketBytes += amount;
    const job = scheduleTail.then(async () => {
      await new Promise(resolve => setTimeout(resolve, shaper.latencyMilliseconds + amount / shaper.rateBytesPerSecond * 1_000));
      await forward();
    }).finally(() => { linkStats.queuedPayloadBytes -= amount; });
    scheduleTail = job.catch(() => {});
    return job;
  };
  const answer = (response, status, value) => {
    if (response.destroyed) return;
    response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
    response.end(JSON.stringify(value));
  };
  const signalInterception = () => {
    intercepted = true;
    for (const response of waiters) answer(response, 200, { intercepted: true });
    waiters.clear();
  };
  // Once shaped, this proxy, not the client, paces how fast a request body is
  // read, so its listener bounds must measure client inactivity rather than
  // the fixture's own pacing: there is no whole-request deadline, and the
  // socket's idle bound (`server.timeout`) is disarmed while a body part waits
  // in the shared schedule and re-armed once it is forwarded. Headers are read
  // unpaced and keep their own deadline.
  const server = createServer({ requestTimeout: 0, headersTimeout: 5_000 }, async (request, response) => {
    if (request.url === "/_fixture/control") {
      if (request.headers["x-tron-fixture-token"] !== token) { answer(response, 403, {}); return; }
      try {
        let body = "";
        for await (const chunk of request) {
          body += chunk.toString();
          if (body.length > 1_024) throw new Error("control body too large");
        }
        const next = JSON.parse(body);
        if (next.mode === "await-intercepted") {
          if (intercepted) answer(response, 200, { intercepted: true });
          else if (waiters.size > 0) answer(response, 409, {});
          else {
            waiters.add(response);
            const timeout = setTimeout(() => { waiters.delete(response); answer(response, 408, {}); }, 5_000);
            timeout.unref();
            response.once("close", () => { clearTimeout(timeout); waiters.delete(response); });
          }
          return;
        }
        if (next.mode === "shape") {
          if (![12_288, 65_536].includes(next.rateBytesPerSecond) || next.latencyMilliseconds !== 30
              || next.maximumQueuedBytes !== 1_048_576 || shaper || policy.mode !== "pass") throw new Error("invalid shared-link schedule");
          shaper = { rateBytesPerSecond: next.rateBytesPerSecond, latencyMilliseconds: next.latencyMilliseconds, maximumQueuedBytes: next.maximumQueuedBytes };
          answer(response, 200, { mode: "shape", schedule: "shared-fifo" });
          return;
        }
        if (next.mode === "link-stats") {
          answer(response, 200, { ...linkStats, queuedPayloadBytes: linkStats.queuedPayloadBytes, schedule: shaper ? "shared-fifo" : "unshaped" });
          return;
        }
        if (next.mode === "unshape") {
          if (linkStats.queuedPayloadBytes !== 0 || policy.mode !== "pass") throw new Error("shared-link schedule is not idle");
          shaper = undefined;
          answer(response, 200, { mode: "unshaped" });
          return;
        }
        if (next.mode === "await-http-held") {
          if (heldHTTP) answer(response, 200, { held: true });
          else if (httpHeldWaiter) answer(response, 409, {});
          else {
            httpHeldWaiter = response;
            const timeout = setTimeout(() => { httpHeldWaiter = undefined; answer(response, 408, {}); }, 5_000);
            timeout.unref();
            response.once("close", () => { clearTimeout(timeout); if (httpHeldWaiter === response) httpHeldWaiter = undefined; });
          }
          return;
        }
        if (next.mode === "hold-http-response") {
          if (policy.mode !== "pass" || heldHTTP) throw new Error("HTTP response hold is already active");
          policy = { mode: "hold-http-response" };
          answer(response, 200, { mode: policy.mode });
          return;
        }
        if (next.mode === "close") {
          if (![1000, 1001, 1008, 1012, 1013].includes(next.code)) throw new Error("invalid close code");
          for (const bridge of bridges) bridge.close(next.code);
          answer(response, 200, { mode: "close" });
          return;
        }
        if (next.mode === "inject-frame") {
          // Sends one app-bound event of an exact byte size on the newest
          // bridge, so the app's decoded-size ceiling can be exercised with
          // (compressed) frames just under and over it.
          if (!Number.isSafeInteger(next.bytes) || next.bytes < 64 || next.bytes > 2 * maximumBytes) throw new Error("invalid frame size");
          const bridge = [...bridges].at(-1);
          if (!bridge?.inject(next.bytes)) throw new Error("no open bridge");
          answer(response, 200, { mode: next.mode, bytes: next.bytes });
          return;
        }
        if (next.mode === "restart-gateway") {
          if (!restartGateway) throw new Error("private Gateway restart is unavailable in this fixture");
          for (const bridge of [...bridges]) bridge.terminate();
          const pid = await restartGateway();
          answer(response, 200, { mode: next.mode, pid });
          return;
        }
        if (!["pass", "blackhole", "hold-hello", "hold-open", "hold-sync", "hold-http-response", "drop-prompt-response", "reject-upgrade"].includes(next.mode)) throw new Error("unknown fault");
        if (next.http !== undefined && (next.mode !== "blackhole" || typeof next.http !== "boolean")) throw new Error("invalid http blackhole");
        if (next.mode === "reject-upgrade" && ![401, 403, 503].includes(next.status)) throw new Error("invalid rejection status");
        if (next.mode === "drop-prompt-response" && (typeof next.commandId !== "string" || !/^[A-Za-z0-9._:-]{8,160}$/.test(next.commandId))) throw new Error("invalid command identity");
        if (intercepted && next.mode !== "pass") throw new Error("reset the owned fault before arming another");
        policy = { mode: next.mode, ...(next.commandId ? { commandId: next.commandId } : {}),
          ...(next.mode === "reject-upgrade" ? { status: next.status } : {}),
          // A blackhole that covers plain HTTP as well as WebSocket frames lets
          // a case prove a route came over the other lane: the proxied leg
          // cannot answer it at all, so a success names the route. Off unless
          // asked, because the other legs keep reading their fixture through
          // this proxy while a socket is blackholed.
          ...(next.http === true ? { http: true } : {}) };
        if (next.mode === "pass") {
          intercepted = false;
          for (const bridge of bridges) bridge.release();
          const resume = releaseHTTP;
          releaseHTTP = undefined;
          clearTimeout(httpHoldTimer);
          httpHoldTimer = undefined;
          resume?.();
        }
        answer(response, 200, { mode: policy.mode });
      } catch { answer(response, 400, { error: "invalid fixture control" }); }
      return;
    }
    // Pairing/health/assets use the exact same owned upstream, never a target
    // URL supplied by the HTTP client. The fixture exposes no general proxy.
    if (policy.mode === "blackhole" && policy.http) { request.destroy(); return; }
    try { await checkTarget(); } catch { answer(response, 503, { error: "owned fixture unavailable" }); return; }
    if (closing || response.destroyed || request.aborted) return;
    const requestHeaderBytes = Buffer.byteLength(`${request.method} ${request.url} HTTP/${request.httpVersion}\r\n${request.rawHeaders.join("\r\n")}\r\n\r\n`);
    const authority = request.headers.host;
    if (authority && !linkStats.originalAuthority) linkStats.originalAuthority = authority;
    void schedule("http-request-headers", requestHeaderBytes, () => {
      const upstream = upstreamRequest({ host: "127.0.0.1", port: targetPort, method: request.method,
        path: request.url, headers: { ...request.headers, host: `127.0.0.1:${targetPort}` } }, incoming => {
        void (async () => {
          if (policy.mode === "hold-http-response") {
            heldHTTP = true;
            if (httpHeldWaiter) { answer(httpHeldWaiter, 200, { held: true }); httpHeldWaiter = undefined; }
            await new Promise(resolve => {
              releaseHTTP = resolve;
              httpHoldTimer = setTimeout(() => {
                policy = { mode: "pass" };
                const resume = releaseHTTP;
                releaseHTTP = undefined;
                resume?.();
              }, 5_000);
              httpHoldTimer.unref();
            });
            clearTimeout(httpHoldTimer);
            httpHoldTimer = undefined;
            heldHTTP = false;
          }
          const responseHeaderBytes = Buffer.byteLength(`HTTP/${incoming.httpVersion} ${incoming.statusCode} ${incoming.statusMessage ?? ""}\r\n${incoming.rawHeaders.join("\r\n")}\r\n\r\n`);
          await schedule("http-response-headers", responseHeaderBytes, () => response.writeHead(incoming.statusCode ?? 502, incoming.headers));
          for await (const chunk of incoming) {
            const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
            for (let offset = 0; offset < bytes.length; offset += 16_384) {
              const part = bytes.subarray(offset, Math.min(offset + 16_384, bytes.length));
              await schedule("http-response-body", part.length, () => response.write(part));
            }
          }
          response.end();
        })().catch(() => response.destroy());
        incoming.once("error", () => response.destroy());
      });
      upstream.once("error", () => response.destroy());
      request.once("aborted", () => upstream.destroy());
      response.once("close", () => upstream.destroy());
      void (async () => {
        const isUploadBody = request.url?.startsWith("/v1/uploads?") ?? false;
        const uploadTransfer = isUploadBody ? { startMs: null, endMs: null, bytes: 0 } : undefined;
        for await (const chunk of request) {
          const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          if (isUploadBody) {
            uploadTransfer.startMs ??= elapsedMilliseconds();
            uploadTransfer.bytes += bytes.length;
            linkStats.uploadBodyBytes += bytes.length;
          }
          for (let offset = 0; offset < bytes.length; offset += 16_384) {
            const part = bytes.subarray(offset, Math.min(offset + 16_384, bytes.length));
            request.socket.setTimeout(0);
            await schedule("http-request-body", part.length, () => upstream.write(part));
            request.socket.setTimeout(server.timeout);
          }
        }
        if (uploadTransfer?.startMs !== null && uploadTransfer?.startMs !== undefined) {
          uploadTransfer.endMs = elapsedMilliseconds();
          linkStats.uploadBodyTransfers.push(uploadTransfer);
          if (linkStats.uploadBodyTransfers.length > 8) linkStats.uploadBodyTransfers.shift();
        }
        upstream.end();
      })().catch(() => { upstream.destroy(); response.destroy(); });
    }).catch(() => { response.destroy(); });
  });
  server.timeout = 10_000;
  // Name the fixture's own idle retirement in proxy.log, which CI retains, so a
  // reset client is attributed in one step. The socket's armed bound tells a
  // keep-alive expiry (5 s) from a stalled client (10 s). A listener replaces
  // Node's implicit destroy, so it destroys the socket itself.
  server.on("timeout", socket => {
    console.log(JSON.stringify({ event: "proxy.client-idle-timeout", elapsedMs: elapsedMilliseconds(), idleTimeoutMs: socket.timeout, shaped: Boolean(shaper) }));
    socket.destroy();
  });
  server.on("connection", socket => {
    if (closing || sockets.size >= 12) { socket.destroy(); return; }
    sockets.add(socket); socket.once("close", () => sockets.delete(socket));
  });
  // The proxy terminates WebSocket on both legs. It accepts the app's
  // permessage-deflate offer and makes the same bare offer upstream only when
  // the app negotiated it, so the Gateway's connection.opened record shows
  // what the real app negotiated. maxPayload bounds inflated messages.
  const webSockets = new WebSocketServer({ noServer: true, maxPayload: maximumBytes, perMessageDeflate: true, autoPong: false });
  server.on("upgrade", async (request, socket, head) => {
    const retire = () => socket.destroy();
    const deadline = setTimeout(retire, 5_000);
    socket.once("end", retire); socket.once("error", retire);
    try { await checkTarget(); } catch { socket.destroy(); }
    finally { clearTimeout(deadline); socket.off("end", retire); socket.off("error", retire); }
    if (socket.destroyed || closing) return;
    if (policy.mode === "reject-upgrade") {
      socket.end(`HTTP/1.1 ${policy.status} Fixture Rejection\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`, () => socket.destroy());
      return;
    }
    if (closing || request.url !== "/v1/socket" || bridges.size >= 4) { socket.destroy(); return; }
    webSockets.handleUpgrade(request, socket, head, front => {
      const compressed = front.extensions === "permessage-deflate";
      console.log(JSON.stringify({ event: "proxy.bridge-opened", appOffer: request.headers["sec-websocket-extensions"] ?? null, appNegotiated: front.extensions || null }));
      const back = new WebSocket(`ws://127.0.0.1:${targetPort}/v1/socket`, {
        headers: request.headers.authorization ? { authorization: request.headers.authorization } : {},
        maxPayload: maximumBytes, perMessageDeflate: compressed ? { clientMaxWindowBits: false } : false, autoPong: false,
      });
      const pending = [];
      const heldFrames = [];
      let pendingBytes = 0, heldBytes = 0;
      let targetID;
      let holding = false;
      let retired = false;
      let closeDeadline;
      const terminate = () => {
        if (retired) return;
        retired = true;
        clearTimeout(closeDeadline);
        pending.length = 0; heldFrames.length = 0;
        pendingBytes = 0; heldBytes = 0;
        bridges.delete(bridge);
        front.terminate(); back.terminate();
      };
      const send = (socket, data, binary = false) => {
        if (socket.readyState !== WebSocket.OPEN || socket.bufferedAmount + data.length > maximumBytes) { terminate(); return; }
        socket.send(data, { binary }, error => { if (error) terminate(); });
      };
      const bridge = {
        terminate,
        close(code) {
          if (front.readyState !== WebSocket.OPEN || closeDeadline !== undefined) return;
          front.close(code);
          closeDeadline = setTimeout(terminate, 1_000);
          closeDeadline.unref();
        },
        inject(bytes) {
          if (front.readyState !== WebSocket.OPEN) return false;
          const empty = JSON.stringify({ type: "event", topic: "fixture.frame", payload: { pad: "" } });
          front.send(JSON.stringify({ type: "event", topic: "fixture.frame", payload: { pad: "x".repeat(bytes - empty.length) } }), error => { if (error) terminate(); });
          return true;
        },
        release() {
          holding = false;
          for (const [data, binary] of heldFrames) send(front, data, binary);
          heldFrames.length = 0; heldBytes = 0;
        },
      };
      bridges.add(bridge);
      front.on("error", terminate); back.on("error", terminate);
      front.on("close", terminate); back.on("close", terminate);
      back.on("open", () => {
        for (const [data, binary] of pending) send(back, data, binary);
        pending.length = 0; pendingBytes = 0;
      });
      front.on("message", (data, binary) => {
        if (policy.mode === "blackhole") { signalInterception(); return; }
        let frame;
        try {
          frame = JSON.parse(data.toString());
          if (frame.type === "request" && typeof frame.method === "string") linkStats.dispatchedRPCs++;
          if (frame.type === "request" && frame.method === "system.logs.export") {
            linkStats.logsExportRequestBytes = data.length;
            if (logsExportRequestIDs.size >= 16) logsExportRequestIDs.delete(logsExportRequestIDs.values().next().value);
            logsExportRequestIDs.add(frame.id);
          }
          if ((policy.mode === "hold-open" && frame.method === "session.open")
            || (policy.mode === "hold-sync" && frame.method === "session.sync")
            || (policy.mode === "drop-prompt-response" && frame.method === "session.prompt" && frame.params?.commandId === policy.commandId)) targetID = frame.id;
        } catch { terminate(); return; }
        const bytes = data.length + 2 + (data.length < 126 ? 0 : data.length <= 65_535 ? 2 : 8) + 4;
        void schedule("websocket-client-frame", bytes, () => {
          if (back.readyState === WebSocket.OPEN) send(back, data, binary);
          else if (pending.length < maximumFrames && pendingBytes + data.length <= maximumBytes) {
            pending.push([data, binary]); pendingBytes += data.length;
          } else terminate();
        }).catch(terminate);
      });
      back.on("message", (data, binary) => {
        if (front.readyState !== WebSocket.OPEN) return;
        if (policy.mode === "blackhole") { signalInterception(); return; }
        let frame;
        try { frame = JSON.parse(data.toString()); } catch { terminate(); return; }
        if (frame.type === "response") linkStats.settledRPCs++;
        if (frame.type === "response" && logsExportRequestIDs.delete(frame.id)) linkStats.logsExportResponseBytes = data.length;
        if (policy.mode === "drop-prompt-response" && frame.type === "response" && frame.id === targetID) {
          policy = { mode: "pass" };
          // This fault specifically loses an accepted result. A definitive
          // rejection must reach the test instead of masquerading as admission.
          if (frame.ok === true) { terminate(); return; }
        }
        if ((policy.mode === "hold-hello" && frame.type === "hello")
          || ((policy.mode === "hold-open" || policy.mode === "hold-sync") && frame.type === "response" && frame.id === targetID)) holding = true;
        if (holding) {
          if (heldFrames.length >= maximumFrames || heldBytes + data.length > maximumBytes) { terminate(); return; }
          heldFrames.push([data, binary]); heldBytes += data.length;
          signalInterception();
        } else void schedule("websocket-server-frame", data.length + 2 + (data.length < 126 ? 0 : data.length <= 65_535 ? 2 : 8), () => send(front, data, binary)).catch(terminate);
      });
      // Auto-pong is disabled at both ends: a blackhole must not fabricate
      // liveness. Other faults preserve ping/pong and ordered server data.
      for (const [source, destination, direction] of [[front, back, "client"], [back, front, "gateway"]]) {
        source.on("ping", data => {
          if (policy.mode === "blackhole") { signalInterception(); return; }
          const heartbeat = direction === "client" ? {
            payload: data.toString("hex"),
            timeline: {
              sequence: ++clientPingSequence,
              enqueuedMs: elapsedMilliseconds(),
              forwardedMs: null,
              gatewayPongMs: null,
              appPongForwardedMs: null,
            },
          } : undefined;
          if (heartbeat) {
            outstandingClientPings.push(heartbeat);
            linkStats.clientHeartbeatTimeline.push(heartbeat.timeline);
            if (linkStats.clientHeartbeatTimeline.length > 16) linkStats.clientHeartbeatTimeline.shift();
            if (outstandingClientPings.length > 16) outstandingClientPings.shift();
          }
          void schedule("websocket-ping", data.length + (direction === "client" ? 6 : 2), () => {
            if (destination.readyState === WebSocket.OPEN) {
              destination.ping(data);
              if (heartbeat) heartbeat.timeline.forwardedMs = elapsedMilliseconds();
              if (direction === "client") linkStats.forwardedWebSocketPings++;
            }
          }).catch(terminate);
        });
        source.on("pong", data => {
          if (policy.mode === "blackhole") { signalInterception(); return; }
          const heartbeat = direction === "gateway"
            ? outstandingClientPings.find(ping => ping.payload === data.toString("hex") && ping.timeline.gatewayPongMs === null)
            : undefined;
          if (heartbeat) {
            heartbeat.timeline.gatewayPongMs = elapsedMilliseconds();
            linkStats.heartbeatRoundTripMilliseconds.push(heartbeat.timeline.gatewayPongMs - heartbeat.timeline.enqueuedMs);
            if (linkStats.heartbeatRoundTripMilliseconds.length > 32) linkStats.heartbeatRoundTripMilliseconds.shift();
          }
          void schedule("websocket-pong", data.length + (direction === "gateway" ? 6 : 2), () => {
            if (destination.readyState === WebSocket.OPEN) {
              destination.pong(data);
              if (heartbeat) heartbeat.timeline.appPongForwardedMs = elapsedMilliseconds();
              if (direction === "gateway") linkStats.forwardedWebSocketPongs++;
              if (heartbeat) {
                const index = outstandingClientPings.indexOf(heartbeat);
                if (index >= 0) outstandingClientPings.splice(index, 1);
              }
            }
          }).catch(terminate);
        });
      }
    });
  });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  return {
    port: server.address().port,
    async close() {
      if (closing) return;
      closing = true;
      for (const response of waiters) response.destroy();
      waiters.clear();
      for (const bridge of [...bridges]) bridge.terminate();
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
      webSockets.close();
    },
  };
}

async function ownedGatewayVerifier(initialPid, port) {
  if (!Number.isSafeInteger(initialPid) || initialPid <= 1 || process.ppid <= 1) throw new Error("Fixture owner PID is required");
  const execute = promisify(execFile);
  const entrypoint = realpathSync(fileURLToPath(new URL("../packages/gateway/dist/index.js", import.meta.url)));
  let pid = initialPid;
  let birth;
  let command;
  let checking;
  const inspect = async (target, field) => (await execute("/bin/ps", ["-p", String(target), "-o", `${field}=`], { timeout: 2_000, maxBuffer: 4_096 })).stdout.trim();
  const capture = async (target, allowedParent) => {
    const nextCommand = await inspect(target, "command");
    const argument = nextCommand.split(/\s+/).at(-1) ?? "";
    if (realpathSync(argument) !== entrypoint || Number(await inspect(target, "ppid")) !== allowedParent) {
      throw new Error("Upstream is not an owned Gateway fixture process");
    }
    return { command: nextCommand, birth: await inspect(target, "lstart") };
  };
  const initial = await capture(pid, process.ppid);
  command = initial.command;
  birth = initial.birth;
  const verifyTarget = () => {
    checking ??= (async () => {
      if (await inspect(pid, "lstart") !== birth || await inspect(pid, "command") !== command) throw new Error("Gateway process ownership changed");
      const result = await execute(process.platform === "darwin" ? "/usr/sbin/lsof" : "lsof",
        ["-nP", "-a", "-p", String(pid), `-iTCP:${port}`, "-sTCP:LISTEN", "-Fpn"], { timeout: 2_000, maxBuffer: 4_096 });
      const fields = result.stdout.trim().split("\n");
      if (!fields.includes(`p${pid}`) || !fields.includes(`n127.0.0.1:${port}`)) throw new Error("Gateway does not own the fixture listener");
    })().finally(() => { checking = undefined; });
    return checking;
  };
  verifyTarget.adopt = async target => {
    const next = await capture(target, process.pid);
    pid = target;
    command = next.command;
    birth = next.birth;
  };
  verifyTarget.pid = () => pid;
  return verifyTarget;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const targetPort = Number(process.env.TRON_E2E_UPSTREAM_PORT);
  const verifyTarget = await ownedGatewayVerifier(Number(process.env.TRON_E2E_UPSTREAM_PID), targetPort);
  const entrypoint = realpathSync(process.env.TRON_E2E_GATEWAY_ENTRY);
  if (entrypoint !== realpathSync(fileURLToPath(new URL("../packages/gateway/dist/index.js", import.meta.url)))) throw new Error("Gateway restart entrypoint is not the repository fixture");
  const restartGateway = async () => {
    await verifyTarget();
    const oldPid = verifyTarget.pid();
    process.kill(oldPid, "SIGTERM");
    const stoppedAt = Date.now() + 5_000;
    while (Date.now() < stoppedAt) {
      try { process.kill(oldPid, 0); } catch { break; }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    try { process.kill(oldPid, 0); throw new Error("Private Gateway did not stop within its fixture deadline"); } catch (error) {
      if (error.message.includes("did not stop")) throw error;
    }
    const { spawn } = await import("node:child_process");
    const child = spawn(process.execPath, [entrypoint], {
      cwd: fileURLToPath(new URL("..", import.meta.url)),
      env: {
        PATH: process.env.PATH,
        HOME: process.env.TRON_E2E_GATEWAY_HOME,
        TRON_DATA_DIR: process.env.TRON_E2E_TRON_HOME,
        PI_CODING_AGENT_DIR: process.env.TRON_E2E_AGENT_DIR,
        PI_SUBAGENTS_TEMP_ROOT: `${process.env.TRON_E2E_GATEWAY_HOME}/internal/subagents`,
        TRON_MACHINE_GROUP_ID: "tron-ios-e2e",
        TRON_GATEWAY_HOST: "127.0.0.1",
        TRON_GATEWAY_PORT: String(targetPort),
        // A restarted fixture Gateway keeps the lane the caller asked for, or
        // the phone would re-learn an advertisement this run dials.
        ...(process.env.TRON_E2E_LAN_ENDPOINT ? { TRON_GATEWAY_LAN_ENDPOINT: process.env.TRON_E2E_LAN_ENDPOINT } : {}),
      },
      stdio: "ignore",
    });
    if (!child.pid) throw new Error("Private Gateway fixture failed to spawn");
    try {
      await writeFile(process.env.TRON_E2E_GATEWAY_PID_FILE, `${child.pid}\n`, { mode: 0o600 });
      await verifyTarget.adopt(child.pid);
    } catch (error) {
      child.kill("SIGTERM");
      throw error;
    }
    return child.pid;
  };
  const proxy = await startFaultProxy({ targetPort, token: process.env.TRON_E2E_PROXY_TOKEN, verifyTarget, restartGateway });
  await writeFile(process.env.TRON_E2E_PROXY_READY, `${JSON.stringify({ port: proxy.port, pid: process.pid })}\n`, { mode: 0o600 });
  const close = () => { void proxy.close().then(() => process.exit(0)); };
  process.once("SIGTERM", close); process.once("SIGINT", close);
}
