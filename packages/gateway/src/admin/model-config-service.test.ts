import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { MODEL_CONFIG_MAX_BYTES, ModelConfigService } from "./model-config-service.js";

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

  it("bounds canonical reads, locked updates, validation bytes, and redaction depth", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-model-config-bounds-"));
    const path = join(root, "models.json");
    const service = new ModelConfigService(root);

    await writeFile(path, JSON.stringify({ providers: {}, padding: "x".repeat(MODEL_CONFIG_MAX_BYTES) }));
    await expect(service.get()).rejects.toMatchObject({ code: "conflict" });
    await expect(service.put({ providers: {} })).rejects.toMatchObject({ code: "conflict" });
    await expect(service.validate({ providers: {}, padding: "x".repeat(MODEL_CONFIG_MAX_BYTES) }))
      .rejects.toMatchObject({ code: "invalid_request" });

    let nested: Record<string, unknown> = { value: "secret" };
    for (let depth = 0; depth < 65; depth += 1) nested = { nested };
    await writeFile(path, JSON.stringify({ providers: {}, nested }));
    await expect(service.get()).rejects.toMatchObject({ code: "conflict" });

    const canonical = {
      providers: {
        custom: {
          baseUrl: "http://localhost:1234/v1",
          api: "openai-completions",
          apiKey: "s".repeat(700_000),
          models: [],
        },
      },
    };
    const canonicalText = `${JSON.stringify(canonical, null, 2)}\n`;
    expect(Buffer.byteLength(canonicalText)).toBeLessThan(MODEL_CONFIG_MAX_BYTES);
    await writeFile(path, canonicalText);
    const redacted = await service.get() as { document: Record<string, unknown> };
    const expanded = { ...redacted.document, padding: "x".repeat(100_000) };
    await expect(service.put(expanded)).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(path, "utf8")).toBe(canonicalText);
  });

  it("admits the native empty configuration", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-model-config-"));
    const service = new ModelConfigService(root);
    await expect(service.validate({ providers: {} })).resolves.toEqual({ valid: true, providerCount: 0 });
  });
});
