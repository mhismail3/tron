import { request, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { UploadStore } from "../machine/upload-store.js";
import { GatewayServer } from "./server.js";

const roots: string[] = [];
const servers: GatewayServer[] = [];

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

class ObservableUploadStore extends UploadStore {
  private completion: (() => void) | undefined;
  private completed = new Promise<void>((resolve) => { this.completion = resolve; });
  private firstChunk: (() => void) | undefined;
  private firstChunkObserved = new Promise<void>((resolve) => { this.firstChunk = resolve; });

  override async saveStream(
    name: string,
    mimeType: string,
    body: AsyncIterable<Uint8Array> | Iterable<Uint8Array>,
    declaredBytes?: number,
  ) {
    const observe = async function* (owner: ObservableUploadStore) {
      for await (const chunk of body) {
        owner.firstChunk?.();
        owner.firstChunk = undefined;
        yield chunk;
      }
    };
    try {
      return await super.saveStream(name, mimeType, observe(this), declaredBytes);
    } finally {
      this.completion?.();
      this.completion = undefined;
    }
  }

  waitForFirstChunk(): Promise<void> {
    return this.firstChunkObserved;
  }

  waitForCompletion(): Promise<void> {
    return this.completed;
  }
}

async function fixture(maximumBytes = 8): Promise<{
  home: string;
  port: number;
  uploads: ObservableUploadStore;
  gateway: GatewayServer;
}> {
  const home = await mkdtemp(join(tmpdir(), "tron-upload-http-"));
  roots.push(home);
  const uploads = new ObservableUploadStore(home, maximumBytes, { maximumStagingBytes: maximumBytes * 2 });
  const gateway = new GatewayServer({
    host: "127.0.0.1",
    port: 0,
    maxFrameBytes: 64 * 1_024,
    devices: { authenticateAndAdmit: async (_token: unknown, register: (identity: { kind: "device"; deviceId: string }) => unknown) => register({ kind: "device", deviceId: "device" }) } as never,
    uploads,
    sessions: {} as never,
    auth: {} as never,
    service: {} as never,
    logger: { log: () => {} } as never,
  });
  servers.push(gateway);
  await gateway.listen();
  const address = (gateway as unknown as { server: { address(): AddressInfo | null } }).server.address();
  if (!address) throw new Error("Gateway did not bind an HTTP address");
  return { home, port: address.port, uploads, gateway };
}

async function entries(path: string): Promise<string[]> {
  try {
    return await readdir(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
}

function deleteUploadRequest(port: number, id: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const outgoing = request({
      host: "127.0.0.1",
      port,
      method: "DELETE",
      path: `/v1/uploads/${encodeURIComponent(id)}`,
      headers: { authorization: "Bearer paired" },
    }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode ?? 0,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    outgoing.on("error", reject);
    outgoing.end();
  });
}

function uploadRequest(
  port: number,
  declaredBytes: number | undefined,
  write: (request: ReturnType<typeof request>) => void,
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const outgoing = request({
      host: "127.0.0.1",
      port,
      method: "POST",
      path: "/v1/uploads?name=stream.txt",
      headers: {
        authorization: "Bearer paired",
        "content-type": "text/plain",
        ...(declaredBytes === undefined ? {} : { "content-length": String(declaredBytes) }),
      },
    }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode ?? 0,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    outgoing.on("error", reject);
    write(outgoing);
  });
}

describe("Gateway upload HTTP streaming", () => {
  it("publishes an unknown-length request only after its file-backed body completes", async () => {
    const { home, port, uploads } = await fixture();
    let outgoingRequest!: ReturnType<typeof request>;
    const responseTask = uploadRequest(port, undefined, (outgoing) => {
      outgoingRequest = outgoing;
      outgoing.write("1234");
    });
    await uploads.waitForFirstChunk();
    expect(await readdir(join(home, "gateway", "uploads"))).toEqual([]);
    outgoingRequest.end("5678");
    const response = await responseTask;

    expect(response.status).toBe(201);
    const id = JSON.parse(response.body).upload.id as string;
    expect(await readFile(join(home, "gateway", "uploads", id, "content.txt"), "utf8")).toBe("12345678");
    expect(await readdir(join(home, "gateway", "upload-bodies"))).toEqual([]);
  });

  it.each([false, true])("cleans a lost upload receipt without deleting claimed bytes (claimed=%s)", async (claimed) => {
    const { home, port, uploads, gateway } = await fixture();
    let published!: () => void;
    const publish = new Promise<void>(resolve => { published = resolve; });
    let bodyWritten!: (id: string) => void;
    const written = new Promise<string>(resolve => { bodyWritten = resolve; });
    let released!: () => void;
    const discarded = new Promise<void>(resolve => { released = resolve; });
    let closed!: () => void;
    const peerClosed = new Promise<void>(resolve => { closed = resolve; });
    (gateway as unknown as { server: Server }).server.once("connection", socket => socket.once("close", closed));
    const save = uploads.saveStream.bind(uploads);
    const discard = uploads.discard.bind(uploads);
    vi.spyOn(uploads, "saveStream").mockImplementation(async (...args) => {
      const uploaded = await save(...args);
      bodyWritten(uploaded.id);
      await publish;
      return uploaded;
    });
    vi.spyOn(uploads, "discard").mockImplementation(async id => {
      try { await discard(id); } finally { released(); }
    });
    let outgoing!: ReturnType<typeof request>;
    const response = uploadRequest(port, 5, request => { outgoing = request; request.end("draft"); });
    void response.catch(() => {});
    try {
      const id = await written;
      if (claimed) await uploads.materialize([id], "fixture-session");
      outgoing.destroy();
      await expect(response).rejects.toBeDefined();
      await peerClosed;
      published();
      let timer!: NodeJS.Timeout;
      try {
        await Promise.race([discarded, new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error("abandoned staging was not retired")), 2_000);
        })]);
      } finally { clearTimeout(timer); }
      if (claimed) expect(await readFile(join(home, "gateway", "uploads", id, "content.txt"), "utf8")).toBe("draft");
      else expect(await entries(join(home, "gateway", "uploads"))).not.toContain(id);
    } finally {
      published();
      outgoing.destroy();
    }
  });

  it("discards authenticated unclaimed staging but rejects prompt-owned uploads", async () => {
    const { home, port, uploads } = await fixture();
    const abandonedResponse = await uploadRequest(port, 5, (outgoing) => outgoing.end("draft"));
    const abandonedID = JSON.parse(abandonedResponse.body).upload.id as string;
    await expect(deleteUploadRequest(port, abandonedID)).resolves.toMatchObject({ status: 204, body: "" });
    expect(await entries(join(home, "gateway", "uploads"))).not.toContain(abandonedID);

    const claimedResponse = await uploadRequest(port, 6, (outgoing) => outgoing.end("prompt"));
    const claimedID = JSON.parse(claimedResponse.body).upload.id as string;
    await uploads.materialize([claimedID], "session");
    const rejected = await deleteUploadRequest(port, claimedID);
    expect(rejected.status).toBe(409);
    expect(JSON.parse(rejected.body)).toMatchObject({ error: { code: "conflict" } });
  });

  it("rejects declared and observed oversize without publishing staging", async () => {
    const declared = await fixture();
    const declaredResponse = await uploadRequest(declared.port, 9, (outgoing) => outgoing.end());
    expect(declaredResponse.status).toBe(400);
    expect(JSON.parse(declaredResponse.body)).toMatchObject({ error: { code: "invalid_request" } });
    expect(await entries(join(declared.home, "gateway", "upload-bodies"))).toEqual([]);

    const observed = await fixture();
    const observedResponse = await uploadRequest(observed.port, undefined, (outgoing) => outgoing.end("123456789"));
    expect(observedResponse.status).toBe(400);
    expect(await entries(join(observed.home, "gateway", "uploads"))).toEqual([]);
    expect(await entries(join(observed.home, "gateway", "upload-bodies"))).toEqual([]);
  });

  it("reports bounded concurrent admission as retryable HTTP overload", async () => {
    const { port, uploads } = await fixture();
    let firstRequest!: ReturnType<typeof request>;
    const firstResponse = uploadRequest(port, undefined, (outgoing) => {
      firstRequest = outgoing;
      outgoing.write("1234");
    });
    await uploads.waitForFirstChunk();

    const rejected = await uploadRequest(port, 8, (outgoing) => outgoing.end("12345678"));
    expect(rejected.status).toBe(503);
    expect(JSON.parse(rejected.body)).toMatchObject({ error: { code: "busy", retryable: true } });
    firstRequest.end("5678");
    await expect(firstResponse).resolves.toMatchObject({ status: 201 });
  });

  it("cleans an interrupted request and releases admission for an immediate retry", async () => {
    const { home, port, uploads } = await fixture();
    const interrupted = uploadRequest(port, 8, (outgoing) => {
      outgoing.write("1234", () => outgoing.destroy());
    });
    await expect(interrupted).rejects.toBeDefined();
    await uploads.waitForCompletion();
    expect(await readdir(join(home, "gateway", "upload-bodies"))).toEqual([]);

    const retry = await uploadRequest(port, 8, (outgoing) => outgoing.end("12345678"));
    expect(retry.status).toBe(201);
  });
});
