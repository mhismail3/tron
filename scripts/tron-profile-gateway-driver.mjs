#!/usr/bin/env node
// Workload and recording clients for scripts/tron-profile-gateway.
import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import {
  closeSync, createWriteStream, mkdirSync, openSync, readFileSync, readSync, fstatSync, rmSync, writeFileSync, writeSync,
} from "node:fs";
import { appendFile } from "node:fs/promises";
import { PathRelay } from "./tron-profile-relay.mjs";
import { createRequire } from "node:module";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

function profileModelChange(sessionId, session) {
  return {
    target: { kind: "session", sessionId },
    fence: { runtimeGeneration: session.runtimeGeneration, model: session.model ?? null },
    changes: [{ key: "model.ref[role=chat]", layer: "chat", op: "set", value: { provider: "tron-profile", id: "profile-model" } }],
  };
}

const PRESENTATION_LEASE_RENEWAL_MS = 15_000;
const REQUEST_TIMEOUT_MS = 30_000;
const PROTOCOL_VERSION = 8;
const PHONE_RETRY_INITIAL_SECONDS = 2;
const PHONE_RETRY_MULTIPLIER = 1.7;
const PHONE_RETRY_MAXIMUM_SECONDS = 15;
const PHONE_RETRY_JITTER_FRACTION = 0.2;

const [command, configPath] = process.argv.slice(2);
if (!["seed", "run", "catalog", "multi"].includes(command) || !configPath) {
  process.stderr.write("usage: tron-profile-gateway-driver.mjs seed|run|catalog|multi CONFIG.json\n");
  process.exit(2);
}
const config = JSON.parse(readFileSync(configPath, "utf8"));
const CONNECTION_CONTRACT = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)),
  "..", "packages", "protocol-fixtures", "gateway-connection-contract.json"), "utf8"));
const CONNECTION = {
  pingIntervalMs: CONNECTION_CONTRACT.clientPingInterval.milliseconds,
  pongDeadlineMs: CONNECTION_CONTRACT.clientPongDeadline.milliseconds,
  transportOpenDeadlineMs: CONNECTION_CONTRACT.clientTransportOpenDeadline.milliseconds,
  helloDeadlineMs: CONNECTION_CONTRACT.clientHelloDeadline.milliseconds,
  ...(config.connection ?? {}),
};
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

function cancellableSleep(ms) {
  let timer;
  const done = new Promise((resolveSleep) => { timer = setTimeout(resolveSleep, ms); });
  return { done, cancel: () => clearTimeout(timer) };
}

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

