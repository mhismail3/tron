import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { isTailscaleAddress, loadConfig, resolveBindHost, resolveTronHome } from "./config.js";

describe("gateway configuration", () => {
  it("recognizes only Tailscale CGNAT and canonical IPv6 ranges", () => {
    expect(isTailscaleAddress("100.64.0.1")).toBe(true);
    expect(isTailscaleAddress("100.127.255.254")).toBe(true);
    expect(isTailscaleAddress("100.128.0.1")).toBe(false);
    expect(isTailscaleAddress("192.168.1.2")).toBe(false);
    expect(isTailscaleAddress("fd7a:115c:a1e0::1")).toBe(true);
  });

  it("keeps explicit loopback binding and validates Tron home overrides", () => {
    expect(resolveBindHost("127.0.0.1")).toBe("127.0.0.1");
    expect(resolveTronHome({ TRON_DATA_DIR: "/tmp/tron-home" })).toBe("/tmp/tron-home");
    expect(() => resolveTronHome({ TRON_DATA_DIR: "relative" })).toThrow(/absolute/);
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
