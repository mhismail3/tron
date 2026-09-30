import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { McpAdminService, type McpCredentialOwner } from "./mcp-admin-service.js";

const cliPath = join(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))), "bundle/cli.js");

describe("McpAdminService", () => {
  it("uses the bundled CLI for explicit status reads and bounds the result to valid JSON", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-admin-"));
    try {
      const service = new McpAdminService(root, cliPath);
      const result = await service.list({ scope: "global" }) as { servers: unknown[]; errors: unknown[] };
      expect(result.servers).toEqual([]);
      expect(result.errors).toEqual([]);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("updates only requested fields, preserves neighboring config and fails closed on malformed files", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-patch-"));
    try {
      const config = join(root, "mcp.json");
      const original = { extensionData: { retained: true }, mcpServers: {
        wanted: { command: "fixture", enabled: true, exposure: "direct", args: ["a"] },
        other: { url: "https://fixture.invalid/mcp", headers: { retained: "value" } },
      } };
      await writeFile(config, JSON.stringify(original));
      const service = new McpAdminService(root, cliPath);
      await service.update({ scope: "global" }, "wanted", { enabled: false, exposure: "hidden" });
      const saved = JSON.parse(await readFile(config, "utf8"));
      expect(saved.mcpServers.wanted).toEqual({ ...original.mcpServers.wanted, enabled: false, exposure: "hidden" });
      expect(saved.mcpServers.other).toEqual(original.mcpServers.other);
      expect(saved.extensionData).toEqual(original.extensionData);
      await expect(service.update({ scope: "global" }, "missing", { enabled: true })).rejects.toThrow(/not found/u);
      await writeFile(config, "{broken");
      await expect(service.update({ scope: "global" }, "wanted", { enabled: true })).rejects.toThrow(/cannot be parsed/u);
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  it("stores a token only through its credential owner and writes a !command reference", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-token-"));
    const captured: string[] = [];
    const owner: McpCredentialOwner = {
      async store(_server, token) { captured.push(token); return "tron-mcp-fixture"; },
      async remove() {},
    };
    try {
      await writeFile(join(root, "mcp.json"), JSON.stringify({ mcpServers: { fixture: { url: "https://fixture.invalid/mcp" } } }));
      const service = new McpAdminService(root, cliPath, owner);
      const response = await service.storeBearer({ scope: "global" }, "fixture", "never-projected-secret");
      const config = await readFile(join(root, "mcp.json"), "utf8");
      expect(captured).toEqual(["never-projected-secret"]);
      expect(response).toEqual({ server: "fixture", stored: true });
      expect(config).toContain("!/usr/bin/security");
      expect(config).not.toContain("never-projected-secret");
    } finally { await rm(root, { recursive: true, force: true }); }
  });

});
