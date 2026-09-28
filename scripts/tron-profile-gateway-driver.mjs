#!/usr/bin/env node
// Workload and recording clients for scripts/tron-profile-gateway.
//
//   node scripts/tron-profile-gateway-driver.mjs seed CONFIG.json
//   node scripts/tron-profile-gateway-driver.mjs run CONFIG.json
//   node scripts/tron-profile-gateway-driver.mjs catalog CONFIG.json
//   node scripts/tron-profile-gateway-driver.mjs multi CONFIG.json
//
// `seed` writes deterministic canonical Pi session JSONL into the isolated
// fixture before its Gateway starts. `run` pairs like the phone, connects the
// recording clients, drives one scenario for N iterations and writes per-window
// counts plus a per-frame timeline. `catalog` generates the multi-session
// scenario's seeded catalog (sessions, forks, subagent runs) in the fixture's
// private agent directory; `multi` drives one multi-session phase against a
// freshly started fixture. The orchestrator owns metric naming, the fixture
// process, and the report; this file only measures.
//
// Phone fidelity (packages/ios-app): GatewayClient.establishConnection sends
// hello {protocolVersion, clientId, clientRole: "mobile"}; GatewayConnectionPolicy
// pings every 10 s with an 8 s pong deadline; URLSessionWebSocketTask offers
// `permessage-deflate` without parameters and answers server pings; the
// dashboard loads `session.list` (limit 500, scope user); a mounted chat runs
// SessionPresentationStore's session.open -> session.sync ->
// session.presentation.set(visible) and renews that lease every 15 s.

