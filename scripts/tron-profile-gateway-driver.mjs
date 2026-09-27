#!/usr/bin/env node
// Workload and recording clients for scripts/tron-profile-gateway.
//
//   node scripts/tron-profile-gateway-driver.mjs seed CONFIG.json
//   node scripts/tron-profile-gateway-driver.mjs run CONFIG.json
//
// `seed` writes deterministic canonical Pi session JSONL into the isolated
// fixture before its Gateway starts. `run` pairs like the phone, connects the
// recording clients, drives one scenario for N iterations and writes per-window
// counts plus a per-frame timeline. The orchestrator owns metric naming,
// the fixture process, and the report; this file only measures.
//
// Phone fidelity (packages/ios-app): GatewayClient.establishConnection sends
// hello {protocolVersion, clientId, clientRole: "mobile"}; GatewayConnectionPolicy
// pings every 10 s with an 8 s pong deadline; URLSessionWebSocketTask offers
// `permessage-deflate` without parameters and answers server pings; the
// dashboard loads `session.list` (limit 500, scope user); a mounted chat runs
// SessionPresentationStore's session.open -> session.sync ->
// session.presentation.set(visible) and renews that lease every 15 s.

import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, createWriteStream } from "node:fs";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const CLIENT_PING_INTERVAL_MS = 10_000;
const CLIENT_PONG_DEADLINE_MS = 8_000;
const PRESENTATION_LEASE_RENEWAL_MS = 15_000;
const REQUEST_TIMEOUT_MS = 30_000;
const PROTOCOL_VERSION = 5;

const [command, configPath] = process.argv.slice(2);
if (!["seed", "run"].includes(command) || !configPath) {
  process.stderr.write("usage: tron-profile-gateway-driver.mjs seed|run CONFIG.json\n");
  process.exit(2);
}
const config = JSON.parse(readFileSync(configPath, "utf8"));
const gatewayRequire = createRequire(join(config.gatewayDir, "package.json"));
const started = performance.now();
const now = () => performance.now() - started;
const sleep = (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms));

function fail(message) {
  throw new Error(message);
}

