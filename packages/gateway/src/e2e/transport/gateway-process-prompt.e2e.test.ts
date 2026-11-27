import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { delimiter, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startGatewayProcess, type GatewayProcess, type ProcessClient } from "../../../test-support/gateway-process.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";
import { withoutTurnFrame } from "../../../test-support/turn-frame.js";
import { applyTranscriptDelta } from "../../protocol/transcript-delta.js";
import { decodeSessionTranscriptDelta, type SessionSnapshot } from "../../protocol/types.js";

const gateways: GatewayProcess[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

type Snapshot = { phase: string; operation?: unknown; transcript: Array<Record<string, any>> };

async function openAndSync(client: ProcessClient, sessionId: string): Promise<Snapshot> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  const synced = await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken });
  expect(synced.ok, JSON.stringify(synced)).toBe(true);
  return opened.result.session as Snapshot;
}

async function freshSnapshot(gateway: GatewayProcess, sessionId: string): Promise<Snapshot> {
  const client = await gateway.connect();
  try { return await openAndSync(client, sessionId); } finally { await client.close(); }
}

function messages(snapshot: Snapshot, role: string): string[] {
  return snapshot.transcript.filter((item) => item.kind === "message" && item.role === role)
    .map((item) => (item.content as Array<{ type: string; text?: string }>).filter((part) => part.type === "text")
      .map((part) => part.text).join(""));
}

