import { request, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { UploadStore } from "../machine/upload-store.js";
import { GatewayServer } from "./server.js";
import { waitFor } from "../../test-support/wait-for.js";

const roots: string[] = [];
const servers: GatewayServer[] = [];
const loggerRecords: Array<{ level: string; message: string; metadata: Record<string, unknown> }> = [];

afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  loggerRecords.splice(0);
});

class ObservableUploadStore extends UploadStore {
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
    return super.saveStream(name, mimeType, observe(this), declaredBytes);
  }

  waitForFirstChunk(): Promise<void> {
    return this.firstChunkObserved;
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
    logger: { log: (level: string, message: string, metadata: Record<string, unknown> = {}) => loggerRecords.push({ level, message, metadata }) } as never,
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
  requestID?: string,
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
        ...(requestID === undefined ? {} : { "x-tron-request-id": requestID }),
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

  it("records only correlated completed bytes or an interrupted upload outcome", async () => {
    const { home, port, uploads } = await fixture();
    const successID = "67a2c7ad-bef8-4336-8988-4b972cd4b82f";
    let outgoing!: ReturnType<typeof request>;
    const successTask = uploadRequest(port, 8, (request) => {
      outgoing = request;
      request.write("1234");
    }, successID);
    await uploads.waitForFirstChunk();
    expect(loggerRecords.filter(({ metadata }) => metadata.event === "http.upload.phase").map(({ metadata }) => metadata.step)).toEqual(["received"]);
    expect(loggerRecords.filter(({ metadata }) => metadata.event === "http.upload")).toHaveLength(0);
    outgoing.end("5678");
    const success = await successTask;
    expect(success.status).toBe(201);
    const successfulRecords = loggerRecords.filter(({ metadata }) => metadata.event === "http.upload");
    expect(successfulRecords).toHaveLength(1);
    const successfulRecord = successfulRecords[0];
    expect(successfulRecord).toMatchObject({
      message: "HTTP attachment upload response finished",
      metadata: { requestID: successID, outcome: "response-finished", counts: { bytes: 8 } },
    });
    expect(loggerRecords.filter(({ metadata }) => metadata.event === "http.upload.phase").map(({ metadata }) => metadata.step)).toEqual(["received", "staged"]);
    expect(successfulRecord?.message).not.toContain("stream.txt");
    expect(successfulRecord?.message).not.toContain("text/plain");

    loggerRecords.splice(0);
    const invalidCorrelation = await uploadRequest(port, 4, (request) => request.end("safe"), "private-header-value");
    expect(invalidCorrelation.status).toBe(201);
    expect(loggerRecords.filter(({ metadata }) => metadata.event === "http.upload" || metadata.event === "http.upload.phase")).toHaveLength(0);

    loggerRecords.splice(0);
    const failedID = "72f73074-529d-4f40-9274-6b0c50389373";
    const interrupted = uploadRequest(port, 8, (outgoing) => {
      outgoing.write("1234", () => outgoing.destroy());
    }, failedID);
    await expect(interrupted).rejects.toBeDefined();
    // The failed-upload record is written once the body stream's own staging
    // cleanup has finished, so waiting for the record also proves the partial
    // file is gone; no fixed pause can prove either on a busy host.
    await waitFor(
      () => loggerRecords.some(({ metadata }) => metadata.event === "http.upload" && metadata.requestID === failedID),
      "the failed upload record",
    );
    expect(await readdir(join(home, "gateway", "upload-bodies"))).toEqual([]);
    const failedRecords = loggerRecords.filter(({ metadata }) => metadata.event === "http.upload");
    expect(failedRecords).toHaveLength(1);
    const failedRecord = failedRecords[0];
    expect(failedRecord).toMatchObject({
      message: "HTTP attachment upload failed",
      metadata: { requestID: failedID, outcome: "failure", code: expect.any(String) },
    });
    // The async body iterator did not yield a partial chunk before abort, so
    // no observed-byte count is available to report.
    expect(failedRecord?.metadata.counts).toBeUndefined();
    expect(failedRecord?.message).not.toContain("stream.txt");
  });
});
