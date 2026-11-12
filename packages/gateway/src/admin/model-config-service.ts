import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { readJson, updateJsonLocked } from "../foundation/json.js";
import { modelProviderOnDisk, type ModelProviderValue } from "../kernel/settings/model-provider-value.js";

const MODEL_CONFIG_MAX_BYTES = 768 * 1_024;
const MODEL_CONFIG_MAX_DEPTH = 64;
const MODEL_CONFIG_MAX_NODES = 32_768;
const MODEL_CONFIG_MAX_COLLECTION_MEMBERS = 8_192;
const MODEL_CONFIG_MAX_PROVIDERS = 100;

function assertBoundedDocument(
  value: unknown,
  code: "invalid_request" | "conflict",
  enforceCanonicalBytes = false,
): void {
  const pending: Array<{ value: unknown; depth: number }> = [{ value, depth: 0 }];
  let nodes = 0;
  while (pending.length > 0) {
    const current = pending.pop()!;
    nodes += 1;
    if (nodes > MODEL_CONFIG_MAX_NODES) throw new GatewayError(code, "Custom model configuration exceeds its node limit");
    if (current.depth > MODEL_CONFIG_MAX_DEPTH) throw new GatewayError(code, "Custom model configuration exceeds its depth limit");
    if (current.value === null || ["string", "boolean"].includes(typeof current.value)) continue;
    if (typeof current.value === "number") {
      if (!Number.isFinite(current.value)) throw new GatewayError(code, "Custom model configuration contains a non-finite number");
      continue;
    }
    if (typeof current.value !== "object") throw new GatewayError(code, "Custom model configuration contains non-JSON data");
    const values = Array.isArray(current.value) ? current.value : Object.values(current.value);
    if (values.length > MODEL_CONFIG_MAX_COLLECTION_MEMBERS) {
      throw new GatewayError(code, "Custom model configuration exceeds its collection limit");
    }
    for (const child of values) pending.push({ value: child, depth: current.depth + 1 });
  }
  if (enforceCanonicalBytes) canonicalDocument(value, code);
}

function canonicalDocument(value: unknown, code: "invalid_request" | "conflict"): string {
  const encoded = `${JSON.stringify(value, null, 2)}\n`;
  if (Buffer.byteLength(encoded) > MODEL_CONFIG_MAX_BYTES) {
    throw new GatewayError(code, "Custom model configuration exceeds its 768 KiB limit");
  }
  return encoded;
}

function boundedReadFailure(error: unknown): never {
  if (error instanceof RangeError || error instanceof SyntaxError) {
    throw new GatewayError("conflict", "Canonical custom model configuration is invalid or exceeds its 768 KiB limit");
  }
  throw error;
}

function redact(value: unknown, key = ""): unknown {
  if (/key|secret|token|authorization/i.test(key) && typeof value === "string") return "<redacted>";
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(Object.entries(value).map(([childKey, child]) => [childKey, redact(child, childKey)]));
  }
  return value;
}

function providersOf(document: Record<string, unknown>): Record<string, unknown> {
  const providers = document.providers ?? {};
  if (typeof providers !== "object" || providers === null || Array.isArray(providers)) {
    throw new GatewayError("conflict", "Custom model configuration has no valid providers object");
  }
  return providers as Record<string, unknown>;
}

export class ModelConfigService {
  private readonly path: string;

  constructor(agentDir: string) {
    this.path = join(agentDir, "models.json");
  }

  async get(): Promise<{ document: unknown; redacted: boolean }> {
    const document = await this.read();
    const redactedDocument = redact(document);
    return { document: redactedDocument, redacted: JSON.stringify(document) !== JSON.stringify(redactedDocument) };
  }

  async provider(id: string): Promise<ModelProviderValue | undefined> {
    const raw = providersOf(await this.read())[id];
    return raw === undefined ? undefined : modelProviderOnDisk(id, raw);
  }

  async setProvider(id: string, value: ModelProviderValue | undefined): Promise<void> {
    try {
      await updateJsonLocked<Record<string, unknown>>(this.path, { providers: {} }, (current) => {
        assertBoundedDocument(current, "conflict");
        const providers = { ...providersOf(current) };
        const existing = providers[id];
        if (existing !== undefined) modelProviderOnDisk(id, existing);
        if (value === undefined) {
          if (existing === undefined) return current;
          delete providers[id];
        } else {
          if (existing === undefined && Object.keys(providers).length >= MODEL_CONFIG_MAX_PROVIDERS) {
            throw new GatewayError("invalid_request", `At most ${MODEL_CONFIG_MAX_PROVIDERS} custom providers are allowed`);
          }
          providers[id] = value;
        }
        const next = { ...current, providers };
        assertBoundedDocument(next, "conflict", true);
        return next;
      }, MODEL_CONFIG_MAX_BYTES);
    } catch (error) {
      boundedReadFailure(error);
    }
  }

  private async read(): Promise<Record<string, unknown>> {
    let document: Record<string, unknown>;
    try {
      document = await readJson<Record<string, unknown>>(this.path, { providers: {} }, MODEL_CONFIG_MAX_BYTES);
    } catch (error) {
      boundedReadFailure(error);
    }
    assertBoundedDocument(document, "conflict");
    return document;
  }
}
