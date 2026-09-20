import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { GatewayService, type ClientContext } from "./gateway-service.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const client = (): ClientContext => ({ id: "connection-object", identity: "local-wrapper", isLocal: true, beginSynchronization: () => "sync", establishSynchronization() {}, completeSynchronization() {}, unsubscribe: () => true, attachTerminal() {}, detachTerminal() {}, ownsTerminal: () => false, isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {} });

function service(chunk: (params: Record<string, unknown>) => unknown): GatewayService {
  const root = join(tmpdir(), `tron-gateway-object-${Date.now()}-${Math.random().toString(16).slice(2)}`); roots.push(root);
  return new GatewayService({ config: { tronHome: root }, knowledge: { invoke: async (_action: unknown) => chunk((_action as { request: Record<string, unknown> }).request) }, receipts: { execute: async (_identity: string, _method: string, _command: string, operation: () => Promise<unknown>) => operation() } } as any);
}

describe("Gateway knowledge object transport", () => {
  it.each([306_865, 1_100_003])("preserves exact bytes and continuations for a %i-byte object", async size => {
    const bytes = Buffer.alloc(size);
    for (let index = 0; index < bytes.length; index += 1) bytes[index] = index % 251;
    const hash = createHash("sha256").update(bytes).digest("hex");
    const gateway = service(params => {
      const offset = Number(params.offset ?? 0); const chunk = bytes.subarray(offset, Math.min(bytes.length, offset + 512_000));
      return { hash, mediaType: "application/octet-stream", bytes: chunk.length, totalBytes: bytes.length, offset, ...(offset + chunk.length < bytes.length ? { nextOffset: offset + chunk.length } : {}), base64: chunk.toString("base64") };
    });
    let offset = 0; const pieces: Buffer[] = [];
    for (;;) {
      const result = await gateway.invoke(client(), "knowledge.object.read", { recordId: "record-object", revisionId: "revision-object", hash, mediaType: "application/octet-stream", bytes: bytes.length, offset }) as any;
      if (offset === 0) expect(result.base64.length).toBeGreaterThan(100_000);
      const piece = Buffer.from(result.base64, "base64");
      expect(piece.length).toBe(result.bytes);
      pieces.push(piece);
      if (result.nextOffset === undefined) break;
      expect(result.nextOffset).toBe(offset + piece.length);
      offset = result.nextOffset;
    }
    expect(pieces.length).toBe(Math.ceil(size / 512_000));
    const rebuilt = Buffer.concat(pieces);
    expect(rebuilt.equals(bytes)).toBe(true);
    expect(createHash("sha256").update(rebuilt).digest("hex")).toBe(hash);
  });

  it("keeps an authorized missing object as null and rejects inconsistent bounded chunks", async () => {
    const missing = service(() => null);
    await expect(missing.invoke(client(), "knowledge.object.read", {})).resolves.toBeNull();
    const invalid = service(() => ({ hash: "a".repeat(64), mediaType: "application/octet-stream", bytes: 75_000, totalBytes: 75_000, offset: 0, base64: Buffer.alloc(74_999).toString("base64") }));
    await expect(invalid.invoke(client(), "knowledge.object.read", {})).rejects.toMatchObject({ code: "internal" });
    const noContinuation = service(() => ({ hash: "c".repeat(64), mediaType: "text/plain", bytes: 1, totalBytes: 2, offset: 0, base64: "YQ==" }));
    await expect(noContinuation.invoke(client(), "knowledge.object.read", {})).rejects.toMatchObject({ code: "internal" });
    const oversized = service(() => ({ hash: "b".repeat(64), mediaType: "application/octet-stream", bytes: 512_001, totalBytes: 512_001, offset: 0, base64: Buffer.alloc(512_001).toString("base64") }));
    await expect(oversized.invoke(client(), "knowledge.object.read", {})).rejects.toMatchObject({ code: "internal" });
  });
});
