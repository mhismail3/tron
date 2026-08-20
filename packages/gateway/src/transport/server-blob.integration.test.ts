import { request } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import { GatewayError } from "../errors.js";
import { BlobStore, type BlobLease } from "../sessions/blob-store.js";
import { GatewayServer } from "./server.js";

const roots: string[] = [];
const servers: GatewayServer[] = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

function makeServer(
  acquireBlob: (id: string) => Promise<BlobLease>,
  port = 0,
  acquireUpload: (id: string) => Promise<unknown> = async () => { throw new GatewayError("not_found", "missing"); },
): GatewayServer {
  return new GatewayServer({
    host: "127.0.0.1",
    port,
    maxFrameBytes: 64 * 1_024,
    devices: { authenticate: async () => ({ id: "device" }) } as never,
    uploads: { acquire: acquireUpload } as never,
    sessions: { acquireBlob } as never,
    auth: {} as never,
    service: {} as never,
    logger: { log: () => {} } as never,
  });
}

async function server(acquireBlob: (id: string) => Promise<BlobLease>): Promise<number> {
  const gateway = makeServer(acquireBlob);
  servers.push(gateway);
  await gateway.listen();
  const address = (gateway as unknown as { server: { address(): AddressInfo | null } }).server.address();
  if (!address) throw new Error("Gateway did not bind");
  return address.port;
}

function download(port: number, id: string, route = "blobs"): Promise<{
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: Buffer;
}> {
  return new Promise((resolve, reject) => {
    const outgoing = request({
      host: "127.0.0.1",
      port,
      path: `/v1/${route}/${encodeURIComponent(id)}`,
      headers: { authorization: "Bearer paired" },
    }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode ?? 0,
        headers: response.headers,
        body: Buffer.concat(chunks),
      }));
      response.on("error", reject);
    });
    outgoing.on("error", reject);
    outgoing.end();
  });
}