const MIB = 1024 * 1024;
const CATALOG_SCHEMA = "tron.profile-gateway-catalog.v1";
const CATALOG_SESSION_SHARE = 225 / 3000;
const CATALOG_FORK_SHARE = 460 / 3000;
const CATALOG_REFERENCE_BYTES = 2048 * MIB;
const LARGE_SESSION_MIB = [100, 125, 150, 175, 200];
const MINIMUM_FILE_BYTES = 4 * 1024;
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
    this.bytes += text.length + 1;
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
    this.lastInboundAt = 0;
    this.pongDeadlineMisses = 0;
    this.unexpectedCloses = 0;
    this.pingsOutstanding = [];
    this.pongRoundTripMsMax = 0;
    this.pongsCounted = 0;
    this.openResponseBytes = 0;
    this.inboundDecodedBytes = 0;
    this.relay = null;
    this.requestTally = null;
    this.retired = false;
    this.clientId = randomUUID();
    this.presentationOpenSerial = 0;
  }

  async connect() {
    const WebSocket = gatewayRequire("ws");
    this.closing = false;
    this.awaitingPong = null;
    this.presentationOpenSerial = 0;
    this.pingsOutstanding.length = 0;
    const transportOpenDeadlineAt = now() + CONNECTION.transportOpenDeadlineMs;
    const remainingTransportOpenMs = () => Math.max(0, transportOpenDeadlineAt - now());
    const socket = new WebSocket(`ws://127.0.0.1:${this.relay ? this.relay.port : config.port}/v1/socket`, {
      headers: { Authorization: `Bearer ${this.token}` },
      perMessageDeflate: { clientMaxWindowBits: false },
      autoPong: false,
      handshakeTimeout: CONNECTION.transportOpenDeadlineMs + 1_000,
      maxPayload: 64 * 1024 * 1024,
    });
    this.socket = socket;
    socket.on("upgrade", (response) => {
      this.tcp = response.socket;
      this.offeredExtensions = socket._req?.getHeader("sec-websocket-extensions") ?? null;
      this.negotiatedExtensions = response.headers["sec-websocket-extensions"] ?? "";
    });
    socket.on("ping", (data) => {
      this.note("in", "control:ping", data.length);
      if (socket.readyState === 1) socket.pong(data);
      if (this.window) this.window.pongsSent += 1;
      this.timeline.write({ t: now(), client: this.name, label: this.label, dir: "out", topic: "control:pong", bytes: data.length });
    });
    socket.on("pong", (data) => {
      const sentAt = this.pingsOutstanding.shift() ?? null;
      if (sentAt !== null) {
        this.pongRoundTripMsMax = Math.max(this.pongRoundTripMsMax, now() - sentAt);
        this.pongsCounted += 1;
      }
      this.awaitingPong = null;
      this.note("in", "control:pong", data.length);
    });
    socket.on("message", (data, isBinary) => this.onMessage(data, isBinary));
    socket.on("close", (code, reason) => {
      if (socket !== this.socket) return;
      clearInterval(this.pingTimer);
      this.pingTimer = null;
      if (!this.closing) {
        this.closedUnexpectedly = `closed ${code} ${reason.toString()}`;
        this.unexpectedCloses += 1;
      }
      if (this.helloReject) {
        const rejectHello = this.helloReject;
        this.helloWaiter = null;
        this.helloReject = null;
        rejectHello(new Error(`${this.name} socket closed during hello (${code})`));
      }
      for (const { reject } of this.pending.values()) reject(new Error(`${this.name} socket closed (${code})`));
      this.pending.clear();
    });
    await withDeadline(new Promise((resolveOpen, rejectOpen) => {
      socket.once("open", resolveOpen);
      socket.once("error", rejectOpen);
      socket.once("unexpected-response", (_, response) => rejectOpen(new Error(`upgrade rejected with HTTP ${response.statusCode}`)));
    }), remainingTransportOpenMs(), `${this.name} WebSocket open`);
    if (this.offeredExtensions !== "permessage-deflate") {
      fail(`${this.name} offered ${JSON.stringify(this.offeredExtensions)}, not the phone's parameterless permessage-deflate`);
    }
    if (!this.tcp) fail(`${this.name}: the upgrade exposed no TCP socket to count wire bytes`);
    const helloDeadlineAt = now() + CONNECTION.helloDeadlineMs;
    const remainingHelloMs = () => Math.max(0, helloDeadlineAt - now());
    const hello = new Promise((resolveHello, rejectHello) => { this.helloWaiter = resolveHello; this.helloReject = rejectHello; });
    this.send({ type: "hello", protocolVersion: PROTOCOL_VERSION, clientId: this.clientId, clientRole: "mobile" });
    this.info = await withDeadline(hello, remainingHelloMs(), `${this.name} hello`);
    if (this.info.protocolVersion !== PROTOCOL_VERSION) fail(`${this.name}: Gateway protocol ${this.info.protocolVersion} is not ${PROTOCOL_VERSION}`);
    this.pingTimer = setInterval(() => this.clientPing(), CONNECTION.pingIntervalMs);
  }

  clientPing() {
    if (this.socket?.readyState !== 1) return;
    if (this.awaitingPong && now() - this.awaitingPong > CONNECTION.pongDeadlineMs) {
      this.pongDeadlineMisses += 1;
      if (this.window) this.window.pongDeadlineMisses += 1;
    }
    this.awaitingPong = now();
    this.pingsOutstanding.push(this.awaitingPong);
    if (this.socket.readyState === 1) this.socket.ping();
    if (this.window) this.window.pingsSent += 1;
    this.timeline.write({ t: now(), client: this.name, label: this.label, dir: "out", topic: "control:ping", bytes: 0 });
  }

  beginPongWindow() {
    this.pongRoundTripMsMax = 0;
    this.pingsOutstanding.length = 0;
  }

  note(dir, topic, bytes) {
    if (dir === "in") this.lastInboundAt = now();
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
    this.inboundDecodedBytes += bytes;
    let frame;
    try { frame = JSON.parse(buffer.toString("utf8")); } catch { frame = { type: isBinary ? "binary" : "invalid" }; }
    let topic;
    if (frame.type === "event") topic = String(frame.topic);
    else if (frame.type === "response") topic = `response:${this.pending.get(frame.id)?.method ?? "unknown"}`;
    else topic = String(frame.type);
    this.lastFrameAt = now();
    this.lastInboundAt = this.lastFrameAt;
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
      process.stderr.write(`${this.name} ${this.label} ${topic}: ${JSON.stringify(frame.payload).slice(0, 2_000)}\n`);
    }
    if (topic === "response:session.open") this.openResponseBytes += bytes;
    if (frame.type === "hello" && this.helloWaiter) {
      const resolveHello = this.helloWaiter;
      this.helloWaiter = null;
      this.helloReject = null;
      resolveHello(frame);
      return;
    }
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

  request(method, params = {}, deadlineMs = REQUEST_TIMEOUT_MS, requestID = randomUUID()) {
    if (this.socket?.readyState !== 1) return Promise.reject(new Error(`${this.name} ${method}: socket not open`));
    const id = requestID;
    const promise = new Promise((resolveRequest, rejectRequest) => {
      this.pending.set(id, { method, resolve: resolveRequest, reject: rejectRequest });
    });
    if (this.requestTally) {
      const entry = { client: this.name, method, startedAtMs: Date.now(), startedAt: now() };
      this.requestTally.push(entry);
      promise.then(
        () => { entry.ms = now() - entry.startedAt; },
        (error) => { entry.ms = now() - entry.startedAt; entry.failed = messageOf(error); });
    }
    this.send({ type: "request", id, method, params });
    return withDeadline(promise, deadlineMs, `${this.name} ${method}`);
  }

  async openPresentation(sessionId, deadlineMs = REQUEST_TIMEOUT_MS) {
    const serial = (this.presentationOpenSerial += 1);
    const id = randomUUID();
    const opened = await this.request("session.open", { sessionId }, deadlineMs, id);
    if (this.presentationOpenSerial === serial) return { opened, superseded: false };
    this.send({ type: "cancel", id });
    return { opened, superseded: true };
  }

  async reconnect() {
    await this.disconnect();
    if (this.retired) throw new Error(`${this.name} reconnected after it was closed`);
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
    this.pingsOutstanding.length = 0;
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

  async abandon() {
    this.closing = true;
    clearInterval(this.pingTimer);
    this.pingTimer = null;
    const socket = this.socket;
    this.socket = null;
    this.awaitingPong = null;
    this.pingsOutstanding.length = 0;
    this.helloWaiter = null;
    this.helloReject = null;
    if (socket && socket.readyState !== 3) socket.terminate();
    for (const { reject } of this.pending.values()) reject(new Error(`${this.name} abandoned`));
    this.pending.clear();
  }

  async attachRelay(relay) {
    await this.abandon();
    this.relay = relay;
  }

  expectClosure() {
    this.closedUnexpectedly = null;
  }

  async disconnect() {
    this.closing = true;
    clearInterval(this.pingTimer);
    this.pingTimer = null;
    const socket = this.socket;
    if (!socket) return;
    if (socket.readyState === 1) {
      socket.close(1000, "profile complete");
      await withDeadline(new Promise((resolveClose) => socket.once("close", resolveClose)), 3_000, `${this.name} close`)
        .catch(() => socket.terminate());
    } else {
      socket.terminate();
    }
  }

  async close() {
    this.retired = true;
    await this.disconnect();
  }
}