import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import {
  closeSync, createWriteStream, mkdirSync, openSync, readFileSync, readSync, fstatSync, writeFileSync, writeSync,
} from "node:fs";
import { appendFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const CLIENT_PING_INTERVAL_MS = 10_000;
const CLIENT_PONG_DEADLINE_MS = 8_000;
const PRESENTATION_LEASE_RENEWAL_MS = 15_000;
const REQUEST_TIMEOUT_MS = 30_000;
const PROTOCOL_VERSION = 6;

const [command, configPath] = process.argv.slice(2);
if (!["seed", "run", "catalog", "multi"].includes(command) || !configPath) {
  process.stderr.write("usage: tron-profile-gateway-driver.mjs seed|run|catalog|multi CONFIG.json\n");
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

/** A sleep whose timer can be cancelled. An un-cleared `setTimeout` keeps the
 * whole driver process alive for its full delay, so every bounded wait cancels
 * its timer as soon as the wait ends. */
function cancellableSleep(ms) {
  let timer;
  const done = new Promise((resolveSleep) => { timer = setTimeout(resolveSleep, ms); });
  return { done, cancel: () => clearTimeout(timer) };
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

// --- Multi-session catalog -------------------------------------------------
//
// Shape of the catalog measured on 2026-09-27 (2,995 JSONL files: 225
// sessions, 460 forks, the rest subagent runs), scaled to `files` and `bytes`.
// Every byte derives from `seed`, so one seed always yields the same tree and
// digest. Layout follows the Gateway's delegated-session contract
// (RuntimeRegistry.delegatedTopologyParentPath):
// <parent-stem>/forks/<fork>.jsonl and <parent-stem>/<producer>/run-N/session.jsonl.

const MIB = 1024 * 1024;
const CATALOG_SCHEMA = "tron.profile-gateway-catalog.v1";
const CATALOG_SESSION_SHARE = 225 / 3000;
const CATALOG_FORK_SHARE = 460 / 3000;
const CATALOG_REFERENCE_BYTES = 2048 * MIB;
// Five large sessions at the reference size, as the largest measured ones.
const LARGE_SESSION_MIB = [100, 125, 150, 175, 200];
const MINIMUM_FILE_BYTES = 4 * 1024;
// Cold-open targets share one size so every iteration opens the same load.
const COLD_SESSION_BYTES = MIB;
const CATALOG_PROJECTS = 12;
const SUBAGENT_PRODUCERS = ["worker", "reviewer", "scout", "planner"];
const TOOL_RESULT_CHARS = [512, 1024, 2048, 4096, 8192, 16384];
const CATALOG_EPOCH_MS = Date.parse("2026-06-01T00:00:00.000Z");
const CATALOG_USAGE = '{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,'
  + '"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}';

function seededHex(random, length) {
  let text = "";
  while (text.length < length) text += Math.floor(random() * 16).toString(16);
  return text;
}

function seededSessionId(random) {
  const hex = seededHex(random, 32);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-7${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

function gaussian(random) {
  return Math.sqrt(-2 * Math.log(1 - random())) * Math.cos(2 * Math.PI * random());
}

/** JSON-encoded text pools; transcripts pick from them so generation stays I/O bound. */
function textPools(seed) {
  const random = generator(seed);
  const pool = (count, min, max) => Array.from({ length: count },
    () => JSON.stringify(prose(random, min + Math.floor(random() * (max - min + 1)))));
  return {
    user: pool(16, 120, 400),
    thinking: pool(16, 160, 600),
    text: pool(16, 200, 800),
    tool: TOOL_RESULT_CHARS.map((chars) => pool(4, chars, chars)),
    seeded: { user: pool(4, 240, 240), thinking: pool(4, 280, 280), text: pool(4, 480, 480), tool: pool(4, 470, 470) },
  };
}

class TranscriptWriter {
  /** `portable` rewrites fixture-specific paths so the digest names the
   * catalog, not the temporary directory it was generated in. */
  constructor(root, path, header, random, digest, portable) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.fd = openSync(path, "wx", 0o600);
    this.random = random;
    this.digest = digest;
    this.nextId = 0;
    this.leaf = null;
    this.clock = Date.parse(header.timestamp);
    const line = `${JSON.stringify(header)}\n`;
    writeSync(this.fd, line);
    digest.update(portable(`${relative(root, path)}\n${line}`));
    this.bytes = line.length;
    this.chunks = [];
    this.pending = 0;
  }

  line(text) {
    this.chunks.push(text, "\n");
    this.bytes += text.length + 1; // pools and envelopes are ASCII
    this.pending += text.length + 1;
    if (this.pending >= 4 * MIB) this.flush();
  }

  flush() {
    if (this.pending === 0) return;
    const buffer = Buffer.from(this.chunks.join(""), "utf8");
    let offset = 0;
    while (offset < buffer.length) offset += writeSync(this.fd, buffer, offset);
    this.digest.update(buffer);
    this.chunks = [];
    this.pending = 0;
  }

  entry(type, body) {
    const id = (this.nextId++).toString(16).padStart(8, "0");
    const timestamp = (this.clock += 1000);
    const parent = this.leaf === null ? "null" : `"${this.leaf}"`;
    this.line(`{"type":"${type}","id":"${id}","parentId":${parent},"timestamp":"${new Date(timestamp).toISOString()}",${body(timestamp, id)}}`);
    this.leaf = id;
  }

  preamble(name) {
    this.entry("model_change", () => '"provider":"tron-profile","modelId":"profile-model"');
    this.entry("thinking_level_change", () => '"thinkingLevel":"low"');
    if (name) this.entry("session_info", () => `"name":${JSON.stringify(name)}`);
  }

  /** One user prompt, a tool call, its result, and a final answer. */
  turn(pools) {
    const pick = (list) => list[Math.floor(this.random() * list.length)];
    const assistant = (content, stopReason, timestamp) => `"message":{"role":"assistant","content":[${content}],`
      + `"api":"faux","provider":"tron-profile","model":"profile-model","usage":${CATALOG_USAGE},`
      + `"stopReason":"${stopReason}","timestamp":${timestamp}}`;
    const toolPool = Array.isArray(pools.tool[0]) ? pick(pools.tool) : pools.tool;
    this.entry("message", (timestamp) => `"message":{"role":"user","content":[{"type":"text","text":${pick(pools.user)}}],"timestamp":${timestamp}}`);
    let callId;
    this.entry("message", (timestamp, id) => {
      callId = `call_${id}`;
      return assistant(`{"type":"thinking","thinking":${pick(pools.thinking)}},{"type":"text","text":${pick(pools.text)}},`
        + `{"type":"toolCall","id":"${callId}","name":"bash","arguments":{"command":"printf generated"}}`, "toolUse", timestamp);
    });
    this.entry("message", (timestamp) => `"message":{"role":"toolResult","toolCallId":"${callId}","toolName":"bash",`
      + `"content":[{"type":"text","text":${pick(toolPool)}}],"isError":false,"timestamp":${timestamp}}`);
    this.entry("message", (timestamp) => assistant(`{"type":"text","text":${pick(pools.text)}}`, "stop", timestamp));
  }

  close() {
    this.flush();
    closeSync(this.fd);
  }
}

function catalogPlan() {
  const files = config.files;
  const scale = config.bytes / CATALOG_REFERENCE_BYTES;
  const pools = config.runSessions + config.coldSessions;
  const sessions = Math.max(Math.round(files * CATALOG_SESSION_SHARE), LARGE_SESSION_MIB.length + pools + CATALOG_PROJECTS);
  const forks = Math.round(files * CATALOG_FORK_SHARE);
  const subagents = files - sessions - forks;
  if (subagents < config.appendTargets) fail(`${files} files cannot hold ${sessions} sessions, ${forks} forks and ${config.appendTargets} subagent runs`);
  const largeBytes = LARGE_SESSION_MIB.map((mib) => Math.round(mib * MIB * scale));
  const coldBytes = config.coldSessions * COLD_SESSION_BYTES;
  // Run-pool sessions hold 160 seeded turns (about 350 KB), enough to fill the
  // snapshot transcript page like the tool-loop scenario's seeded sessions.
  const runBytes = config.runSessions * 350 * 1024;
  const others = sessions - LARGE_SESSION_MIB.length - pools + forks + subagents;
  const remaining = config.bytes - largeBytes.reduce((sum, value) => sum + value, 0) - coldBytes - runBytes;
  if (remaining < others * MINIMUM_FILE_BYTES) fail(`${config.bytes} bytes cannot hold the fixed sessions and ${others} other files`);
  return { sessions, forks, subagents, largeBytes, remaining };
}

function generateCatalog() {
  const startedAt = performance.now();
  const plan = catalogPlan();
  const root = resolve(config.agentDir, "sessions");
  const digest = createHash("sha256");
  const workspace = resolve(config.workspace);
  const encodedWorkspace = workspace.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-");
  const portable = (text) => text.split(root).join("<catalog>").split(workspace).join("<workspace>")
    .split(encodedWorkspace).join("<workspace>");
  const pools = textPools(config.seed);
  const layout = generator(config.seed ^ 0x5eed);
  const projects = Array.from({ length: CATALOG_PROJECTS }, (_, index) => {
    const cwd = resolve(config.workspace, `project-${String(index + 1).padStart(2, "0")}`);
    mkdirSync(cwd, { recursive: true, mode: 0o700 });
    return { cwd, directory: join(root, `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`) };
  });
  let index = 0;
  let totalBytes = 0;
  const write = (path, header, fill) => {
    const random = generator(Math.imul(config.seed, 100_003) + index);
    const writer = new TranscriptWriter(root, path, header, random, digest, portable);
    fill(writer);
    writer.close();
    totalBytes += writer.bytes;
    index += 1;
    return { path, bytes: writer.bytes, leaf: writer.leaf };
  };
  const header = (random, cwd, parentSession) => {
    const id = seededSessionId(random);
    const timestamp = new Date(CATALOG_EPOCH_MS + index * 37 * 60_000).toISOString();
    return { type: "session", version: 3, id, timestamp, cwd, ...(parentSession ? { parentSession } : {}) };
  };
  const fillTo = (bytes, turnPools = pools) => (writer) => {
    writer.preamble(null);
    do writer.turn(turnPools); while (writer.bytes < bytes);
  };
  const topLevel = (name, fill) => {
    const project = projects[index % projects.length];
    const value = header(layout, project.cwd);
    const path = join(project.directory, `${value.timestamp.replace(/[:.]/g, "-")}_${value.id}.jsonl`);
    const written = write(path, value, (writer) => { writer.preamble(name); fill(writer); });
    return { sessionId: value.id, cwd: project.cwd, ...written };
  };

  const large = plan.largeBytes.map((bytes, position) => topLevel(`Large session ${position + 1}`,
    (writer) => { do writer.turn(pools); while (writer.bytes < bytes); }));
  const runPool = Array.from({ length: config.runSessions }, (_, position) => topLevel(`Running session ${position + 1}`,
    (writer) => { for (let turn = 0; turn < 160; turn += 1) writer.turn(pools.seeded); }));
  const coldPool = Array.from({ length: config.coldSessions }, (_, position) => topLevel(`Cold session ${position + 1}`,
    (writer) => { do writer.turn(pools); while (writer.bytes < COLD_SESSION_BYTES); }));

  // Remaining files share the remaining bytes by class weight and a seeded
  // log-normal spread: sessions are larger than forks, subagent runs smaller.
  const others = [
    ...Array.from({ length: plan.sessions - large.length - runPool.length - coldPool.length }, () => ({ kind: "session", weight: 3 })),
    ...Array.from({ length: plan.forks }, () => ({ kind: "fork", weight: 2 })),
    ...Array.from({ length: plan.subagents }, () => ({ kind: "subagent", weight: 0.5 })),
  ];
  for (const item of others) item.weight *= Math.exp(0.8 * gaussian(layout));
  const totalWeight = others.reduce((sum, item) => sum + item.weight, 0);
  const parents = [...large];
  const subagentRuns = [];
  const runsByParent = new Map();
  for (const item of others) {
    const bytes = Math.max(MINIMUM_FILE_BYTES, Math.floor(plan.remaining * item.weight / totalWeight));
    if (item.kind === "session") {
      parents.push(topLevel(`Session ${parents.length + 1}`, (writer) => { do writer.turn(pools); while (writer.bytes < bytes); }));
      continue;
    }
    const parent = parents[Math.floor(layout() * parents.length)];
    const stem = parent.path.slice(0, -".jsonl".length);
    const value = header(layout, parent.cwd, parent.path);
    if (item.kind === "fork") {
      write(join(stem, "forks", `${value.timestamp.replace(/[:.]/g, "-")}_${value.id}.jsonl`), value, fillTo(bytes));
      continue;
    }
    const producer = SUBAGENT_PRODUCERS[Math.floor(layout() * SUBAGENT_PRODUCERS.length)];
    const key = `${stem}/${producer}`;
    const run = (runsByParent.get(key) ?? 0) + 1;
    runsByParent.set(key, run);
    const written = write(join(stem, producer, `run-${run}`, "session.jsonl"), value, fillTo(bytes));
    subagentRuns.push({ sessionId: value.id, ...written });
  }
  const pick = ({ sessionId, path, bytes, cwd }) => ({ sessionId, path, bytes, cwd });
  const manifest = {
    schema: CATALOG_SCHEMA,
    seed: config.seed,
    root,
    files: index,
    bytes: totalBytes,
    sessions: plan.sessions,
    forks: plan.forks,
    subagentRuns: plan.subagents,
    digest: digest.digest("hex"),
    generationSeconds: (performance.now() - startedAt) / 1000,
    large: large.map(pick),
    runPool: runPool.map(pick),
    coldPool: coldPool.map(pick),
    appendTargets: subagentRuns.slice(0, config.appendTargets).map(({ path }) => path),
  };
  writeFileSync(config.output, `${JSON.stringify(manifest, null, 2)}\n`);
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
    // Set by close(): permanent, so a reconnect still in flight cannot leave a
    // socket open behind a finished run.
    this.retired = false;
    // Stable across reconnects, as the phone's client identity is.
    this.clientId = randomUUID();
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
      // A socket retired by reconnect() may finish closing after its successor opened.
      if (socket !== this.socket) return;
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
    this.send({ type: "hello", protocolVersion: PROTOCOL_VERSION, clientId: this.clientId, clientRole: "mobile" });
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
      if (frame.ok === false) {
        waiter.reject(Object.assign(new Error(`${waiter.method} failed: ${JSON.stringify(frame.error)}`), { gatewayError: frame.error }));
      }
      else waiter.resolve(frame.result);
      return;
    }
    for (const listener of this.listeners) listener(frame, topic);
  }

  request(method, params = {}, deadlineMs = REQUEST_TIMEOUT_MS) {
    // A lease renewal can fire while reconnect() has no open socket.
    if (this.socket?.readyState !== 1) return Promise.reject(new Error(`${this.name} ${method}: socket not open`));
    const id = randomUUID();
    const promise = new Promise((resolveRequest, rejectRequest) => {
      this.pending.set(id, { method, resolve: resolveRequest, reject: rejectRequest });
    });
    this.send({ type: "request", id, method, params });
    return withDeadline(promise, deadlineMs, `${this.name} ${method}`);
  }

  /** Close and reopen the socket like a phone reconnect; the open window,
   * listeners and client identity carry over. */
  async reconnect() {
    await this.disconnect();
    // A client retired by close() while this reconnect was in flight must not
    // open another socket: an abandoned lane would keep the driver alive.
    if (this.retired) throw new Error(`${this.name} reconnected after it was closed`);
    // disconnect() gives up waiting after 3 s and terminates; retire the old
    // socket and its unanswered requests now rather than when its close event lands.
    this.socket = null;
    for (const { reject } of this.pending.values()) reject(new Error(`${this.name} reconnected`));
    this.pending.clear();
    const window = this.window;
    if (window && this.tcp) {
      window.socketCarryRead += this.tcp.bytesRead - window.socketRead0;
      window.socketCarryWritten += this.tcp.bytesWritten - window.socketWritten0;
    }
    this.closing = false;
    this.awaitingPong = null;
    this.tcp = null;
    await this.connect();
    if (this.retired) await this.disconnect();
    if (window) {
      window.socketRead0 = this.tcp.bytesRead;
      window.socketWritten0 = this.tcp.bytesWritten;
    }
  }

  beginWindow(label) {
    this.label = label;
    this.window = emptyWindow();
    this.window.socketRead0 = this.tcp?.bytesRead ?? null;
    this.window.socketWritten0 = this.tcp?.bytesWritten ?? null;
    this.window.socketCarryRead = 0;
    this.window.socketCarryWritten = 0;
  }

  endWindow() {
    const window = this.window;
    this.window = null;
    const read = this.tcp?.bytesRead ?? null;
    const written = this.tcp?.bytesWritten ?? null;
    window.socketBytesRead = read !== null && window.socketRead0 !== null ? read - window.socketRead0 + window.socketCarryRead : null;
    window.socketBytesWritten = written !== null && window.socketWritten0 !== null
      ? written - window.socketWritten0 + window.socketCarryWritten : null;
    delete window.socketRead0;
    delete window.socketWritten0;
    delete window.socketCarryRead;
    delete window.socketCarryWritten;
    this.label = "between";
    return window;
  }

  /** Drop the open socket, whatever state it is in, and stop the pings. */
  async disconnect() {
    this.closing = true;
    clearInterval(this.pingTimer);
    const socket = this.socket;
    if (!socket) return;
    if (socket.readyState === 1) {
      socket.close(1000, "profile complete");
      await withDeadline(new Promise((resolveClose) => socket.once("close", resolveClose)), 3_000, `${this.name} close`)
        .catch(() => socket.terminate());
    } else {
      // Connecting, closing or already closed: terminate so no socket handle is
      // left behind (an abandoned lane can leave the client in any state).
      socket.terminate();
    }
  }

  /** Close for good. Retired is permanent, so a lane's reconnect can no longer
   * open a socket and the driver process can exit while it unwinds. */
  async close() {
    this.retired = true;
    await this.disconnect();
  }
}

/** Mounted-chat presentation owner mirroring SessionPresentationStore. */
class MountedChat {
  constructor(client, sessionId) {
    this.client = client;
    this.sessionId = sessionId;
    this.revision = 0;
  }

  async open(deadlineMs = REQUEST_TIMEOUT_MS) {
    const opened = await this.client.request("session.open", { sessionId: this.sessionId }, deadlineMs);
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
    const synced = await this.client.request("session.sync", { sessionId: this.sessionId, syncToken: opened.syncToken }, deadlineMs);
    if (synced?.synchronized !== true) fail("session.sync did not synchronize");
    await this.setVisible(true, deadlineMs);
    this.renewal = setInterval(() => { void this.setVisible(true).catch((error) => { this.renewalError = error; }); }, PRESENTATION_LEASE_RENEWAL_MS);
    return opened;
  }

  setVisible(visible, deadlineMs = REQUEST_TIMEOUT_MS) {
    this.revision += 1;
    return this.client.request("session.presentation.set", {
      sessionId: this.sessionId, subscriptionToken: this.token, revision: this.revision, visible,
    }, deadlineMs);
  }

  /** Restore the mounted chat on a new socket, as the phone does after a reconnect. */
  remount(deadlineMs) {
    clearInterval(this.renewal);
    this.client.listeners.delete(this.listener);
    const gaps = this.sequenceGaps ?? 0;
    return this.open(deadlineMs).then((opened) => {
      this.sequenceGaps += gaps;
      this.renewalError = null; // a renewal cut off by the reconnect is not a failure
      return opened;
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

// --- Multi-session phase -------------------------------------------------------
//
// One phase per fixture Gateway process: `prime` pairs the three devices and
// lets the first catalog load build the durable index; each `iteration` then
// starts eight long tool loops, measures a window with no session subscriber,
// mounts the mobile chat, and measures a mixed window while the dashboard
// lists, the prober opens warm, cold and large sessions and prompts cold ones,
// both recorded clients reconnect on schedule, and subagent-like writers append
// to child transcripts.

const APPENDED_TEXT = prose(generator(11), 900);
// The prober's warm and large lanes and the dashboard's reconnect lane use
// their own devices: the Gateway admits one session.open per connection, so a
// minutes-long large cold open must not starve the warm and cold samples, and a
// minutes-long list must not starve the reconnect sample.
const MULTI_DEVICES = ["mobile", "dashboard", "dashboard-reconnect", "driver", "warm", "large"];
// A retryable Gateway error (for example `busy` when the catalog changed while
// a session opened) would surface on the phone as a failed open; the profile
// retries after a short pause, counts it, and times the operation to success.
const BUSY_RETRY_DELAY_MS = 250;
const BUSY_RETRY_LIMIT = 40;

async function retryingBusy(retries, method, operation) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      if (error?.gatewayError?.retryable !== true || attempt >= BUSY_RETRY_LIMIT) throw error;
      retries[method] = (retries[method] ?? 0) + 1;
      await sleep(BUSY_RETRY_DELAY_MS);
    }
  }
}

function lastEntryId(path) {
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd).size;
    const length = Math.min(size, 256 * 1024);
    const buffer = Buffer.alloc(length);
    readSync(fd, buffer, 0, length, size - length);
    const lines = buffer.toString("utf8").trimEnd().split("\n");
    return JSON.parse(lines.at(-1)).id ?? fail(`${path} ends without an entry id`);
  } finally {
    closeSync(fd);
  }
}

/** Subagent-like external writers: one entry per target every interval. */
function startAppender(paths, intervalMs, label) {
  const targets = paths.map((path) => ({ path, leaf: lastEntryId(path), next: 0 }));
  const prefix = label.replace(/[^A-Za-z0-9]/g, "");
  let appended = 0;
  let failure = null;
  let busy = null;
  const timer = setInterval(() => {
    if (busy) return;
    busy = Promise.all(targets.map(async (target) => {
      const id = `${prefix}${(target.next += 1).toString(16)}`;
      const line = JSON.stringify({
        type: "message", id, parentId: target.leaf, timestamp: new Date().toISOString(),
        message: { role: "assistant", content: [{ type: "text", text: APPENDED_TEXT }], api: "faux", provider: "tron-profile",
          model: "profile-model", usage: JSON.parse(CATALOG_USAGE), stopReason: "stop", timestamp: Date.now() },
      });
      await appendFile(target.path, `${line}\n`);
      target.leaf = id;
      appended += 1;
    })).catch((error) => { failure ??= error; }).finally(() => { busy = null; });
  }, intervalMs);
  return {
    async stop() {
      clearInterval(timer);
      await busy;
      if (failure) throw failure;
      return appended;
    },
  };
}

function readProbe() {
  try { return JSON.parse(readFileSync(config.probeOutput, "utf8")); } catch { return null; }
}

/** Ask the fixture's probe for a snapshot; it answers once its event loop runs. */
async function probeSnapshot() {
  const previous = readProbe()?.sequence ?? 0;
  process.kill(config.gatewayPid, "SIGUSR2");
  // A blocked Gateway event loop answers late; that delay is the measurement.
  const deadline = now() + config.measuredDeadlineMs;
  for (;;) {
    const snapshot = readProbe();
    if (snapshot && snapshot.sequence > previous) return snapshot;
    if (now() > deadline) fail(`the fixture probe did not answer SIGUSR2 within ${config.measuredDeadlineMs} ms`);
    await sleep(25);
  }
}

/**
 * One measured window. `body(start)` starts the workload; when `fixedSeconds`
 * is set it must only start the lanes and return, and the window closes at
 * `start + fixedSeconds` whether or not their operations have finished.
 * In-flight operations then get `tailGraceSeconds` to finish outside the
 * window: their latency still counts, and whatever is left is censored by
 * `abandonInflight` so one slow operation can neither stretch the window nor
 * the run. A lane that fails inside the window is thrown here at once, so the
 * caller's `finally` still stops the appender, closes the clients and flushes
 * the timeline.
 */
async function measuredWindow(label, connected, recorded, body, options = {}) {
  const { fixedSeconds = null, tailGraceSeconds = null, abandonInflight = null } = options;
  for (const client of connected) client.beginWindow(label);
  const probeBefore = await probeSnapshot();
  const before = await sampleGatewayUsage();
  const start = now();
  let lanes = null;
  if (fixedSeconds === null) {
    await body(start);
  } else {
    lanes = body(start);
    // The handler is attached with the lanes, not after the deadline: a lane
    // that rejects inside the window must surface as this function's failure
    // instead of as an unhandled rejection that kills the process before any
    // cleanup runs.
    const laneFailure = lanes.then(() => null, (error) => ({ error }));
    const settled = await Promise.race([
      sleep(Math.max(0, start + fixedSeconds * 1000 - now())).then(() => null), laneFailure]);
    if (settled !== null) throw settled.error;
  }
  // The window closes before any sample is read: frames, bytes, CPU time and
  // catalog walks of work that outlives the deadline belong to the tail.
  const end = now();
  const clients = {};
  for (const client of connected) {
    const window = client.endWindow();
    if (recorded.includes(client.name)) clients[client.name] = window;
  }
  const after = await sampleGatewayUsage();
  const probeAfter = await probeSnapshot();
  const window = {
    label, windowSeconds: (end - start) / 1000, gateway: usageDelta(before, after), clients,
    probe: {
      catalogWalks: probeAfter.catalogWalks - probeBefore.catalogWalks,
      eventLoopDelay: probeAfter.eventLoopDelay,
      heapUsedPeakBytes: probeAfter.heapUsedPeakBytes,
      heapLimitBytes: probeAfter.heapLimitBytes,
      rssPeakBytes: probeAfter.rssPeakBytes,
    },
  };
  if (lanes !== null) {
    const tailStart = now();
    // Cancelled in `finally`: the timer must not outlive the tail, or the
    // driver would idle (and keep its parent waiting) for the full grace
    // period after every iteration.
    const tail = cancellableSleep(tailGraceSeconds * 1000);
    let expired = false;
    try {
      // A lane that fails after the deadline is still fatal: its rejection
      // ends the race and reaches the caller's `finally` like any other.
      await Promise.race([lanes, tail.done.then(() => { expired = true; })]);
    } finally {
      tail.cancel();
    }
    window.tail = {
      seconds: (now() - tailStart) / 1000, outcome: expired ? "abandoned" : "complete",
      abandoned: expired && abandonInflight ? abandonInflight() : [],
    };
  }
  return window;
}

async function multi() {
  mkdirSync(config.outputDir, { recursive: true });
  const timelineStream = createWriteStream(join(config.outputDir, "timeline.jsonl"), { flags: "a" });
  const timeline = { write: (record) => timelineStream.write(`${JSON.stringify(record)}\n`) };
  const clients = [];
  const chats = [];
  let appender = null;
  const measured = config.measuredDeadlineMs;
  const result = { schema: "tron.profile-gateway-multi.v1", phase: config.phase, label: config.label };
  const resultPath = join(config.outputDir, `result-${config.label}.json`);
  const connect = async (name, token) => {
    const client = new RecordingClient(name, token, timeline);
    client.label = config.label;
    await client.connect();
    clients.push(client);
    return client;
  };
  try {
    if (config.phase === "prime") {
      const tokens = {};
      let code = null;
      for (const name of MULTI_DEVICES) {
        const paired = await pair(`Tron profile ${name}`, code);
        code = paired.code;
        tokens[name] = paired.token;
      }
      writeFileSync(config.devicesPath, JSON.stringify(tokens), { mode: 0o600 });
      const dashboard = await connect("dashboard", tokens.dashboard);
      result.gateway = { version: dashboard.info.gatewayVersion, protocolVersion: dashboard.info.protocolVersion };
      // The phone's dashboard list (user scope) builds the durable index.
      const started = now();
      const listed = await dashboard.request("session.list", { limit: 500, scope: "user" }, measured);
      result.list = { ms: now() - started, rows: listed?.sessions?.length ?? null };
      writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
      return;
    }

    const tokens = JSON.parse(readFileSync(config.devicesPath, "utf8"));
    const samples = {
      sessionList: [], sessionOpenWarm: [], sessionOpenCold: [], sessionOpenColdLarge: [], promptAdmission: [],
      reconnectReadyMobile: [], reconnectReadyDashboard: [],
    };
    // Operations a lane is still waiting on. The mixed window's tail expires
    // with one of them in flight on a slow fixture, so each one is censored
    // (its elapsed time is the sample) instead of holding the run open.
    const inflight = new Set();
    // Set once the mixed window's tail has ended: an operation a lane finishes
    // after that is no longer measured, so the sample set cannot change while
    // the run winds down (and cannot gain a post-window sample).
    let measuring = true;
    const timed = async (kind, operation) => {
      const entry = { kind, startedAt: now(), censored: false };
      inflight.add(entry);
      try {
        const value = await operation();
        if (measuring && !entry.censored) samples[kind].push(now() - entry.startedAt);
        return value;
      } finally {
        inflight.delete(entry);
      }
    };
    const abandonInflight = () => {
      const abandoned = [];
      for (const entry of inflight) {
        entry.censored = true;
        const elapsedMs = now() - entry.startedAt;
        samples[entry.kind].push(elapsedMs);
        abandoned.push({ kind: entry.kind, elapsedMs: Math.round(elapsedMs) });
      }
      return abandoned;
    };
    const driver = await connect("driver", tokens.driver);
    const phases = new Map();
    driver.listeners.add((frame) => {
      if (frame.type === "event" && frame.topic === "session.summary" && frame.payload?.sessionId) {
        phases.set(frame.payload.sessionId, frame.payload.phase);
      }
    });
    const dashboard = await connect("dashboard", tokens.dashboard);
    let started = now();
    await dashboard.request("session.list", { limit: 500, scope: "user" }, measured);
    result.startupListMs = now() - started;

    // Eight long tool loops; the driver unsubscribes after each prompt, so the
    // runs continue with no session subscriber (accepted prompts outlive them).
    result.setupPromptMs = [];
    const retries = {};
    result.busyRetries = retries;
    const retrying = (client, method, params) => retryingBusy(retries, method, () => client.request(method, params, measured));
    const mutation = (client, method, params) => {
      const commandId = randomUUID(); // one command, however often admission is retried
      return retrying(client, method, { ...params, commandId });
    };
    for (const { sessionId } of config.running) {
      const opened = await retrying(driver, "session.open", { sessionId });
      await mutation(driver, "session.setModel", { sessionId, provider: "tron-profile", modelId: "profile-model" });
      started = now();
      await mutation(driver, "session.prompt", { sessionId, text: config.runPrompt });
      result.setupPromptMs.push(now() - started);
      await driver.request("session.close", { sessionId, subscriptionToken: opened.subscriptionToken }, measured);
    }
    await sleep(config.settleBeforeMs);

    // The subagent-like writers start with the measured windows, not with the
    // setup: on `main` every append re-scans the whole catalog, and the eight
    // cold opens that bring the steady state up must not queue behind that
    // backlog (they are a precondition, not a measurement).
    appender = startAppender(config.appendTargets, config.appendIntervalMs, config.label);

    result.noSubscriber = await measuredWindow("no-subscriber", [driver, dashboard], ["dashboard"],
      () => sleep(config.noSubscriberSeconds * 1000));

    const mobile = await connect("mobile", tokens.mobile);
    const chat = new MountedChat(mobile, config.running[0].sessionId);
    chats.push(chat);
    await retryingBusy(retries, "mount", () => chat.remount(measured));
    await sleep(config.settleBeforeMs);

    const reconnectMs = config.reconnectIntervalSeconds * 1000;
    // The dashboard's offset is clamped so its first reconnect lands inside the
    // window whatever `--mixed-seconds` is; the mobile keeps its own offset,
    // which is earlier than the dashboard's for a window of 40 s or more. A
    // `--mixed-seconds` too short for the mobile to reconnect at all (20 s or
    // less) is rejected by the orchestrator's validation, not hidden here.
    const dashboardReconnectOffsetMs = Math.min(config.dashboardReconnectOffsetSeconds, config.mixedSeconds / 2) * 1000;
    const pause = (intervalMs, cycleStart, deadline) => sleep(Math.max(0, Math.min(intervalMs - (now() - cycleStart), deadline - now())));
    // Lists and reconnects run on separate devices. The Gateway admits one
    // session.open per connection, so the open lanes already work this way; a
    // single `session.list` can also outlast the whole mixed window on `main`,
    // and the dashboard's scheduled reconnect must not be starved by it.
    const dashboardLoop = async (start, deadline) => {
      while (now() < deadline) {
        const cycleStart = now();
        await timed("sessionList", () => retrying(dashboard, "session.list", { limit: 500, scope: "user" }));
        await pause(config.listIntervalMs, cycleStart, deadline);
      }
    };
    const reconnecting = await connect("dashboard-reconnect", tokens["dashboard-reconnect"]);
    const dashboardReconnectLane = async (start, deadline) => {
      for (let reconnectAt = start + dashboardReconnectOffsetMs; reconnectAt < deadline; reconnectAt += reconnectMs) {
        await sleep(Math.max(0, reconnectAt - now()));
        await timed("reconnectReadyDashboard", async () => {
          await reconnecting.reconnect();
          await retrying(reconnecting, "session.list", { limit: 500, scope: "user" });
        });
      }
    };
    const mobileLoop = async (start, deadline) => {
      for (let reconnectAt = start + config.mobileReconnectOffsetSeconds * 1000; reconnectAt < deadline; reconnectAt += reconnectMs) {
        await sleep(Math.max(0, reconnectAt - now()));
        await timed("reconnectReadyMobile", async () => {
          await mobile.reconnect();
          await retryingBusy(retries, "mount", () => chat.remount(measured));
        });
      }
    };
    const warm = await connect("warm", tokens.warm);
    const large = await connect("large", tokens.large);
    const openClose = async (client, kind, sessionId) => {
      const opened = await timed(kind, () => retrying(client, "session.open", { sessionId }));
      await client.request("session.close", { sessionId, subscriptionToken: opened.subscriptionToken }, measured);
    };
    // Largest first, so the 200 MiB worst case is measured however few fit.
    const largeLane = async (start, deadline) => {
      for (const { sessionId } of [...config.large].reverse()) {
        if (now() >= deadline) break;
        await openClose(large, "sessionOpenColdLarge", sessionId);
      }
    };
    const warmLane = async (start, deadline) => {
      for (let turn = 0; now() < deadline; turn += 1) {
        const cycleStart = now();
        await openClose(warm, "sessionOpenWarm", config.running[turn % config.running.length].sessionId);
        await pause(config.proberIntervalMs, cycleStart, deadline);
      }
    };
    const coldLane = async (start, deadline) => {
      for (const { sessionId } of config.cold) {
        if (now() >= deadline) break;
        const cycleStart = now();
        const opened = await timed("sessionOpenCold", () => retrying(driver, "session.open", { sessionId }));
        // The model selection and the prompt admission are measured workload
        // too: started after the deadline the prompt would be timed while every
        // other lane has stopped (biased low) and censored with an elapsed time
        // under the tail, not the tail's own length.
        if (now() < deadline) {
          await mutation(driver, "session.setModel", { sessionId, provider: "tron-profile", modelId: "profile-model" });
          if (now() < deadline) {
            await timed("promptAdmission", () => mutation(driver, "session.prompt", { sessionId, text: config.coldPrompt }));
          }
        }
        await driver.request("session.close", { sessionId, subscriptionToken: opened.subscriptionToken }, measured);
        await pause(config.proberIntervalMs, cycleStart, deadline);
      }
    };
    // The mixed window is fixed-length: it closes at `mixedSeconds` even when a
    // lane is mid-operation, so window totals (frames, bytes, CPU time, catalog
    // walks) do not scale with the fixture's latency and two runs can agree.
    result.mixed = await measuredWindow("mixed", [driver, dashboard, mobile, warm, large, reconnecting],
      ["mobile", "dashboard"],
      async (start) => {
        const deadline = start + config.mixedSeconds * 1000;
        // Every lane starts at once; operations still in flight at the deadline
        // finish in the window's bounded tail.
        await Promise.all([dashboardLoop(start, deadline), dashboardReconnectLane(start, deadline),
          mobileLoop(start, deadline), largeLane(start, deadline), warmLane(start, deadline),
          coldLane(start, deadline)]);
      }, { fixedSeconds: config.mixedSeconds, tailGraceSeconds: config.tailGraceMs / 1000, abandonInflight });
    // The tail is the last moment an operation may be censored into the
    // samples: from here on a lane that settles late is no longer measured, and
    // the copy below fixes the set the result reports.
    measuring = false;
    result.samples = Object.fromEntries(Object.entries(samples).map(([kind, values]) => [kind, [...values]]));
    result.runningPhases = config.running.map(({ sessionId }) => phases.get(sessionId) ?? null);
    result.mobileOutcome = chat.outcome();
    result.appendedEntries = await appender.stop();
    appender = null;
    for (const client of clients) {
      if (client.closedUnexpectedly) fail(`${client.name} ${client.closedUnexpectedly}`);
    }
    writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
  } finally {
    for (const chat of chats) clearInterval(chat.renewal);
    if (appender) await appender.stop().catch(() => {});
    for (const client of clients) await client.close();
    // A lane abandoned by the mixed window's tail can restore a mounted chat
    // while its socket closes; nothing may keep the driver process alive after
    // every client is closed.
    for (const chat of chats) clearInterval(chat.renewal);
    await new Promise((resolveFlush) => timelineStream.end(resolveFlush));
  }
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
  else if (command === "catalog") generateCatalog();
  else if (command === "multi") await multi();
  else await main();
} catch (error) {
  process.stderr.write(`error: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(1);
}
