import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { readJson, updateJsonLocked } from "../util/json.js";
import { object } from "../util/validation.js";

function redact(value: unknown, key = ""): unknown {
  if (/key|secret|token|authorization/i.test(key) && typeof value === "string") return "<redacted>";
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(Object.entries(value).map(([childKey, child]) => [childKey, redact(child, childKey)]));
  }
  return value;
}

function restoreRedacted(next: unknown, previous: unknown): unknown {
  if (next === "<redacted>") {
    if (previous === undefined) {
      throw new GatewayError("invalid_request", "A redacted secret cannot be written without a canonical value");
    }
    return previous;
  }
  if (Array.isArray(next)) {
    const prior = Array.isArray(previous) ? previous : [];
    return next.map((value, index) => restoreRedacted(value, prior[index]));
  }
  if (typeof next === "object" && next !== null) {
    const prior = typeof previous === "object" && previous !== null && !Array.isArray(previous)
      ? previous as Record<string, unknown>
      : {};
    return Object.fromEntries(Object.entries(next).map(([key, value]) => [key, restoreRedacted(value, prior[key])]));
  }
  return next;
}

export class ModelConfigService {
  private readonly path: string;

  constructor(agentDir: string) {
    this.path = join(agentDir, "models.json");
  }

  async get(): Promise<{ document: unknown; redacted: boolean }> {
    const document = await readJson<Record<string, unknown>>(this.path, { providers: {} });
    return { document: redact(document), redacted: JSON.stringify(document) !== JSON.stringify(redact(document)) };
  }

  async validate(raw: unknown): Promise<{ valid: true; providerCount: number }> {
    const document = object(raw, "models document");
    const providers = object(document.providers, "models.providers");
    if (Object.keys(providers).length > 100) throw new GatewayError("invalid_request", "At most 100 custom providers are allowed");
    for (const [providerId, value] of Object.entries(providers)) {
      if (!/^[a-z0-9][a-z0-9._-]{0,119}$/i.test(providerId)) throw new GatewayError("invalid_request", `Invalid provider id: ${providerId}`);
      const provider = object(value, `provider ${providerId}`);
      if (provider.models !== undefined && !Array.isArray(provider.models)) throw new GatewayError("invalid_request", `provider ${providerId}.models must be an array`);
      if (Array.isArray(provider.models) && provider.models.length > 500) throw new GatewayError("invalid_request", `provider ${providerId} has too many models`);
    }

    // Let Tron's pinned runtime validate the complete native schema rather
    // than maintaining a second, inevitably drifting models.json schema.
    const root = await mkdtemp(join(tmpdir(), "tron-model-validation-"));
    const candidate = join(root, "models.json");
    try {
      await writeFile(candidate, `${JSON.stringify(document)}\n`, { mode: 0o600 });
      const runtime = await ModelRuntime.create({ modelsPath: candidate, refreshOnCreate: false });
      const error = runtime.getError();
      if (error) throw new GatewayError("invalid_request", `Custom model configuration is invalid: ${error}`);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
    return { valid: true, providerCount: Object.keys(providers).length };
  }

  async put(raw: unknown): Promise<{ requiresRestart: true }> {
    const document = object(raw, "models document");
    await this.validate(document);
    await updateJsonLocked<Record<string, unknown>>(this.path, { providers: {} }, (current) =>
      restoreRedacted(document, current) as Record<string, unknown>);
    return { requiresRestart: true };
  }
}
