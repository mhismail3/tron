import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ModelConfigService } from "./model-config-service.js";

describe("ModelConfigService", () => {
  it("uses the pinned agent runtime to reject invalid model definitions before writing", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-model-config-"));
    const service = new ModelConfigService(root);

    await expect(service.put({
      providers: {
        custom: { baseUrl: "http://localhost:1234/v1", api: "openai-completions", models: [{ name: "Missing ID" }] },
      },
    })).rejects.toThrow(/invalid/i);
    await expect(readFile(join(root, "models.json"), "utf8")).rejects.toThrow();
  });

  it("preserves canonical secret values when a redacted document is updated", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-model-config-"));
    await writeFile(join(root, "models.json"), `${JSON.stringify({
      providers: { custom: { baseUrl: "http://localhost:1234/v1", api: "openai-completions", apiKey: "secret", models: [] } },
    })}\n`);
    const service = new ModelConfigService(root);
    const current = await service.get();
    expect(current.redacted).toBe(true);
    await service.put(current.document);
    expect(JSON.parse(await readFile(join(root, "models.json"), "utf8"))).toMatchObject({
      providers: { custom: { apiKey: "secret" } },
    });
  });

  it("admits the native empty configuration", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-model-config-"));
    const service = new ModelConfigService(root);
    await expect(service.validate({ providers: {} })).resolves.toEqual({ valid: true, providerCount: 0 });
  });
});