async function createSession(gateway: GatewayProcess, client: ProcessClient, commandId: string): Promise<string> {
  const created = await client.request("session.create", { commandId, cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  await openAndSync(client, sessionId);
  return sessionId;
}

async function settled(gateway: GatewayProcess, sessionId: string): Promise<Snapshot> {
  return await waitFor(async () => {
    const snapshot = await freshSnapshot(gateway, sessionId);
    return snapshot.phase === "idle" && !snapshot.operation ? snapshot : undefined;
  }, "the session settled idle");
}


type StatedFrame = { topic: string; payload: unknown; bytes: number; transcript: unknown[] };

const bytesOf = (value: unknown) => Buffer.byteLength(JSON.stringify(value));
const itemBytes = (items: readonly unknown[]) => items.reduce<number>((total, item) => total + bytesOf(item), 0);

function replay(base: SessionSnapshot, events: ReadonlyArray<{ topic: string; payload: any }>, tolerateRefusal = false): { snapshot: SessionSnapshot; frames: StatedFrame[]; refused: boolean } {
  let snapshot = base;
  const frames: StatedFrame[] = [];
  for (const event of events) {
    const payload = event.payload;
    if (event.topic === "session.snapshot" || event.topic === "session.rebaseline") {
      const next = (event.topic === "session.rebaseline" ? payload.snapshot : payload) as SessionSnapshot;
      frames.push({ topic: event.topic, payload, bytes: bytesOf(payload), transcript: next.transcript });
      if (next.runtimeGeneration !== snapshot.runtimeGeneration || next.eventSequence > snapshot.eventSequence) snapshot = next;
      continue;
    }
    if (typeof payload?.eventSequence !== "number" || payload.runtimeGeneration !== snapshot.runtimeGeneration
      || payload.eventSequence <= snapshot.eventSequence) continue;
    if (event.topic !== "session.transcriptDelta") {
      snapshot = { ...snapshot, eventSequence: payload.eventSequence };
      continue;
    }
    const delta = decodeSessionTranscriptDelta(payload.data);
    frames.push({ topic: event.topic, payload, bytes: bytesOf(payload), transcript: [...delta.replaced.map(({ item }) => item), ...delta.snapshot.transcript] });
    const applied = applyTranscriptDelta(snapshot, delta);
    if (!applied) {
      if (tolerateRefusal) return { snapshot, frames, refused: true };
      throw new Error(`delta ${payload.eventSequence} does not extend the replayed transcript`);
    }
    snapshot = applied;
  }
  return { snapshot, frames, refused: false };
}

describe("prompt journeys across the real Gateway process", () => {
  it("settles one streamed reply exactly once across fresh-connection reads, a duplicate submit and a process restart (#2230)", async () => {
    const gateway = await startGatewayProcess();
    gateways.push(gateway);
    const prompt = "Reply once to this exact prompt.";
    const head = "PARTIAL-ALPHA ";
    const tail = "OMEGA-COMPLETE.";
    let reach = (): void => {};
    let release = (): void => {};
    const reached = new Promise<void>((resolve) => { reach = resolve; });
    const released = new Promise<void>((resolve) => { release = resolve; });
    let lookupPid: number | undefined;
    gateway.provider.script([() => ({ chunks: [head, async () => { reach(); await released; }, tail] })]);

    try {
      const phone = await gateway.connect();
      const sessionId = await createSession(gateway, phone, "prompt-once-create");
      const admitted = await phone.request("session.prompt", { commandId: "prompt-once-command", sessionId, text: prompt });
      expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
      await awaitsWithin(reached, "the provider streamed its first chunk");
      await waitFor(async () => phone.events.some((event) => event.sessionId === sessionId
        && JSON.stringify(event.payload).includes(head)) || undefined, "the phone saw the partial reply");
      const live = await freshSnapshot(gateway, sessionId);
      expect(live.phase).toBe("running");
      expect((live.operation as { id?: string } | undefined)?.id).toBe(admitted.result.operationId);

      const retried = await phone.request("session.prompt", { commandId: "prompt-once-command", sessionId, text: prompt });
      expect(retried.ok, JSON.stringify(retried)).toBe(true);
      expect(retried.result.operationId).toBe(admitted.result.operationId);
      expect(messages(await freshSnapshot(gateway, sessionId), "user")).toEqual([prompt]);
      release();

      const expectExactlyOnce = (snapshot: Snapshot) => {
        expect(snapshot.phase).toBe("idle");
        expect(snapshot.operation ?? null).toBeNull();
        expect(messages(snapshot, "user")).toEqual([prompt]);
        expect(messages(snapshot, "assistant")).toEqual([head + tail]);
      };
      expectExactlyOnce(await settled(gateway, sessionId));
      expectExactlyOnce(await freshSnapshot(gateway, sessionId));
      const status = await phone.request("command.status", { method: "session.prompt", commandId: "prompt-once-command" });
      expect(status.result).toEqual({ status: "completed", result: { operationId: admitted.result.operationId } });
      const requestLog = (await readFile(join(gateway.tronHome, "logs", "requests.jsonl"), "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line));
      expect(requestLog).toHaveLength(1);
      const sent = JSON.parse(gateway.provider.requests[0]!.body) as Record<string, unknown> & { messages: Array<Record<string, unknown>>; tools?: unknown[] };
      const size = (units: readonly unknown[]) => units.reduce<number>((bytes, unit) => bytes + Buffer.byteLength(JSON.stringify(unit)), 0);
      const toolBytes = size(sent.tools ?? []);
      const messageBytes = size(sent.messages.flatMap((message) => {
        if (!Array.isArray(message.content)) return [message];
        const { content, ...envelope } = message;
        return [envelope, ...content as unknown[]];
      }));
      const { tools: _tools, messages: _messages, ...params } = sent;
      expect(sent.messages.map((message) => message.role)).toEqual(expect.arrayContaining(["system", "user"]));
      expect(toolBytes).toBeGreaterThan(0);
      expect(requestLog[0]).toMatchObject({ sessionId, kind: "ordinary", api: "openai-completions", stop: "stop", marks: [], system: [],
        tools: { bytes: toolBytes }, request: { bytes: toolBytes + messageBytes },
        params: { bytes: Buffer.byteLength(JSON.stringify(Object.fromEntries(Object.entries(params).sort(([left], [right]) => left < right ? -1 : 1)))) } });
      expect(Date.parse(requestLog[0].timestamp)).toBeGreaterThan(0);
      expect(new Set([requestLog[0].tools.hash, requestLog[0].request.hash, requestLog[0].params.hash]).size).toBe(3);
      expect(JSON.stringify(requestLog[0])).not.toContain(prompt);
      const observed = JSON.parse(await readFile(join(gateway.tronHome, "logs", "observations", `${new Date(requestLog[0].timestamp).toISOString().slice(0, 10)}.json`), "utf8"));
      expect(observed.kinds.ordinary).toMatchObject({ requests: 1 });
      expect(JSON.stringify(observed)).not.toContain(prompt);
      await phone.close();

      const normalRestartStarted = performance.now();
      await gateway.restart({ whileStopped: async () => {
        console.info("normal Gateway shutdown ms", performance.now() - normalRestartStarted);
      } });
      console.info("normal Gateway process restart ms", performance.now() - normalRestartStarted);
      expectExactlyOnce(await freshSnapshot(gateway, sessionId));
      expect(gateway.provider.requests).toHaveLength(1);
      expect(withoutTurnFrame(gateway.provider.requests[0]!.messages).filter((message) => message.role === "user")).toHaveLength(1);
      expect(gateway.provider.errors).toEqual([]);

      const bin = join(gateway.root, "bin");
      const pidFile = join(gateway.root, "npm.pid");
      const callers = join(gateway.root, "npm.callers");
      await mkdir(bin);
      await writeFile(join(bin, "npm"), `#!${process.execPath}\nconst fs = require("node:fs"); fs.appendFileSync(${JSON.stringify(callers)}, fs.fstatSync(0).isSocket() ? "async\\n" : "sync\\n"); fs.writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000);\n`, { mode: 0o755 });
      await gateway.restart({ environment: { PATH: `${bin}${delimiter}${process.env.PATH ?? ""}` } });
      expectExactlyOnce(await freshSnapshot(gateway, sessionId));
      lookupPid = await waitFor(async () => {
        try { return Number(await readFile(pidFile, "utf8")) || undefined; } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
          return undefined;
        }
      }, "the real session started its global npm discovery");
      expect((await readFile(callers, "utf8")).split("\n").filter(Boolean)).toEqual(["async"]);
      process.kill(lookupPid, 0);
      const restartStarted = performance.now();
      await gateway.restart({ whileStopped: async () => {
        console.info("npm discovery shutdown join ms", performance.now() - restartStarted);
        assert.throws(() => process.kill(lookupPid!, 0), { code: "ESRCH" });
      } });
      console.info("npm discovery process restart ms", performance.now() - restartStarted);
      expectExactlyOnce(await freshSnapshot(gateway, sessionId));
      expect(gateway.provider.requests).toHaveLength(1);
    } finally {
      release();
      if (lookupPid !== undefined) {
        try { process.kill(lookupPid, "SIGKILL"); } catch (error) {
          // oxlint-disable-next-line no-unsafe-finally -- a cleanup failure must surface even when the guarded block already failed
          if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
        }
      }
    }
  });

  it("an old settings file that says install telemetry on cannot re-enable it: the real SDK sends no attribution header to a provider (D2)", async () => {
    const gateway = await startGatewayProcess({ providerName: "openrouter", settings: { enableInstallTelemetry: true } });
    gateways.push(gateway);
    gateway.provider.script([() => ({ chunks: ["quiet reply"] })]);
    const phone = await gateway.connect();
    try {
      const sessionId = await createSession(gateway, phone, "telemetry-create");
      const admitted = await phone.request("session.prompt", { commandId: "telemetry-prompt", sessionId, text: "Reply quietly." });
      expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
      expect(messages(await settled(gateway, sessionId), "assistant")).toEqual(["quiet reply"]);
    } finally {
      await phone.close();
    }
    expect(gateway.provider.requests).toHaveLength(1);
    const headers = gateway.provider.requests[0]!.headers;
    expect(headers["user-agent"]).toMatch(/^pi\//);
    expect(headers["http-referer"]).toBeUndefined();
    expect(headers["x-openrouter-title"]).toBeUndefined();
    expect(headers["x-openrouter-categories"]).toBeUndefined();
  });

  it("sends each canonical transcript item to a subscribed phone once per tool call, and a phone off the base resyncs from one full snapshot (#2473)", async () => {
    const gateway = await startGatewayProcess();
    gateways.push(gateway);
    const tools = 10;
    gateway.provider.script([
      ...Array.from({ length: tools }, (_, index) => () => ({
        chunks: [`Step ${index + 1}.`],
        toolCalls: [{ id: `delta_call_${index + 1}`, name: "bash", arguments: { command: `seq -f 'step ${index + 1} line %04g of deterministic tool output' 1 80` } }],
      })),
      () => ({ chunks: ["All ten steps finished."] }),
      () => ({ chunks: ["Resynchronized reply."] }),
    ]);
    const phone = await gateway.connect();
    try {
      const sessionId = await createSession(gateway, phone, "delta-create");
      const opened = await phone.request("session.open", { sessionId });
      expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
      const base = opened.result.session as SessionSnapshot;
      const start = phone.events.length;
      const admitted = await phone.request("session.prompt", { commandId: "delta-prompt", sessionId, text: "Run the ten steps." });
      expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
      const replayed = await waitFor(() => {
        const state = replay(base, phone.events.slice(start).filter((event) => event.sessionId === sessionId));
        return state.snapshot.phase === "idle" && !state.snapshot.operation
          && messages(state.snapshot as unknown as Snapshot, "assistant").at(-1) === "All ten steps finished." ? state : undefined;
      }, "the phone's own stream to settle the ten steps");
      const final = await freshSnapshot(gateway, sessionId) as unknown as SessionSnapshot;
      expect(replayed.snapshot.transcript).toEqual(final.transcript);

      const stated = replayed.frames;
      const restated = stated.filter((frame) => frame.topic === "session.rebaseline");
      const transcriptBytes = stated.filter((frame) => frame.topic !== "session.rebaseline")
        .reduce((total, frame) => total + itemBytes(frame.transcript), 0);
      const appended = final.transcript.slice(base.transcriptTotal - final.transcriptStart);
      const settledPrompt = appended.find((item) => item.kind === "message" && item.role === "user")!;
      console.info("#2473 per tool call", JSON.stringify({
        frames: stated.length / tools,
        bytes: stated.reduce((total, frame) => total + frame.bytes, 0) / tools,
        transcriptBytes: transcriptBytes / tools,
        full: stated.filter((frame) => frame.topic !== "session.transcriptDelta").length,
      }));
      expect(stated.length / tools, "transcript-bearing frames per tool call").toBeLessThanOrEqual(3);
      expect(transcriptBytes, "each canonical item crosses the wire once; the prompt row again when its lifecycle settles").toBeLessThanOrEqual(itemBytes(appended) + bytesOf(settledPrompt));
      expect(stated.filter((frame) => frame.topic === "session.snapshot"), "no full snapshot while the phone holds the base").toEqual([]);
      expect(restated.every((frame) => (frame.payload as { reason?: string }).reason === "superseded snapshot"),
        "a full restatement only replaces frames the outbound queue had not yet sent").toBe(true);

      const skipped = stated.find((frame, index) => frame.topic === "session.transcriptDelta" && frame.transcript.length > 0
        && stated[index + 1]?.topic === "session.transcriptDelta");
      expect(skipped, "two consecutive deltas to drop the first of").toBeDefined();
      const behind = replay(base, phone.events.slice(start).filter((event) => event.sessionId === sessionId && event.payload !== skipped!.payload), true);
      expect(behind.refused, "a delta whose base the phone does not hold is refused, never guessed").toBe(true);

      const reopened = await phone.request("session.open", { sessionId });
      expect((await phone.request("session.sync", { sessionId, syncToken: reopened.result.syncToken })).ok).toBe(true);
      const resynced = reopened.result.session as SessionSnapshot;
      expect(resynced.transcript).toEqual(final.transcript);
      const after = phone.events.length;
      expect((await phone.request("session.prompt", { commandId: "delta-after-resync", sessionId, text: "Once more." })).ok).toBe(true);
      const continued = await waitFor(() => {
        const state = replay(resynced, phone.events.slice(after).filter((event) => event.sessionId === sessionId));
        return state.snapshot.phase === "idle" && !state.snapshot.operation
          && messages(state.snapshot as unknown as Snapshot, "assistant").at(-1) === "Resynchronized reply." ? state : undefined;
      }, "deltas to continue from the resynchronized snapshot");
      expect(continued.frames.filter((frame) => frame.topic === "session.snapshot")).toEqual([]);
      expect(continued.snapshot.transcript).toEqual((await freshSnapshot(gateway, sessionId) as unknown as SessionSnapshot).transcript);
    } finally {
      await phone.close();
    }
  });
});
