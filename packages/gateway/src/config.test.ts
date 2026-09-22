import { chmod, lstat, mkdtemp as createTemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { isTailscaleAddress, loadConfig as loadGatewayConfig, machineGroupIdentityPaths, resolveBindHost, resolveTronHome } from "./config.js";
import * as durableJson from "./util/durable-json.js";

const roots: string[] = [];
async function mkdtemp(prefix: string) { const root = await createTemp(prefix); roots.push(root); return root; }
const loadConfig: typeof loadGatewayConfig = (args, environment = {}) => loadGatewayConfig(args, {
  TRON_MACHINE_GROUP_ID: environment.TRON_MACHINE_GROUP_PATH ? undefined : "test-machine-group",
  ...environment,
});
afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

describe("gateway configuration", () => {
  it("keeps runtime admission bounded and explicitly scalable beyond the default", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-runtime-capacity-"));
    const environment = { TRON_DATA_DIR: home };
    expect((await loadConfig([], environment)).maxLiveRuntimes).toBe(128);
    expect((await loadConfig([], { ...environment, TRON_GATEWAY_MAX_LIVE_RUNTIMES: "512" })).maxLiveRuntimes).toBe(512);
    for (const raw of ["0", "-1", "1.5", "NaN", "1025", "", "1e2"]) {
      await expect(loadConfig([], { ...environment, TRON_GATEWAY_MAX_LIVE_RUNTIMES: raw })).rejects.toMatchObject({ code: "invalid_request" });
    }
  });

  it("recognizes only Tailscale CGNAT and canonical IPv6 ranges", () => {
    expect(isTailscaleAddress("100.64.0.1")).toBe(true);
    expect(isTailscaleAddress("100.127.255.254")).toBe(true);
    expect(isTailscaleAddress("100.128.0.1")).toBe(false);
    expect(isTailscaleAddress("192.168.1.2")).toBe(false);
    expect(isTailscaleAddress("fd7a:115c:a1e0::1")).toBe(true);
    for (const malformed of [
      "100.64.0.999", "100.64.0.1.example", "100.63.255.255", "100.128.0.1", "100.64.0.1%en0",
      "fd7a:115c:a1e0:garbage::1", "fd7a:115c:a1e1::1", "fd7a:115c:a1e0::1%utun0",
    ]) expect(isTailscaleAddress(malformed)).toBe(false);
  });

  it("resolves tailscale deterministically and keeps explicit loopback binding", () => {
    const interfaces = {
      en0: [{ address: "100.90.0.2", netmask: "", family: "IPv4" as const, mac: "", internal: false, cidr: "" }],
      utun9: [{ address: "100.80.0.3", netmask: "", family: "IPv4" as const, mac: "", internal: false, cidr: "" }],
    };
    expect(resolveBindHost("tailscale", interfaces)).toBe("100.80.0.3");
    expect(resolveBindHost("127.0.0.1", interfaces)).toBe("127.0.0.1");
    expect(resolveTronHome({ TRON_DATA_DIR: "/tmp/tron-home" })).toBe("/tmp/tron-home");
    expect(machineGroupIdentityPaths({}, "/Users/example")).toEqual({
      canonical: "/Users/example/.tron/internal/machine-group-id",
      legacy: "/Users/example/.tron-machine-group-id",
    });
    expect(machineGroupIdentityPaths({ TRON_MACHINE_GROUP_PATH: "/tmp/shared-group" }, "/Users/example").canonical).toBe("/tmp/shared-group");
    expect(() => resolveTronHome({ TRON_DATA_DIR: "relative" })).toThrow(/absolute/);
    expect(() => resolveBindHost("tailscale", {})).toThrow(/Tailscale is not connected/);
  });

  it("shares an injected machine group while retaining per-home machine identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-group-"));
    const groupPath = join(root, "machine-group.json");
    const [first, second] = await Promise.all([
      loadConfig([], { TRON_DATA_DIR: join(root, "prod"), TRON_MACHINE_GROUP_PATH: groupPath }),
      loadConfig([], { TRON_DATA_DIR: join(root, "dev"), TRON_MACHINE_GROUP_PATH: groupPath }),
    ]);
    expect(first.machineGroupID).toBe(second.machineGroupID);
    expect(first.machineId).not.toBe(second.machineId);
    const sameHome = join(root, "same-home");
    const [sameFirst, sameSecond] = await Promise.all([
      loadConfig([], { TRON_DATA_DIR: sameHome, TRON_MACHINE_GROUP_PATH: groupPath }),
      loadConfig([], { TRON_DATA_DIR: sameHome, TRON_MACHINE_GROUP_PATH: groupPath }),
    ]);
    expect(sameFirst.machineId).toBe(sameSecond.machineId);
    expect(first.agentDir).toBe(join(root, "prod", "agent"));
    expect(second.agentDir).toBe(join(root, "dev", "agent"));
    const unchangedDefault = await loadConfig([], { TRON_DATA_DIR: join(root, "default"), TRON_MACHINE_GROUP_PATH: groupPath });
    expect(unchangedDefault.agentDir).toBe(join(root, "default", "agent"));
  });

  it("retains only an explicit absolute agent directory and rejects the retired name override", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-agent-dir-"));
    await expect(loadConfig([], { TRON_DATA_DIR: join(root, "home"), TRON_AGENT_DIR_NAME: "agent-old" })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(loadConfig([], { TRON_DATA_DIR: join(root, "home"), PI_CODING_AGENT_DIR: "relative-agent" })).rejects.toMatchObject({ code: "invalid_request" });
    const explicit = join(root, "custom-agent");
    const loaded = await loadConfig([], { TRON_DATA_DIR: join(root, "home"), PI_CODING_AGENT_DIR: explicit });
    expect(loaded.agentDir).toBe(explicit);
    const homeNamed = await loadConfig([], { TRON_HOME_NAME: "tron-custom", PI_CODING_AGENT_DIR: explicit });
    expect(homeNamed.agentDir).toBe(explicit);
  });

  it("does not admit a runtime or user push-origin override", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-push-"));
    const canonical = await loadConfig([], { TRON_DATA_DIR: join(root, "canonical") });
    const attemptedOverride = await loadConfig([], {
      TRON_DATA_DIR: join(root, "override"),
      TRON_PUSH_SERVICE_ORIGIN: "https://attacker.example.test",
    });
    expect(canonical.pushServiceOrigin).toBeDefined();
    expect(attemptedOverride.pushServiceOrigin).toBe(canonical.pushServiceOrigin);
  });

  it("normalizes the retired default workspace without rekeying identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-workspace-retirement-"));
    const path = join(root, "gateway", "gateway.json");
    await loadConfig([], { TRON_DATA_DIR: root });
    const before = { version: 1, machineId: "machine", machineName: "Mac", defaultWorkspace: "/old/workspace" };
    await writeFile(path, `${JSON.stringify(before)}\n`);

    const [loaded, concurrent] = await Promise.all([
      loadConfig([], { TRON_DATA_DIR: root }), loadConfig([], { TRON_DATA_DIR: root }),
    ]);
    expect(concurrent.machineId).toBe(before.machineId);
    expect(await loadConfig([], { TRON_DATA_DIR: root })).toEqual(loaded);
    expect(loaded.machineId).toBe(before.machineId);
    expect(loaded.machineName).toBe(before.machineName);
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
      version: 1,
      machineId: before.machineId,
      machineName: before.machineName,
    });
  });

  it("preserves the exact old identity if normalization cannot publish", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-write-failure-"));
    const path = join(root, "gateway/gateway.json");
    await loadConfig([], { TRON_DATA_DIR: root });
    const original = JSON.stringify({ version: 1, machineId: "kept", machineName: "Mac", defaultWorkspace: "/old" });
    await writeFile(path, original);
    vi.spyOn(durableJson, "durableAtomicWriteJson").mockRejectedValueOnce(Object.assign(new Error("disk full"), { code: "ENOSPC" }));
    await expect(loadConfig([], { TRON_DATA_DIR: root })).rejects.toMatchObject({ code: "ENOSPC" });
    expect(await readFile(path, "utf8")).toBe(original);
    expect((await loadConfig([], { TRON_DATA_DIR: root })).machineId).toBe("kept");
  });

  it.each(["permissions", "symlink"])("preserves unsafe %s configuration rather than normalizing it", async kind => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-unsafe-"));
    const path = join(root, "gateway/gateway.json");
    await loadConfig([], { TRON_DATA_DIR: root });
    const original = JSON.stringify({ version: 1, machineId: "kept", machineName: "Mac", defaultWorkspace: "/old" });
    await writeFile(path, original);
    if (kind === "permissions") await chmod(path, 0o644);
    else {
      await writeFile(join(root, "target.json"), original, { mode: 0o600 });
      await rm(path);
      await symlink(join(root, "target.json"), path);
    }
    const before = await lstat(path);
    await expect(loadConfig([], { TRON_DATA_DIR: root })).rejects.toMatchObject({ code: "conflict" });
    expect((await lstat(path)).ino).toBe(before.ino);
    expect(await readFile(path, "utf8")).toBe(original);
  });

  it("persists one bounded identity and reloads it without rekeying", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-"));
    const environment = {
      TRON_DATA_DIR: root,
      PI_CODING_AGENT_DIR: join(root, "agent"),
      TRON_GATEWAY_HOST: "127.0.0.2",
      TRON_GATEWAY_PORT: "12345",
    };
    const first = await loadConfig([], environment);
    const second = await loadConfig([], environment);

    expect(second.machineId).toBe(first.machineId);
    expect(second.machineName).toBe(first.machineName);
    expect(second.agentDir).toBe(join(root, "agent"));
    expect(second.host).toBe("127.0.0.2");
    expect(second.port).toBe(12_345);
    expect(second.maxFrameBytes).toBe(1_048_576);
    expect(second.maxOutboundBytes).toBe(8 * 1_048_576);
  });

  it.each([
    ["empty", ""],
    ["whitespace", " \n"],
    ["null", "null"],
    ["malformed", "{not-json"],
    ["unknown fields", JSON.stringify({ version: 1, machineId: "id", machineName: "Mac", extra: true })],
    ["missing fields", JSON.stringify({ version: 1, machineId: "id" })],
    ["wrong version", JSON.stringify({ version: 2, machineId: "id", machineName: "Mac" })],
    ["wrong field types", JSON.stringify({ version: 1, machineId: 1, machineName: true })],
    ["empty identity", JSON.stringify({ version: 1, machineId: "", machineName: "Mac" })],
    ["control-bearing identity", JSON.stringify({ version: 1, machineId: "id\n", machineName: "Mac" })],
    ["oversized identity", JSON.stringify({ version: 1, machineId: "x".repeat(257), machineName: "Mac" })],
    ["empty machine name", JSON.stringify({ version: 1, machineId: "id", machineName: "" })],
    ["oversized machine name", JSON.stringify({ version: 1, machineId: "id", machineName: "x".repeat(1_025) })],
    ["empty default workspace", JSON.stringify({ version: 1, machineId: "id", machineName: "Mac", defaultWorkspace: "" })],
    ["oversized default workspace", JSON.stringify({ version: 1, machineId: "id", machineName: "Mac", defaultWorkspace: "x".repeat(8_193) })],
  ])("fails closed for %s persisted identity without replacing it", async (_label, content) => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-invalid-"));
    const path = join(root, "gateway", "gateway.json");
    await loadConfig([], { TRON_DATA_DIR: root });
    await writeFile(path, content);

    await expect(loadConfig([], { TRON_DATA_DIR: root })).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(path, "utf8")).toBe(content);
  });

  it("admits the exact file ceiling and rejects one byte beyond it", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-config-boundary-"));
    const path = join(root, "gateway", "gateway.json");
    await loadConfig([], { TRON_DATA_DIR: root });
    const compact = JSON.stringify(JSON.parse(await readFile(path, "utf8")));
    const exact = `${compact}${" ".repeat(16 * 1_024 - Buffer.byteLength(compact))}`;
    expect(Buffer.byteLength(exact)).toBe(16 * 1_024);
    await writeFile(path, exact);
    await expect(loadConfig([], { TRON_DATA_DIR: root })).resolves.toMatchObject({
      machineId: JSON.parse(compact).machineId,
    });

    const oversized = `${exact} `;
    await writeFile(path, oversized);
    await expect(loadConfig([], { TRON_DATA_DIR: root })).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(path, "utf8")).toBe(oversized);
  });
});
