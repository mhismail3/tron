import { request, type ClientRequest } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import { BrowserSocket, jpeg, registration } from "../../test-fixtures/browser-live.js";
import { GatewayServer } from "./server.js";

const roots: string[] = [], servers: GatewayServer[] = [], requests: ClientRequest[] = [];
afterEach(async () => {
  for (const outgoing of requests.splice(0)) outgoing.destroy();
  await Promise.all(servers.splice(0).map((server) => server.close()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  vi.restoreAllMocks();
});
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-live-http-")); roots.push(root);
  const devices = new DeviceStore(root, "fixture"); await devices.initialize();
  const device = await devices.pair((await devices.ensureEnrollment()).code, "Fixture phone");
  const sockets: BrowserSocket[] = [];
  const views = new BrowserLiveViewRegistry(() => { const socket = new BrowserSocket(); sockets.push(socket); return socket as never; });
  views.register({ ...registration, loadToken: views.beginSessionLoad(registration.sessionId) });
  let authorized = true;
  const server = new GatewayServer({ host: "127.0.0.1", port: 0, maxFrameBytes: 64 * 1024, devices,
    uploads: {} as never, sessions: {} as never, auth: { cancelOwner() {} } as never, service: {} as never,
    logger: { log() {} } as never, liveViews: views,
    authorizeBrowserLiveView: (session, view, generation) => authorized && session === registration.sessionId
      && view === registration.viewId && generation === registration.generation,
  });
  servers.push(server); await server.listen();
  const port = (server as unknown as { server: { address(): AddressInfo } }).server.address().port;
  return { server, views, sockets, devices, device, port, retireBranch() { authorized = false; } };
}
const route = `/v1/sessions/${registration.sessionId}/live-views/${registration.viewId}`;
function send(port: number, token: string, method: string, path = route, headers: Record<string, string> = {}, hold = false) {
  const body = method === "POST" ? JSON.stringify({ generation: registration.generation }) : undefined;
  let outgoing!: ClientRequest;
  const result = new Promise<{ status: number; headers: Record<string, string | string[] | undefined>; data: Buffer }>((resolve, reject) => {
    outgoing = request({ host: "127.0.0.1", port, method, path, headers: { authorization: `Bearer ${token}`,
      ...(body ? { "content-length": Buffer.byteLength(body) } : {}), ...headers } }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode!, headers: response.headers, data: Buffer.concat(chunks) }));
      response.on("error", reject);
    });
    outgoing.on("error", reject); requests.push(outgoing);
    if (hold) outgoing.flushHeaders(); else outgoing.end(body);
  });
  return { result, finish: () => outgoing.end(body) };
}
function headers(leaseId: string) { return { "x-tron-live-lease": leaseId, "x-tron-live-generation": registration.generation }; }

describe("authenticated disposable browser-view HTTP", () => {
  it("opens only when requested, delivers bounded fresh frames, and closes without closing browser automation", async () => {
    const f = await fixture();
    expect(f.sockets).toHaveLength(0);
    const opened = await send(f.port, f.device.token, "POST").result;
    expect(opened.status).toBe(200);
    const { leaseId } = JSON.parse(opened.data.toString());
    const socket = f.sockets[0]!; socket.open();
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.startScreencast")).toBe(true));
    socket.frame(7);
    await vi.waitFor(() => expect(f.views.frame(registration.sessionId, registration.viewId, registration.generation, leaseId, f.device.deviceId)).toHaveProperty("data"));
    const frame = await send(f.port, f.device.token, "GET", `${route}/frame`, headers(leaseId)).result;
    expect(frame.status).toBe(200); expect(frame.data).toEqual(jpeg);
    expect(frame.headers["content-type"]).toBe("image/jpeg");
    expect(frame.headers["cache-control"]).toBe("no-store");
    expect(frame.headers["x-tron-live-width"]).toBe("1");
    const unchanged = await send(f.port, f.device.token, "GET", `${route}/frame`, { ...headers(leaseId), "x-tron-live-after": "1" }).result;
    expect(unchanged.status).toBe(204); expect(unchanged.data.length).toBe(0);
    expect(unchanged.headers["x-tron-live-state"]).toBe("unchanged");
    expect((await send(f.port, f.device.token, "DELETE", route, headers(leaseId)).result).status).toBe(204);
    expect(socket.readyState).toBe(3);
    expect(socket.commands.some((command) => command.method === "Browser.close")).toBe(false);
    expect((await send(f.port, f.device.token, "GET", `${route}/frame`, headers(leaseId)).result).status).toBe(404);
  });

  it("cannot admit a viewer after revocation while the POST body is pending", async () => {
    const f = await fixture();
    let admitted!: () => void;
    const initialAdmission = new Promise<void>((resolve) => { admitted = resolve; });
    const authenticate = f.devices.authenticateAndAdmit.bind(f.devices);
    vi.spyOn(f.devices, "authenticateAndAdmit").mockImplementation((token, register) => authenticate(token, (identity) => {
      const result = register(identity); admitted(); return result;
    }));
    const opening = send(f.port, f.device.token, "POST", route, {}, true);
    await initialAdmission;
    await f.devices.revoke(f.device.deviceId, () => f.server.disconnectDevice(f.device.deviceId));
    opening.finish();
    expect((await opening.result).status).toBe(401);
    expect(f.sockets).toHaveLength(0);
  });

  it("revocation and branch retirement end existing viewers; wrong route/generation cannot close another lease", async () => {
    const f = await fixture();
    const opened = await send(f.port, f.device.token, "POST").result;
    const { leaseId } = JSON.parse(opened.data.toString());
    const wrong = await send(f.port, f.device.token, "DELETE", route, { ...headers(leaseId), "x-tron-live-generation": "other" }).result;
    expect(wrong.status).toBe(401);
    expect(f.sockets[0]?.readyState).toBe(0);
    f.retireBranch();
    expect((await send(f.port, f.device.token, "GET", `${route}/frame`, headers(leaseId)).result).status).toBe(404);
    expect(f.sockets[0]?.readyState).toBe(3);
    const g = await fixture();
    const second = await send(g.port, g.device.token, "POST").result;
    const lease = JSON.parse(second.data.toString()).leaseId;
    await g.devices.revoke(g.device.deviceId, () => g.server.disconnectDevice(g.device.deviceId));
    expect(g.sockets[0]?.readyState).toBe(3);
    expect((await send(g.port, g.device.token, "GET", `${route}/frame`, headers(lease)).result).status).toBe(401);
    expect((await send(g.port, "not-a-token", "POST").result).status).toBe(401);
  });
});