class MountedChat {
  constructor(client, sessionId) {
    this.client = client;
    this.sessionId = sessionId;
    this.revision = 0;
  }

  async open(deadlineMs = REQUEST_TIMEOUT_MS) {
    const attempt = await this.client.openPresentation(this.sessionId, deadlineMs);
    const opened = attempt.opened;
    if (opened?.session?.sessionId !== this.sessionId) fail(`session.open returned ${opened?.session?.sessionId}`);
    this.token = opened.subscriptionToken;
    this.openSnapshot = opened.session;
    this.latest = opened.session;
    this.cursor = { generation: opened.session.runtimeGeneration, sequence: opened.session.eventSequence };
    this.sequenceGaps = 0;
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
    if (attempt.superseded) {
      this.client.listeners.delete(this.listener);
      return opened;
    }
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

  remount(deadlineMs) {
    clearInterval(this.renewal);
    this.client.listeners.delete(this.listener);
    const gaps = this.sequenceGaps ?? 0;
    return this.open(deadlineMs).then((opened) => {
      this.sequenceGaps += gaps;
      this.renewalError = null;
      return opened;
    });
  }

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
    return null;
  }
}

async function pair(deviceName, previousCode) {
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

const APPENDED_TEXT = prose(generator(11), 900);
const MULTI_DEVICES = ["mobile", "dashboard", "dashboard-reconnect", "driver", "warm", "large"];
const BUSY_RETRY_DELAY_MS = 250;
const BUSY_RETRY_LIMIT = 40;

const CATALOG_READY_DEADLINE_MS = 90_000;

async function retryingBusy(retries, method, operation, deadlineMs = null) {
  const deadline = deadlineMs === null ? null : now() + deadlineMs;
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      const exhausted = deadline === null ? attempt >= BUSY_RETRY_LIMIT : now() >= deadline;
      if (error?.gatewayError?.retryable !== true || exhausted) throw error;
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

async function probeSnapshot() {
  const previous = readProbe()?.sequence ?? 0;
  process.kill(config.gatewayPid, "SIGUSR2");
  const deadline = now() + config.measuredDeadlineMs;
  for (;;) {
    const snapshot = readProbe();
    if (snapshot && snapshot.sequence > previous) return snapshot;
    if (now() > deadline) fail(`the fixture probe did not answer SIGUSR2 within ${config.measuredDeadlineMs} ms`);
    await sleep(25);
  }
}

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
    const laneFailure = lanes.then(() => null, (error) => ({ error }));
    const settled = await Promise.race([
      sleep(Math.max(0, start + fixedSeconds * 1000 - now())).then(() => null), laneFailure]);
    if (settled !== null) throw settled.error;
  }
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
    const tail = cancellableSleep(tailGraceSeconds * 1000);
    let expired = false;
    try {
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

function messageOf(error) {
  return String(error instanceof Error ? error.message : error);
}

const RESTART_MEASURED_CLIENTS = ["mobile", "dashboard", "driver"];

function phoneRetryDelayMs(failures) {
  let nominal = PHONE_RETRY_INITIAL_SECONDS;
  for (let index = 1; index < Math.max(1, failures); index += 1) {
    if (nominal >= PHONE_RETRY_MAXIMUM_SECONDS) break;
    nominal = Math.min(nominal * PHONE_RETRY_MULTIPLIER, PHONE_RETRY_MAXIMUM_SECONDS);
  }
  const lower = nominal * (1 - PHONE_RETRY_JITTER_FRACTION);
  const upper = Math.min(nominal * (1 + PHONE_RETRY_JITTER_FRACTION), PHONE_RETRY_MAXIMUM_SECONDS);
  return (lower + (upper - lower) * Math.random()) * 1000;
}

async function waitForJson(path, deadlineMs, what) {
  const deadline = now() + deadlineMs;
  for (;;) {
    try {
      return JSON.parse(readFileSync(path, "utf8"));
    } catch {
      if (now() > deadline) fail(`timed out after ${deadlineMs} ms waiting for ${what}`);
      await sleep(50);
    }
  }
}

function waitForClosure(client, timeoutMs) {
  return withDeadline(new Promise((resolveClosed) => {
    const socket = client.socket;
    if (!socket || socket.readyState === 3) { setImmediate(() => resolveClosed(Date.now())); return; }
    socket.once("close", () => resolveClosed(Date.now()));
  }), timeoutMs, `${client.name} socket close`);
}

async function phoneBackoffWait(ms, signal = null) {
  if (!signal) { await sleep(ms); return false; }
  const wait = cancellableSleep(ms);
  try {
    return await Promise.race([wait.done.then(() => false), signal.then(() => true)]);
  } finally {
    wait.cancel();
  }
}

async function connectUntilReady(client, ready, deadlineMs, annotate = () => ({}), pathChange = null) {
  const attempts = [];
  let failures = 1;
  let waitMs = null;
  for (;;) {
    const startedAt = now();
    const annotations = annotate();
    try {
      await client.connect();
      await ready();
      attempts.push({ ms: now() - startedAt, waitMs, connected: true, ...annotations });
      return attempts;
    } catch (error) {
      attempts.push({ ms: now() - startedAt, waitMs, failed: messageOf(error), ...annotations });
      await client.abandon();
      if (now() > deadlineMs) fail(`${client.name} did not recover within ${Math.round(deadlineMs - startedAt)} ms: ${messageOf(error)}`);
      const returnedAt = pathChange === null ? null : pathChange.returnedAt();
      if (returnedAt !== null && returnedAt >= startedAt) {
        failures = 1;
        waitMs = 0;
        continue;
      }
      const waitStartedAt = now();
      const cancelled = returnedAt === null
        && await phoneBackoffWait(phoneRetryDelayMs(failures), pathChange?.signal ?? null);
      waitMs = cancelled ? 0 : now() - waitStartedAt;
      failures = cancelled ? 1 : failures + 1;
    }
  }
}

async function relayFor(config, mobile) {
  if (mobile.relay) return mobile.relay;
  const relay = new PathRelay(config.port, now);
  await relay.listen();
  await mobile.attachRelay(relay);
  await mobile.connect();
  return relay;
}

async function blackholeLeg(config, { mobile, chat, retry }) {
  const leg = { seconds: config.blackholeSeconds, settleMs: config.blackholeSettleMs, abandonedOnMiss: null,
    silenceMs: null, pathReturnedAtMs: null, recoveryReadyMs: null, attempts: [] };
  const relay = await relayFor(config, mobile);
  await retry("mount", () => chat.remount(config.measuredDeadlineMs));
  await sleep(config.blackholeSettleMs);
  const missesBefore = mobile.pongDeadlineMisses;
  const outageStart = now();
  const outageEnd = outageStart + config.blackholeSeconds * 1000;
  let returnedAt = null;
  let signalPathReturn;
  const pathReturned = new Promise((resolvePathReturn) => { signalPathReturn = resolvePathReturn; });
  const returnTimer = setTimeout(() => {
    relay.blackhole(false);
    returnedAt = now();
    leg.pathReturnedAtMs = Date.now();
    signalPathReturn();
  }, config.blackholeSeconds * 1000);
  returnTimer.unref?.();
  try {
    relay.blackhole(true);
    const quietUntil = Math.min(outageEnd, outageStart
      + CONNECTION.pingIntervalMs * 2 + CONNECTION.pongDeadlineMs + config.blackholeSettleMs);
    while (mobile.pongDeadlineMisses === missesBefore && now() < quietUntil) await sleep(25);
    leg.abandonedOnMiss = mobile.pongDeadlineMisses > missesBefore;
    leg.silenceMs = now() - mobile.lastInboundAt;
    await mobile.abandon();
    leg.attempts = await connectUntilReady(mobile,
      () => retry("mount", () => chat.remount(config.measuredDeadlineMs)),
      outageEnd + config.measuredDeadlineMs,
      () => ({ duringOutage: returnedAt === null }),
      { returnedAt: () => returnedAt, signal: pathReturned });
  } finally {
    clearTimeout(returnTimer);
  }
  if (returnedAt === null) fail("the blackhole path never returned");
  leg.recoveryReadyMs = now() - returnedAt;
  leg.attemptsDuringOutage = leg.attempts.filter((attempt) => attempt.duringOutage).length;
  return leg;
}

function streamTargets(config, mountedSessionId) {
  const targets = [];
  for (const entry of config.running ?? []) {
    const sessionId = entry?.sessionId;
    if (typeof sessionId !== "string" || sessionId === mountedSessionId || targets.includes(sessionId)) continue;
    targets.push(sessionId);
  }
  return targets;
}

function pageTargets(config, mountedSessionId) {
  const targets = [];
  const pool = [...(config.cold ?? []), ...(config.large ?? []), ...(config.running ?? [])];
  for (const entry of pool) {
    const sessionId = entry?.sessionId;
    if (typeof sessionId !== "string" || sessionId === mountedSessionId || targets.includes(sessionId)) continue;
    targets.push(sessionId);
  }
  return targets;
}

async function bandwidthStreamLeg(config, { mobile, chat, retry }) {
  const relay = await relayFor(config, mobile);
  await retry("mount", () => chat.remount(config.measuredDeadlineMs));
  const missesBefore = mobile.pongDeadlineMisses;
  const closesBefore = mobile.unexpectedCloses;
  const downBefore = relay.downBytes;
  const decodedBefore = mobile.inboundDecodedBytes;
  const streams = [];
  for (const sessionId of streamTargets(config, chat.sessionId).slice(0, config.bandwidthStreamSessions)) {
    const streamChat = new MountedChat(mobile, sessionId);
    try {
      await retry("mount", () => streamChat.open(config.bandwidthStreamAttachDeadlineMs));
      streams.push(streamChat);
    } catch (error) {
      if (mobile.socket?.readyState !== 1 && !mobile.closedUnexpectedly) {
        await waitForClosure(mobile, config.measuredDeadlineMs);
      }
      if (mobile.socket?.readyState !== 1 && !mobile.closedUnexpectedly) throw error;
      await streamChat.close().catch(() => {});
      if (mobile.closedUnexpectedly) break;
    }
  }
  const capBitsPerSecond = Math.round(config.bandwidthStreamMbps * 1_000_000);
  const startedAtMs = Date.now();
  mobile.beginPongWindow();
  const pongsBefore = mobile.pongsCounted;
  relay.cap(capBitsPerSecond);
  const startedAt = now();
  const legEnd = startedAt + config.bandwidthStreamSeconds * 1000;
  while (now() < legEnd && !mobile.closedUnexpectedly) await sleep(100);
  const seconds = (now() - startedAt) / 1000;
  const deliveredBytes = relay.downBytes - downBefore;
  const decodedBytes = mobile.inboundDecodedBytes - decodedBefore;
  relay.cap(0);
  for (const streamChat of streams) await streamChat.close().catch(() => {});
  return {
    capBitsPerSecond, seconds, startedAtMs, endedAtMs: Date.now(), streams: streams.length + 1,
    deliveredBytes, deliveredBytesPerSecond: deliveredBytes / seconds,
    payloadBytes: decodedBytes, payloadBytesPerSecond: decodedBytes / seconds,
    linkUse: (deliveredBytes / seconds) / (capBitsPerSecond / 8),
    maxPingToPongMs: mobile.pongsCounted > pongsBefore ? mobile.pongRoundTripMsMax : null,
    uncappedPingToPongMs: config.uncappedPingToPongMs ?? null,
    pongDeadlineMisses: mobile.pongDeadlineMisses - missesBefore,
    unexpectedCloses: mobile.unexpectedCloses - closesBefore,
  };
}

async function bandwidthLeg(config, { mobile, chat, retry }) {
  const relay = await relayFor(config, mobile);
  const missesBefore = mobile.pongDeadlineMisses;
  const closesBefore = mobile.unexpectedCloses;
  const upBefore = relay.upBytes;
  const downBefore = relay.downBytes;
  const openBytesBefore = mobile.openResponseBytes;
  const capBitsPerSecond = Math.round(config.bandwidthMbps * 1_000_000);
  const startedAtMs = Date.now();
  mobile.beginPongWindow();
  const pongsBefore = mobile.pongsCounted;
  relay.cap(capBitsPerSecond);
  const startedAt = now();
  const operations = [];
  let closedEarly = false;
  let stopped = false;
  let failure = null;
  let inFlight = 0;
  let maxInFlight = 0;
  const legEnd = startedAt + config.bandwidthLegSeconds * 1000;
  const extras = pageTargets(config, chat.sessionId).slice(0, Math.max(1, config.bandwidthInFlight))
    .map((sessionId) => new MountedChat(mobile, sessionId));
  const lanes = extras.length > 0 ? extras : [chat];
  const runLane = async (laneChat) => {
    try {
      while (!stopped && now() < legEnd) {
        const operationStart = now();
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        try {
          await retry("mount", () => laneChat.remount(config.measuredDeadlineMs));
        } catch (error) {
          if (mobile.socket?.readyState !== 1 && !mobile.closedUnexpectedly) {
            await waitForClosure(mobile, config.measuredDeadlineMs);
          }
          if (mobile.socket?.readyState !== 1 && !mobile.closedUnexpectedly) {
            throw new Error(`${mobile.name} socket died under the cap without being counted: ${messageOf(error)}`);
          }
          if (mobile.closedUnexpectedly) { closedEarly = true; stopped = true; return; }
          throw error;
        } finally {
          inFlight -= 1;
        }
        operations.push(now() - operationStart);
      }
    } catch (error) {
      stopped = true;
      failure ??= error;
    }
  };
  await Promise.all(lanes.map((laneChat) => runLane(laneChat)));
  const seconds = (now() - startedAt) / 1000;
  const deliveredBytes = relay.downBytes - downBefore;
  const pageBytes = mobile.openResponseBytes - openBytesBefore;
  relay.cap(0);
  for (const extra of extras) await extra.close().catch(() => {});
  if (failure !== null) throw failure;
  const meanPageWireBytes = operations.length > 0 ? deliveredBytes / operations.length : 0;
  const meanPageDecodedBytes = operations.length > 0 ? pageBytes / operations.length : 0;
  return {
    capBitsPerSecond, seconds, operations, closedEarly, startedAtMs, endedAtMs: Date.now(),
    deliveredBytes, deliveredBytesPerSecond: deliveredBytes / seconds,
    sentBytes: relay.upBytes - upBefore,
    linkUse: (deliveredBytes / seconds) / (capBitsPerSecond / 8),
    maxInFlight,
    offeredInFlightBytes: maxInFlight * meanPageDecodedBytes,
    offeredInFlightWireBytes: maxInFlight * meanPageWireBytes,
    maxPingToPongMs: mobile.pongsCounted > pongsBefore ? mobile.pongRoundTripMsMax : null,
    pongDeadlineMisses: mobile.pongDeadlineMisses - missesBefore,
    unexpectedCloses: mobile.unexpectedCloses - closesBefore,
  };
}

async function restartLeg(config, clients, retryMethod, measuredNames) {
  const requestPath = join(config.outputDir, `restart-request-${config.label}.json`);
  const donePath = join(config.outputDir, `restart-done-${config.label}.json`);
  rmSync(donePath, { force: true });
  const requestedAtMs = Date.now();
  const closedAt = new Map();
  const closures = clients.map(({ client }) => waitForClosure(client, config.restartDeadlineMs)
    .then((atMs) => { closedAt.set(client.name, atMs); }));
  for (const { name, client } of clients) {
    if (measuredNames.includes(name)) client.requestTally = [];
  }
  writeFileSync(requestPath, `${JSON.stringify({ requestedAtMs, gatewayPid: config.gatewayPid })}\n`);
  const ready = Promise.all(clients.map(async ({ name, client, ready: prepare }, index) => {
    await closures[index];
    client.expectClosure();
    const attempts = await connectUntilReady(client, prepare, now() + config.restartDeadlineMs);
    const readyAtMs = Date.now();
    const stormEnd = now() + config.restartStormSeconds * 1000;
    while (measuredNames.includes(name) && now() < stormEnd) {
      const cycleStart = now();
      await retryMethod("list", () => client.request("session.list", { limit: 500, scope: "user" }, config.measuredDeadlineMs));
      await sleep(Math.max(0, 1_000 - (now() - cycleStart)));
    }
    return { name, readyAtMs, attempts, closedAtMs: closedAt.get(name), reconnectMs: readyAtMs - closedAt.get(name) };
  }));
  const [results, restored] = await Promise.all([
    ready, waitForJson(donePath, config.restartDeadlineMs, "the profiler's Gateway restart"),
  ]);
  const measured = results.filter((entry) => measuredNames.includes(entry.name));
  const requests = [];
  for (const { name, client } of clients) {
    if (!measuredNames.includes(name)) continue;
    for (const entry of client.requestTally ?? []) {
      if (entry.ms === undefined) continue;
      requests.push({ client: name, ms: entry.ms, sinceRestoreMs: entry.startedAtMs - restored.restoredAtMs,
        duringDowntime: entry.failed !== undefined && entry.failed !== null, failed: entry.failed ?? null });
    }
    client.requestTally = null;
  }
  requests.sort((left, right) => left.sinceRestoreMs - right.sinceRestoreMs);
  for (const { client } of clients) client.expectClosure();
  return {
    requestedAtMs, restoredAtMs: restored.restoredAtMs, restoredPid: restored.pid,
    downtimeMs: restored.restoredAtMs - requestedAtMs,
    startup: restored.startup ?? null,
    clients: measured, clientsAll: results, requests,
  };
}

async function impairmentLegs(config, context) {
  const legs = context.legs;
  const recoverCountedCloses = async (nextCase) => {
    const closed = context.all.filter((client) => client.closedUnexpectedly);
    if (closed.length === 0) return;
    const counted = Object.values(legs).reduce((total, leg) => total + (leg.unexpectedCloses ?? 0), 0);
    if (counted === 0) {
      context.persist();
      fail(`${closed[0].name} ${closed[0].closedUnexpectedly} before the ${nextCase} case`);
    }
    for (const client of closed) {
      context.closedByCases.push(`${client.name} ${client.closedUnexpectedly}`);
      client.expectClosure();
      await client.connect();
      if (client === context.mobile) {
        await context.retry("mount", () => context.chat.remount(config.measuredDeadlineMs));
      }
    }
  };
  for (const name of config.cases) {
    await recoverCountedCloses(name);
    if (name === "blackhole") legs.blackhole = await blackholeLeg(config, context);
    else if (name === "bandwidth") legs.bandwidth = await bandwidthLeg(config, context);
    else if (name === "bandwidth-stream") legs["bandwidth-stream"] = await bandwidthStreamLeg(config, context);
    else if (name === "restart") {
      legs.restart = await restartLeg(config, context.clients, context.retry, RESTART_MEASURED_CLIENTS);
      for (const client of context.all) client.expectClosure();
    } else fail(`unknown impairment case ${name}`);
    context.persist();
  }
  return legs;
}

async function multi() {
  config.cases ??= [];
  mkdirSync(config.outputDir, { recursive: true });
  const timelineStream = createWriteStream(join(config.outputDir, "timeline.jsonl"), { flags: "a" });
  const timeline = { write: (record) => timelineStream.write(`${JSON.stringify(record)}\n`) };
  const clients = [];
  const chats = [];
  let appender = null;
  const measured = config.measuredDeadlineMs;
  const result = { schema: "tron.profile-gateway-multi.v1", phase: config.phase, label: config.label, cases: config.cases };
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
      const primeRetries = {};
      let started = now();
      const listed = await retryingBusy(primeRetries, "session.list", async () => {
        started = now();
        return await dashboard.request("session.list", { limit: 500, scope: "user" }, measured);
      }, CATALOG_READY_DEADLINE_MS);
      result.list = { ms: now() - started, rows: listed?.sessions?.length ?? null,
        busyRetries: primeRetries["session.list"] ?? 0 };
      writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
      return;
    }

    const tokens = JSON.parse(readFileSync(config.devicesPath, "utf8"));
    const samples = {
      sessionList: [], sessionOpenWarm: [], sessionOpenCold: [], sessionOpenColdLarge: [], promptAdmission: [],
      reconnectReadyMobile: [], reconnectReadyDashboard: [],
    };
    const inflight = new Set();
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

    result.setupPromptMs = [];
    const retries = {};
    result.busyRetries = retries;
    const retrying = (client, method, params) => retryingBusy(retries, method, () => client.request(method, params, measured));
    const mutation = (client, method, params) => {
      const commandId = randomUUID();
      return retrying(client, method, { ...params, commandId });
    };
    for (const { sessionId } of config.running) {
      const opened = await retrying(driver, "session.open", { sessionId });
      await mutation(driver, "settings.change", profileModelChange(sessionId, opened.session));
      started = now();
      await mutation(driver, "session.prompt", { sessionId, text: config.runPrompt });
      result.setupPromptMs.push(now() - started);
      await driver.request("session.close", { sessionId, subscriptionToken: opened.subscriptionToken }, measured);
    }
    await sleep(config.settleBeforeMs);

    appender = startAppender(config.appendTargets, config.appendIntervalMs, config.label);

    result.noSubscriber = await measuredWindow("no-subscriber", [driver, dashboard], ["dashboard"],
      () => sleep(config.noSubscriberSeconds * 1000));

    const mobile = await connect("mobile", tokens.mobile);
    const chat = new MountedChat(mobile, config.running[0].sessionId);
    chats.push(chat);
    await retryingBusy(retries, "mount", () => chat.remount(measured));
    await sleep(config.settleBeforeMs);

    const reconnectMs = config.reconnectIntervalSeconds * 1000;
    const dashboardReconnectOffsetMs = Math.min(config.dashboardReconnectOffsetSeconds, config.mixedSeconds / 2) * 1000;
    const pause = (intervalMs, cycleStart, deadline) => sleep(Math.max(0, Math.min(intervalMs - (now() - cycleStart), deadline - now())));
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
        if (now() < deadline) {
          await mutation(driver, "settings.change", profileModelChange(sessionId, opened.session));
          if (now() < deadline) {
            await timed("promptAdmission", () => mutation(driver, "session.prompt", { sessionId, text: config.coldPrompt }));
          }
        }
        await driver.request("session.close", { sessionId, subscriptionToken: opened.subscriptionToken }, measured);
        await pause(config.proberIntervalMs, cycleStart, deadline);
      }
    };
    result.mixed = await measuredWindow("mixed", [driver, dashboard, mobile, warm, large, reconnecting],
      ["mobile", "dashboard"],
      async (start) => {
        const deadline = start + config.mixedSeconds * 1000;
        await Promise.all([dashboardLoop(start, deadline), dashboardReconnectLane(start, deadline),
          mobileLoop(start, deadline), largeLane(start, deadline), warmLane(start, deadline),
          coldLane(start, deadline)]);
      }, { fixedSeconds: config.mixedSeconds, tailGraceSeconds: config.tailGraceMs / 1000, abandonInflight });
    measuring = false;
    result.samples = Object.fromEntries(Object.entries(samples).map(([kind, values]) => [kind, [...values]]));
    result.runningPhases = config.running.map(({ sessionId }) => phases.get(sessionId) ?? null);
    result.mobileOutcome = chat.outcome();
    result.appendedEntries = await appender.stop();
    appender = null;
    const closedByCases = [];
    result.uncappedPingToPongMs = mobile.pongRoundTripMsMax;
    if (config.cases.length > 0) {
      const ready = (client) => (client === mobile
        ? () => retryingBusy(retries, "mount", () => chat.remount(measured))
        : () => retryingBusy(retries, "list", () => client.request("session.list", { limit: 500, scope: "user" }, measured)));
      const byName = new Map(clients.map((client) => [client.name, client]));
      const restartNames = [...RESTART_MEASURED_CLIENTS,
        ...clients.map((client) => client.name).filter((name) => !RESTART_MEASURED_CLIENTS.includes(name))];
      const legs = {};
      result.impairment = legs;
      await impairmentLegs(config, {
        mobile, chat, all: clients, legs, closedByCases,
        persist: () => writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`),
        retry: (method, operation) => retryingBusy(retries, method, operation),
        clients: restartNames.map((name) => ({ name, client: byName.get(name), ready: ready(byName.get(name)) })),
      });
    }
    writeFileSync(resultPath, `${JSON.stringify(result, null, 2)}\n`);
    if (closedByCases.length > 0) fail(`a capped leg closed ${closedByCases.join("; ")}`);
    for (const client of clients) {
      if (client.closedUnexpectedly) fail(`${client.name} ${client.closedUnexpectedly}`);
    }
  } finally {
    for (const chat of chats) clearInterval(chat.renewal);
    if (appender) await appender.stop().catch(() => {});
    for (const client of clients) await client.close();
    for (const client of clients) client.relay?.close();
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
      await client.request("session.list", { limit: 500, scope: "user" });
      result.clients[name] = {
        offeredExtensions: client.offeredExtensions,
        negotiatedExtensions: client.negotiatedExtensions,
        recorded: name !== "driver",
      };
    }
    result.gateway = { version: byName[wants[0]].info.gatewayVersion, protocolVersion: byName[wants[0]].info.protocolVersion };
    await sleep(config.settleBeforeMs);

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
      await actor.request("settings.change", { ...profileModelChange(sessionId, opened.session), commandId: randomUUID() });
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