describe("Gateway blob HTTP leases", () => {
  it("runs destructive transient initialization only after the HTTP port is bound", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-blob-bind-"));
    roots.push(home);
    const directory = join(home, "blobs");
    await mkdir(directory);
    const store = new BlobStore(
      { maximumItemBytes: 16, maximumItems: 2, maximumTotalBytes: 32 },
      Date.now,
      directory,
    );
    await writeFile(join(directory, "stale-blob"), "stale");
    const gateway = makeServer((id) => store.acquire(id));
    servers.push(gateway);
    let observedBound = false;
    await gateway.listen(async () => {
      const address = (gateway as unknown as { server: { address(): AddressInfo | null } }).server.address();
      observedBound = address !== null;
      expect(await readFile(join(directory, "stale-blob"), "utf8")).toBe("stale");
      await store.initialize();
    });
    expect(observedBound).toBe(true);
    await expect(readFile(join(directory, "stale-blob"))).rejects.toMatchObject({ code: "ENOENT" });
    await store.dispose();
  });

  it("does not run destructive initialization when port binding fails", async () => {
    const owner = makeServer(async () => { throw new GatewayError("not_found", "missing"); });
    servers.push(owner);
    await owner.listen();
    const address = (owner as unknown as { server: { address(): AddressInfo | null } }).server.address();
    if (!address) throw new Error("Owner did not bind");

    const home = await mkdtemp(join(tmpdir(), "tron-blob-bind-failure-"));
    roots.push(home);
    const stale = join(home, "stale");
    await writeFile(stale, "keep");
    const contender = makeServer(async () => { throw new GatewayError("not_found", "missing"); }, address.port);
    let initialized = false;
    await expect(contender.listen(async () => {
      initialized = true;
      await rm(stale, { force: true });
    })).rejects.toMatchObject({ code: "EADDRINUSE" });
    expect(initialized).toBe(false);
    expect(await readFile(stale, "utf8")).toBe("keep");
  });

  it("preserves the HTTP contract for memory-backed projected blobs", async () => {
    const store = new BlobStore({ maximumItemBytes: 16, maximumItems: 2, maximumTotalBytes: 32 });
    const id = store.registerData(Buffer.from("projected"), "image/png");
    const port = await server((requested) => store.acquire(requested));

    const response = await download(port, id);
    expect(response.status).toBe(200);
    expect(response.headers["content-type"]).toBe("image/png");
    expect(response.headers["content-length"]).toBe("9");
    expect(response.headers["cache-control"]).toBe("private, max-age=300");
    expect(response.headers["x-content-type-options"]).toBe("nosniff");
    expect(response.body.toString()).toBe("projected");
    await store.dispose();
  });

  it("streams a file-backed blob with the established headers", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-blob-http-"));
    roots.push(home);
    const store = new BlobStore(
      { maximumItemBytes: 16, maximumItems: 2, maximumTotalBytes: 32 },
      Date.now,
      join(home, "blobs"),
    );
    await store.initialize();
    const source = join(home, "source");
    await writeFile(source, "file-backed");
    const id = await store.registerFile(source, "text/plain");
    const port = await server((requested) => store.acquire(requested));

    const response = await download(port, id);
    expect(response.status).toBe(200);
    expect(response.headers["content-type"]).toBe("text/plain");
    expect(response.headers["content-length"]).toBe("11");
    expect(response.headers["cache-control"]).toBe("private, max-age=300");
    expect(response.headers["x-content-type-options"]).toBe("nosniff");
    expect(response.body.toString()).toBe("file-backed");
    await store.dispose();
  });

  it("streams prompt-owned uploads through the same authenticated bounded contract", async () => {
    const gateway = makeServer(
      async () => { throw new GatewayError("not_found", "missing"); },
      0,
      async () => ({
        name: "notes.txt",
        mimeType: "text/plain",
        size: 5,
        stream: Readable.from([Buffer.from("notes")]),
        release: async () => {},
      }),
    );
    servers.push(gateway);
    await gateway.listen();
    const address = (gateway as unknown as { server: { address(): AddressInfo | null } }).server.address();
    if (!address) throw new Error("Gateway did not bind");

    const response = await download(address.port, "00000000-0000-4000-8000-000000000001", "uploads");
    expect(response.status).toBe(200);
    expect(response.headers["content-type"]).toBe("text/plain");
    expect(response.headers["content-length"]).toBe("5");
    expect(response.headers["content-disposition"]).toContain("notes.txt");
    expect(response.body.toString()).toBe("notes");
  });

  it("returns JSON before headers for an unavailable blob", async () => {
    const port = await server(async () => {
      throw new GatewayError("not_found", "missing");
    });
    const response = await download(port, "missing");
    expect(response.status).toBe(404);
    expect(JSON.parse(response.body.toString())).toMatchObject({ error: { code: "not_found" } });
  });

  it("releases the lease when a client aborts", async () => {
    let releaseBody!: () => void;
    const bodyGate = new Promise<void>((resolve) => { releaseBody = resolve; });
    let released!: () => void;
    const releaseObserved = new Promise<void>((resolve) => { released = resolve; });
    const port = await server(async () => ({
      mimeType: "text/plain",
      size: 8,
      stream: Readable.from((async function* () {
        yield Buffer.from("1234");
        await bodyGate;
        yield Buffer.from("5678");
      })()),
      release: async () => { released(); },
    }));

    await new Promise<void>((resolve, reject) => {
      const outgoing = request({
        host: "127.0.0.1",
        port,
        path: "/v1/blobs/value",
        headers: { authorization: "Bearer paired" },
      }, (response) => {
        response.once("data", () => {
          response.destroy();
          releaseBody();
          resolve();
        });
      });
      outgoing.on("error", reject);
      outgoing.end();
    });
    await releaseObserved;
  });

  it("closes a post-header stream failure and still releases", async () => {
    let released!: () => void;
    const releaseObserved = new Promise<void>((resolve) => { released = resolve; });
    const port = await server(async () => ({
      mimeType: "text/plain",
      size: 8,
      stream: Readable.from((async function* () {
        yield Buffer.from("1234");
        throw new Error("read failed");
      })()),
      release: async () => { released(); },
    }));
    await expect(download(port, "value")).rejects.toBeDefined();
    await releaseObserved;
  });
});
