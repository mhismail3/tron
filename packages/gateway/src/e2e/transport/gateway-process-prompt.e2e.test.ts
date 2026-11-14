import { randomUUID } from "node:crypto";
import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { delimiter, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startGatewayProcess, type GatewayProcess, type ProcessClient } from "../../../test-support/gateway-process.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";

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
      await phone.close();

      const normalRestartStarted = performance.now();
      await gateway.restart({ whileStopped: async () => {
        console.info("normal Gateway shutdown ms", performance.now() - normalRestartStarted);
      } });
      console.info("normal Gateway process restart ms", performance.now() - normalRestartStarted);
      expectExactlyOnce(await freshSnapshot(gateway, sessionId));
      expect(gateway.provider.requests).toHaveLength(1);
      expect(gateway.provider.requests[0]!.messages.filter((message) => message.role === "user")).toHaveLength(1);
      expect(gateway.provider.errors).toEqual([]);

      const bin = join(gateway.root, "bin");
      const pidFile = join(gateway.root, "npm.pid");
      await mkdir(bin);
      await writeFile(join(bin, "npm"), `#!${process.execPath}\nrequire("node:fs").writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000);\n`, { mode: 0o755 });
      await gateway.restart({ environment: { PATH: `${bin}${delimiter}${process.env.PATH ?? ""}` } });
      expectExactlyOnce(await freshSnapshot(gateway, sessionId));
      lookupPid = await waitFor(async () => {
        try { return Number(await readFile(pidFile, "utf8")) || undefined; } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
          return undefined;
        }
      }, "the real session started its global npm discovery");
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
  }, 60_000);
});

describe("Run Swift files device preference through the production Gateway process composition", () => {
  it("a Home settings change reaches the explicit paired iPhone over its authenticated socket, is audited, and undoes through a fresh read", async () => {
    const gateway = await startGatewayProcess();
    gateways.push(gateway);
    const phone = await gateway.pair("Process fixture iPhone");
    const iphone = await gateway.connect({ token: phone.token, capabilities: ["device-preference"] });
    const local = await gateway.connect();
    const key = "experimental.swiftApps";
    const device = { device: phone.deviceId };
    const requests = (action: string) => iphone.events.filter((event) => event.topic === "device.preference.request" && event.payload.action === action).map((event) => event.payload as Record<string, any>);
    const answer = async (action: string, index: number, body: Record<string, unknown>) => {
      await waitFor(() => requests(action).length > index, `the phone ${action} request ${index + 1}`);
      const reply = await iphone.request("device.preference.respond", { commandId: randomUUID(), requestId: requests(action)[index]!.requestId, ...body });
      expect(reply.ok, JSON.stringify(reply)).toBe(true);
    };

    const changing = local.request("settings.change", { commandId: randomUUID(), target: { kind: "global" }, reason: "Turn off Swift files",
      changes: [{ key, layer: "global", op: "set", value: false, qualifiers: device, expected: true }] });
    await new Promise((resolve) => setTimeout(resolve, 8_000));
    const settled = await Promise.race([changing.then((value) => ({ value }), (error: unknown) => ({ error: String(error) })), new Promise((resolve) => setTimeout(() => resolve({ pending: true }), 1_000))]);
    const probe = iphone.request("device.preference.respond", { commandId: randomUUID(), requestId: requests("read")[0]!.requestId, status: "value", value: true });
    const reply = await Promise.race([probe.then((value) => ({ value }), (error: unknown) => ({ error: String(error) })), new Promise((resolve) => setTimeout(() => resolve({ pending: true }), 3_000))]);
    expect(JSON.stringify({ topics: iphone.events.map((event) => event.topic), settled, reply }), "DIAGNOSTIC").toBe("never");
    await answer("read", 0, { status: "value", value: true });
    await answer("read", 1, { status: "value", value: true });
    await answer("set", 0, { status: "applied" });
    const applied = await changing;
    expect(applied.ok, JSON.stringify(applied)).toBe(true);
    expect(applied.result).toMatchObject({ status: "applied" });
    const changeId = applied.result.changes[0].changeId as string;

    const history = await local.request("settings.history", { key, limit: 10 });
    expect(history.ok, JSON.stringify(history)).toBe(true);
    expect(history.result.entries).toHaveLength(1);
    expect(history.result.entries[0]).toMatchObject({ changeId, status: "applied", actor: { kind: "ui" }, layer: "global", before: true, after: false, qualifiers: device });

    const undoing = local.request("settings.undo", { commandId: randomUUID(), changeId, reason: "Undo Swift files" });
    await answer("read", 2, { status: "value", value: false });
    await answer("set", 1, { status: "applied" });
    const undone = await undoing;
    expect(undone.ok, JSON.stringify(undone)).toBe(true);
    expect(undone.result).toMatchObject({ status: "applied" });
    expect(requests("set").map((request) => [request.expected, request.value])).toEqual([[true, false], [false, true]]);
    await local.close(); await iphone.close();
  }, 60_000);
});