async function withDeadline(promise, ms, what) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timed out after ${ms} ms: ${what}`)), ms); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

// Deterministic text for seeded history; independent of the faux model text.
function generator(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}
const WORDS = ["session", "gateway", "snapshot", "stream", "phone", "tool", "result", "render",
  "window", "bounded", "canonical", "reply", "profile", "measure", "energy", "timer"];
function prose(random, length) {
  let text = "";
  while (text.length < length) {
    const count = 8 + Math.floor(random() * 8);
    const words = Array.from({ length: count }, () => WORDS[Math.floor(random() * WORDS.length)]).join(" ");
    text += `${words[0].toUpperCase()}${words.slice(1)}. `;
  }
  return text.slice(0, length);
}

async function seed() {
  const agentModule = await import(pathToFileURL(join(config.gatewayDir,
    "node_modules/@earendil-works/pi-coding-agent/dist/index.js")).href);
  const { SessionManager } = agentModule;
  const cwd = resolve(config.workspace);
  // Same directory rule as RuntimeRegistry.sessionDirectoryFor.
  const sessionDir = join(config.agentDir, "sessions", `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`);
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
  const sessions = [];
  for (let index = 0; index < config.count; index += 1) {
    const random = generator(config.seed);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendModelChange("tron-profile", "profile-model");
    manager.appendThinkingLevelChange("low");
    let timestamp = 1_790_000_000_000;
    for (let turn = 0; turn < config.turns; turn += 1) {
      const callId = `seed_call_${String(turn).padStart(4, "0")}`;
      const assistant = (content, stopReason) => ({
        role: "assistant", content, api: "faux", provider: "tron-profile", model: "profile-model",
        usage, stopReason, timestamp: (timestamp += 1000),
      });
      manager.appendMessage({ role: "user", content: [{ type: "text", text: prose(random, config.userChars) }], timestamp: (timestamp += 1000) });
      manager.appendMessage(assistant([
        { type: "thinking", thinking: prose(random, config.thinkingChars) },
        { type: "text", text: prose(random, config.assistantChars) },
        { type: "toolCall", id: callId, name: "bash", arguments: { command: `printf seeded-${turn}` } },
      ], "toolUse"));
      manager.appendMessage({
        role: "toolResult", toolCallId: callId, toolName: "bash",
        content: [{ type: "text", text: prose(random, config.toolChars) }], isError: false, timestamp: (timestamp += 1000),
      });
      manager.appendMessage(assistant([{ type: "text", text: prose(random, config.assistantChars) }], "stop"));
    }
    sessions.push({ sessionId: manager.getSessionId(), path: manager.getSessionFile() });
  }
  writeFileSync(config.output, `${JSON.stringify({ sessions }, null, 2)}\n`);
}

function emptyWindow() {
  return {
    frames: 0, bytes: 0, largestFrame: 0, largestTopic: null, topics: {},
    outboundFrames: 0, outboundBytes: 0,
    pingsReceived: 0, pongsSent: 0, pingsSent: 0, pongsReceived: 0, pongDeadlineMisses: 0,
  };
}

class RecordingClient {
  constructor(name, token, timeline) {
    this.name = name;
    this.token = token;
    this.timeline = timeline;
    this.pending = new Map();
    this.listeners = new Set();
    this.window = null;
    this.label = "setup";
    this.lastFrameAt = 0;
    this.closedUnexpectedly = null;
  }

  async connect() {
    const WebSocket = gatewayRequire("ws");
    const socket = new WebSocket(`ws://127.0.0.1:${config.port}/v1/socket`, {
      headers: { Authorization: `Bearer ${this.token}` },
      // URLSessionWebSocketTask's offer is exactly `permessage-deflate`; this
      // option set makes ws send the same parameterless offer.
      perMessageDeflate: { clientMaxWindowBits: false },
      autoPong: false,
      handshakeTimeout: 15_000,
      maxPayload: 64 * 1024 * 1024,
    });
    this.socket = socket;
    socket.on("upgrade", (response) => {
      this.tcp = response.socket;
      // ws still holds the sent request here; record the exact offer.
      this.offeredExtensions = socket._req?.getHeader("sec-websocket-extensions") ?? null;
      this.negotiatedExtensions = response.headers["sec-websocket-extensions"] ?? "";
    });
    socket.on("ping", (data) => {
      // Answer immediately like URLSession; count both directions.
      this.note("in", "control:ping", data.length);
      socket.pong(data);
      if (this.window) this.window.pongsSent += 1;
      this.timeline.write({ t: now(), client: this.name, label: this.label, dir: "out", topic: "control:pong", bytes: data.length });
    });
    socket.on("pong", (data) => {
      this.awaitingPong = null;
      this.note("in", "control:pong", data.length);
    });
    socket.on("message", (data, isBinary) => this.onMessage(data, isBinary));
    socket.on("close", (code, reason) => {
      if (!this.closing) this.closedUnexpectedly = `closed ${code} ${reason.toString()}`;
      for (const { reject } of this.pending.values()) reject(new Error(`${this.name} socket closed (${code})`));
      this.pending.clear();
    });
    await withDeadline(new Promise((resolveOpen, rejectOpen) => {
      socket.once("open", resolveOpen);
      socket.once("error", rejectOpen);
      socket.once("unexpected-response", (_, response) => rejectOpen(new Error(`upgrade rejected with HTTP ${response.statusCode}`)));
    }), 15_000, `${this.name} WebSocket open`);
    if (this.offeredExtensions !== "permessage-deflate") {
      fail(`${this.name} offered ${JSON.stringify(this.offeredExtensions)}, not the phone's parameterless permessage-deflate`);
    }
    if (!this.tcp) fail(`${this.name}: the upgrade exposed no TCP socket to count wire bytes`);
    const hello = new Promise((resolveHello) => { this.helloWaiter = resolveHello; });
    this.send({ type: "hello", protocolVersion: PROTOCOL_VERSION, clientId: randomUUID(), clientRole: "mobile" });
    this.info = await withDeadline(hello, 15_000, `${this.name} hello`);
    if (this.info.protocolVersion !== PROTOCOL_VERSION) fail(`${this.name}: Gateway protocol ${this.info.protocolVersion} is not ${PROTOCOL_VERSION}`);
    this.pingTimer = setInterval(() => this.clientPing(), CLIENT_PING_INTERVAL_MS);
  }

  clientPing() {
    if (this.socket.readyState !== 1) return;
    // The phone would reconnect here; this recorder keeps measuring and the
    // orchestrator reports the miss (usually a stalled fixture on a busy host).
    if (this.awaitingPong && now() - this.awaitingPong > CLIENT_PONG_DEADLINE_MS && this.window) {
      this.window.pongDeadlineMisses += 1;
    }
    this.awaitingPong = now();
    this.socket.ping();
    if (this.window) this.window.pingsSent += 1;
    this.timeline.write({ t: now(), client: this.name, label: this.label, dir: "out", topic: "control:ping", bytes: 0 });
  }

  note(dir, topic, bytes) {
    this.timeline.write({ t: now(), client: this.name, label: this.label, dir, topic, bytes });
    if (!this.window) return;
    if (topic === "control:ping") this.window.pingsReceived += 1;
    if (topic === "control:pong") this.window.pongsReceived += 1;
  }

  send(frame) {
    const encoded = JSON.stringify(frame);
    const bytes = Buffer.byteLength(encoded);
    const topic = frame.type === "request" ? `request:${frame.method}` : frame.type;
    this.timeline.write({ t: now(), client: this.name, label: this.label, dir: "out", topic, bytes });
    if (this.window) { this.window.outboundFrames += 1; this.window.outboundBytes += bytes; }
    this.socket.send(encoded);
  }

  onMessage(data, isBinary) {
    const buffer = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data);
    const bytes = buffer.length;
    let frame;
    try { frame = JSON.parse(buffer.toString("utf8")); } catch { frame = { type: isBinary ? "binary" : "invalid" }; }
    let topic;
    if (frame.type === "event") topic = String(frame.topic);
    else if (frame.type === "response") topic = `response:${this.pending.get(frame.id)?.method ?? "unknown"}`;
    else topic = String(frame.type);
    this.lastFrameAt = now();
    this.timeline.write({ t: this.lastFrameAt, client: this.name, label: this.label, dir: "in", topic, bytes });
    if (this.window) {
      const window = this.window;
      window.frames += 1;
      window.bytes += bytes;
      if (bytes > window.largestFrame) { window.largestFrame = bytes; window.largestTopic = topic; }
      const entry = (window.topics[topic] ??= { frames: 0, bytes: 0, largest: 0 });
      entry.frames += 1;
      entry.bytes += bytes;
      entry.largest = Math.max(entry.largest, bytes);
    }
    if (topic === "session.diagnostic" || topic === "session.operationFailed") {
      // Runtime failure detail is the evidence for a rejected workload.
      process.stderr.write(`${this.name} ${this.label} ${topic}: ${JSON.stringify(frame.payload).slice(0, 2_000)}\n`);
    }
    if (frame.type === "hello" && this.helloWaiter) { this.helloWaiter(frame); this.helloWaiter = null; return; }
    if (frame.type === "response") {
      const waiter = this.pending.get(frame.id);
      if (!waiter) return;
      this.pending.delete(frame.id);
      if (frame.ok === false) waiter.reject(new Error(`${waiter.method} failed: ${JSON.stringify(frame.error)}`));
      else waiter.resolve(frame.result);
      return;
    }
    for (const listener of this.listeners) listener(frame, topic);
  }

  request(method, params = {}) {
    const id = randomUUID();
    const promise = new Promise((resolveRequest, rejectRequest) => {
      this.pending.set(id, { method, resolve: resolveRequest, reject: rejectRequest });
    });
    this.send({ type: "request", id, method, params });
    return withDeadline(promise, REQUEST_TIMEOUT_MS, `${this.name} ${method}`);
  }

  beginWindow(label) {
    this.label = label;
    this.window = emptyWindow();
    this.window.socketRead0 = this.tcp?.bytesRead ?? null;
    this.window.socketWritten0 = this.tcp?.bytesWritten ?? null;
  }

  endWindow() {
    const window = this.window;
    this.window = null;
    const read = this.tcp?.bytesRead ?? null;
    const written = this.tcp?.bytesWritten ?? null;
    window.socketBytesRead = read !== null && window.socketRead0 !== null ? read - window.socketRead0 : null;
    window.socketBytesWritten = written !== null && window.socketWritten0 !== null ? written - window.socketWritten0 : null;
    delete window.socketRead0;
    delete window.socketWritten0;
    this.label = "between";
    return window;
  }

  async close() {
    this.closing = true;
    clearInterval(this.pingTimer);
    if (this.socket && this.socket.readyState === 1) {
      this.socket.close(1000, "profile complete");
      await withDeadline(new Promise((resolveClose) => this.socket.once("close", resolveClose)), 3_000, `${this.name} close`)
        .catch(() => this.socket.terminate());
    }
  }
}

