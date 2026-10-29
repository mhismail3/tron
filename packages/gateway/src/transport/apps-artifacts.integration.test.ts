import { request } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, mkdtemp, open, realpath, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { expect, it } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { AppsFolderStore } from "../modules/apps/apps-folder-store.js";
import { GatewayServer } from "./server.js";

it("serves typed folder artifact ranges through real device authentication, releases 304s and refuses stale bytes", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-app-artifact-http-"))), home = join(root, "tron");
  const workspace = new TronWorkspace(home); await workspace.initialize();
  const store = new AppsFolderStore(workspace, home), devices = new DeviceStore(home, "fixture-machine");
  let gateway: GatewayServer | undefined;
  try {
    await devices.initialize(); const invite = await devices.ensureEnrollment(), paired = await devices.pair(invite.code, "fixture phone");
    const directory = join(home, "workspace/files/apps/preview"); await mkdir(directory, { recursive: true });
    const file = await open(join(directory, "clip.mp4"), "w"), header = Buffer.from("000000186674797069736f6d", "hex"), size = 40 * 1024 * 1024;
    try { await file.write(header); await file.truncate(size); } finally { await file.close(); }
    const row = (await store.index.catalog()).rows[0]!, projection = await store.open("preview", row.contentRevision, paired.deviceId);
    if (projection.kind !== "artifact") throw new Error("Fixture did not admit an artifact");
    gateway = new GatewayServer({ host: "127.0.0.1", port: 0, maxFrameBytes: 64 * 1024, devices, apps: store,
      display: {} as never, uploads: {} as never, sessions: {} as never, auth: {} as never, service: {} as never, logger: { log: () => {} } as never });
    await gateway.listen();
    const port = (gateway as unknown as { server: { address(): AddressInfo } }).server.address().port;
    const get = (headers: Record<string, string> = {}, authenticated = true) => new Promise<{ status: number; headers: import("node:http").IncomingHttpHeaders; body: Buffer }>((resolve, reject) => {
      const outgoing = request({ host: "127.0.0.1", port, path: projection.artifact.resourcePath,
        headers: { ...(authenticated ? { authorization: `Bearer ${paired.token}` } : {}), ...headers } }, response => {
        const chunks: Buffer[] = []; response.on("data", (chunk: Buffer) => chunks.push(chunk)); response.on("error", reject);
        response.on("end", () => resolve({ status: response.statusCode ?? 0, headers: response.headers, body: Buffer.concat(chunks) }));
      }); outgoing.on("error", reject); outgoing.end();
    });
    expect((await get({}, false)).status).toBe(401);
    const ranged = await get({ range: "bytes=4-11" });
    expect(ranged.status).toBe(206); expect(ranged.body).toEqual(header.subarray(4, 12));
    expect(ranged.headers["content-range"]).toBe(`bytes 4-11/${size}`); expect(ranged.headers["content-type"]).toBe("video/mp4");
    const etag = ranged.headers.etag!;
    for (let i = 0; i < 6; i++) expect((await get({ "if-none-match": etag })).status).toBe(304);
    expect((await get({ range: "bytes=0-3" })).body).toEqual(header.subarray(0, 4));
    const unsatisfiable = await get({ range: `bytes=${size}-` }); expect(unsatisfiable.status).toBe(416);
    expect(unsatisfiable.headers["content-range"]).toBe(`bytes */${size}`);
    const changed = await open(join(directory, "clip.mp4"), "r+"); try { await changed.write(Buffer.from([1]), 0, 1, 16); } finally { await changed.close(); }
    expect((await get({ range: "bytes=0-11" })).status).toBe(409);
  } finally { await gateway?.close(); await store.dispose(); await workspace.dispose(); await rm(root, { recursive: true, force: true }); }
});