/** Mounted-chat presentation owner mirroring SessionPresentationStore. */
class MountedChat {
  constructor(client, sessionId) {
    this.client = client;
    this.sessionId = sessionId;
    this.revision = 0;
  }

  async open() {
    const opened = await this.client.request("session.open", { sessionId: this.sessionId });
    if (opened?.session?.sessionId !== this.sessionId) fail(`session.open returned ${opened?.session?.sessionId}`);
    this.token = opened.subscriptionToken;
    this.openSnapshot = opened.session;
    this.latest = opened.session;
    this.cursor = { generation: opened.session.runtimeGeneration, sequence: opened.session.eventSequence };
    this.sequenceGaps = 0;
    // Cursor rule of the phone and terminal chat: a snapshot installs the
    // cursor; every other sequenced event must be exactly the next one. A gap
    // would make the phone resynchronize, which this profile must not hide.
    this.listener = (frame) => {
      const payload = frame.payload;
      if (frame.type !== "event" || !payload || typeof payload !== "object") return;
      if ((payload.sessionId ?? frame.sessionId) !== this.sessionId) return;
      if (frame.topic === "session.snapshot") {
        if (payload.runtimeGeneration === this.cursor.generation && payload.eventSequence <= this.cursor.sequence) return;
        this.latest = payload;
        this.cursor = { generation: payload.runtimeGeneration, sequence: payload.eventSequence };
        return;
      }
      if (typeof payload.eventSequence !== "number" || typeof payload.runtimeGeneration !== "string") return;
      if (payload.runtimeGeneration !== this.cursor.generation || payload.eventSequence !== this.cursor.sequence + 1) {
        this.sequenceGaps += 1;
      }
      this.cursor = { generation: payload.runtimeGeneration, sequence: payload.eventSequence };
    };
    this.client.listeners.add(this.listener);
    const synced = await this.client.request("session.sync", { sessionId: this.sessionId, syncToken: opened.syncToken });
    if (synced?.synchronized !== true) fail("session.sync did not synchronize");
    await this.setVisible(true);
    this.renewal = setInterval(() => { void this.setVisible(true).catch((error) => { this.renewalError = error; }); }, PRESENTATION_LEASE_RENEWAL_MS);
    return opened;
  }

  setVisible(visible) {
    this.revision += 1;
    return this.client.request("session.presentation.set", {
      sessionId: this.sessionId, subscriptionToken: this.token, revision: this.revision, visible,
    });
  }

  /** Canonical outcome of the latest installed snapshot, for workload checks. */
  outcome() {
    const transcript = this.latest?.transcript ?? [];
    let lastUser = -1;
    transcript.forEach((item, index) => { if (item.kind === "message" && item.role === "user") lastUser = index; });
    const since = transcript.slice(lastUser + 1);
    const assistants = since.filter((item) => item.kind === "message" && item.role === "assistant");
    const finalText = (assistants.at(-1)?.content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("");
    return {
      phase: this.latest?.phase ?? null,
      transcriptTotal: this.latest?.transcriptTotal ?? null,
      promptFound: lastUser >= 0,
      assistantMessages: assistants.length,
      toolResults: since.filter((item) => item.kind === "message" && item.role === "toolResult").length,
      finalTextChars: finalText.length,
      sequenceGaps: this.sequenceGaps,
    };
  }

  async close() {
    clearInterval(this.renewal);
    this.client.listeners.delete(this.listener);
    if (this.renewalError) throw this.renewalError;
    await this.setVisible(false);
    await this.client.request("session.close", { sessionId: this.sessionId, subscriptionToken: this.token });
  }
}

function readEnrollmentCode() {
  try {
    return JSON.parse(readFileSync(join(config.tronHome, "gateway", "enrollment.json"), "utf8")).code ?? null;
  } catch {
    return null; // Absent or mid-replacement: the Gateway republishes it.
  }
}

async function pair(deviceName, previousCode) {
  // Pairing consumes the one-use invitation; the Gateway regenerates it
  // asynchronously, so wait for a new code rather than reusing the old one.
  const deadline = now() + 10_000;
  let code = readEnrollmentCode();
  while (code === null || code === previousCode) {
    if (now() > deadline) fail("the fixture did not publish a fresh pairing invitation");
    await sleep(50);
    code = readEnrollmentCode();
  }
  const response = await withDeadline(fetch(`http://127.0.0.1:${config.port}/v1/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, deviceName }),
  }), 15_000, "pairing");
  const body = await response.json();
  if (!response.ok || typeof body.token !== "string") fail(`pairing failed with HTTP ${response.status}`);
  return { token: body.token, code };
}

function sampleGatewayUsage() {
  return new Promise((resolveUsage, rejectUsage) => {
    execFile("python3", [config.orchestrator, "_rusage", String(config.gatewayPid)], { timeout: 10_000 }, (error, stdout) => {
      if (error) return rejectUsage(new Error(`rusage sampling failed: ${error.message}`));
      try { resolveUsage(JSON.parse(stdout)); } catch (parseError) { rejectUsage(parseError); }
    });
  });
}

function usageDelta(before, after) {
  const delta = {};
  for (const key of Object.keys(after)) {
    if (typeof after[key] === "number" && typeof before[key] === "number") delta[key] = after[key] - before[key];
  }
  return delta;
}

/** Resolves when `sessionId` reports idle after having run, then after `quietMs`
 * without inbound frames on any recorded client. */
function settled(observer, recorders, sessionId, deadlineMs) {
  return withDeadline(new Promise((resolveSettled) => {
    let ran = false;
    let idleAt = null;
    const listener = (frame) => {
      if (frame.type !== "event" || frame.topic !== "session.summary") return;
      const summary = frame.payload;
      if (summary?.sessionId !== sessionId) return;
      if (summary.phase !== "idle") ran = true;
      else if (ran && idleAt === null) idleAt = now();
    };
    observer.listeners.add(listener);
    const poll = setInterval(() => {
      if (idleAt === null) return;
      const lastFrame = Math.max(...recorders.map((client) => client.lastFrameAt));
      if (now() - Math.max(idleAt, lastFrame) >= config.quietMs) {
        clearInterval(poll);
        observer.listeners.delete(listener);
        resolveSettled(idleAt);
      }
    }, 50);
  }), deadlineMs, `session ${sessionId} to settle`);
}

async function main() {
  mkdirSync(config.outputDir, { recursive: true });
  const timelineStream = createWriteStream(join(config.outputDir, "timeline.jsonl"));
  const timeline = { write: (record) => timelineStream.write(`${JSON.stringify(record)}\n`) };
  const clients = [];
  const mobiles = [];
  const result = { schema: "tron.profile-gateway-run.v1", scenario: config.scenario, clients: {}, iterations: [] };
  try {
    const recorders = [];
    let code = null;
    const tokens = {};
    for (const name of ["mobile", "dashboard", "driver"]) {
      const paired = await pair(`Tron profile ${name}`, code);
      code = paired.code;
      tokens[name] = paired.token;
    }
    const wants = config.scenario === "dashboard-observer" ? ["dashboard", "driver"] : ["mobile", "dashboard"];
    const byName = {};
    for (const name of wants) {
      const client = new RecordingClient(name, tokens[name], timeline);
      await client.connect();
      clients.push(client);
      byName[name] = client;
      if (name !== "driver") recorders.push(client);
      // Dashboard catalog load, as DashboardStateOwners does after connecting.
      await client.request("session.list", { limit: 500, scope: "user" });
      result.clients[name] = {
        offeredExtensions: client.offeredExtensions,
        negotiatedExtensions: client.negotiatedExtensions,
        recorded: name !== "driver",
      };
    }
    result.gateway = { version: byName[wants[0]].info.gatewayVersion, protocolVersion: byName[wants[0]].info.protocolVersion };
    await sleep(config.settleBeforeMs);

    // Warm-up iterations run the identical workload unmeasured, so first-use
    // effects (JIT, model recents, catalog materialization) stay out of samples.
    result.warmups = [];
    for (let iteration = 0; iteration < config.warmup + config.iterations; iteration += 1) {
      const warmup = iteration < config.warmup;
      const label = warmup ? `warmup-${iteration + 1}` : `iteration-${iteration - config.warmup + 1}`;
      const actor = config.scenario === "dashboard-observer" ? byName.driver : byName.mobile;
      let sessionId;
      if (config.scenario === "stream-reply" || config.scenario === "idle") {
        const created = await actor.request("session.create", { cwd: config.workspace, commandId: randomUUID() });
        sessionId = created.sessionId;
      } else {
        sessionId = config.seededSessions[iteration]?.sessionId ?? fail(`no seeded session for ${label}`);
      }
      const chat = new MountedChat(actor, sessionId);
      mobiles.push(chat);
      const opened = await chat.open();
      const openedModel = opened.session.model ?? null;
      process.stderr.write(`${label} ${sessionId} opened with model ${JSON.stringify(openedModel)}\n`);
      // Pi 0.87.1 can open a cold session with no model when its provider comes
      // from an extension (an availability refresh race), which the phone would
      // surface as a send failure. Select the profile model explicitly on every
      // iteration, before the window, so each measured workload is identical.
      await actor.request("session.setModel", {
        sessionId, provider: "tron-profile", modelId: "profile-model", commandId: randomUUID(),
      });
      await sleep(config.settleBeforeMs);

      for (const client of clients) client.beginWindow(label);
      const before = await sampleGatewayUsage();
      const windowStart = now();
      let settledAt = null;
      if (config.scenario === "idle") {
        await sleep(config.windowSeconds * 1000);
      } else {
        const done = settled(actor, recorders, sessionId, config.runDeadlineSeconds * 1000);
        await actor.request("session.prompt", { sessionId, text: config.prompt, commandId: randomUUID() });
        settledAt = await done;
      }
      const windowEnd = now();
      const after = await sampleGatewayUsage();
      const windows = {};
      for (const client of clients) {
        const window = client.endWindow();
        if (client.name !== "driver") windows[client.name] = window;
      }
      const outcome = chat.outcome();
      await chat.close();
      mobiles.pop();
      const openTranscript = opened.session.transcript ?? [];
      (warmup ? result.warmups : result.iterations).push({
        label, sessionId,
        windowSeconds: (windowEnd - windowStart) / 1000,
        settleSeconds: settledAt === null ? null : (settledAt - windowStart) / 1000,
        gateway: usageDelta(before, after),
        outcome,
        openedModel,
        openedTranscript: { items: openTranscript.length, total: opened.session.transcriptTotal,
          bytes: Buffer.byteLength(JSON.stringify(openTranscript)) },
        clients: windows,
      });
      for (const client of clients) {
        if (client.closedUnexpectedly) fail(`${client.name} ${client.closedUnexpectedly}`);
      }
      await sleep(config.settleBetweenMs);
    }
  } finally {
    for (const chat of mobiles) clearInterval(chat.renewal);
    for (const client of clients) await client.close();
    await new Promise((resolveFlush) => timelineStream.end(resolveFlush));
  }
  writeFileSync(join(config.outputDir, "result.json"), `${JSON.stringify(result, null, 2)}\n`);
}

try {
  if (command === "seed") await seed();
  else await main();
} catch (error) {
  process.stderr.write(`error: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(1);
}
