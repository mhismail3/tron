import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it, vi } from "vitest";
import { MacKeychainConnectorCredentialStore } from "./connector-credentials.js";

const execFileAsync = promisify(execFile);

vi.mock("node:child_process", async importOriginal => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, spawn: vi.fn(actual.spawn) };
});

async function withTestKeychain(run: (path: string) => Promise<void>): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "tron-connector-keychain- '\"\\$#-"));
  const path = join(directory, "test.keychain-db");
  const password = randomUUID();
  try {
    await execFileAsync("security", ["create-keychain", "-p", password, path], { timeout: 5_000 });
    await execFileAsync("security", ["set-keychain-settings", path], { timeout: 5_000 });
    await execFileAsync("security", ["unlock-keychain", "-p", password, path], { timeout: 5_000 });
    await run(path);
  } finally {
    try {
      if (existsSync(path)) await execFileAsync("security", ["delete-keychain", path], { timeout: 5_000 });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
}

describe("MacKeychainConnectorCredentialStore", () => {
  it("refuses the default keychain in tests", () => {
    expect(() => new MacKeychainConnectorCredentialStore()).toThrow("Connector credential tests require an explicit keychain path");
    expect(() => new MacKeychainConnectorCredentialStore(undefined, "")).toThrow("Connector credential tests require an explicit keychain path");
  });

  it.skipIf(process.platform !== "darwin")("writes, replaces, reads and deletes only in a private keychain", async () => {
    await withTestKeychain(async path => {
      const service = `Tron Connector Credentials Test "'\\ $ # café ${randomUUID()}`;
      const store = new MacKeychainConnectorCredentialStore(service, path);
      const reference = `connector:x:keychain-test-${randomUUID()}`;
      const value = `  secret with spaces "double" 'single' \\ $ # ${randomUUID()}  `;
      expect(await store.read(reference)).toBeUndefined();
      await store.write(reference, value);
      expect(await store.read(reference)).toBe(value);
      // Independently verify the explicit target, rather than only reading back
      // through an adapter that could share a targeting bug with its writer.
      const result = await execFileAsync("security", ["find-generic-password", "-s", service, "-a", reference, "-w", path], { timeout: 5_000 });
      expect(result.stdout).toBe(`${value}\n`);
      await store.write(reference, "replacement");
      expect(await store.read(reference)).toBe("replacement");
      await store.delete(reference);
      expect(await store.read(reference)).toBeUndefined();
      await store.delete(reference);
    });
  });

  it.each([
    { name: "empty", value: "", error: "Connector credential is invalid" },
    { name: "NUL", value: "nul\u0000", error: "Connector credential is invalid" },
    { name: "tab", value: "tab\t", error: "Connector credential is invalid" },
    { name: "newline", value: "newline\n", error: "Connector credential is invalid" },
    { name: "carriage return", value: "return\r", error: "Connector credential is invalid" },
    { name: "escape", value: "escape\u001b", error: "Connector credential is invalid" },
    { name: "DEL", value: "delete\u007f", error: "Connector credential is invalid" },
    { name: "C1 control", value: "control\u0085", error: "Connector credential is invalid" },
    { name: "Unicode", value: "café 🔑", error: "Connector credential is invalid" },
    { name: "unpaired surrogate", value: "surrogate\ud800", error: "Connector credential is invalid" },
    { name: "oversized ASCII", value: "a".repeat(4_096), error: "Mac Keychain credential command is too long" },
    { name: "oversized escaped text", value: "\\".repeat(2_048), error: "Mac Keychain credential command is too long" },
  ])("refuses $name before starting security", async ({ value, error }) => {
    const directory = await mkdtemp(join(tmpdir(), "tron-connector-keychain-admission-"));
    try {
      // No keychain is needed: every input must fail admission before spawning.
      // This sentinel also makes negative controls safe from any OS access.
      vi.mocked(spawn).mockImplementation(() => { throw new Error("Invalid input reached security"); });
      const store = new MacKeychainConnectorCredentialStore(undefined, join(directory, "test.keychain-db"));
      const reference = "connector:x:invalid-input";
      const operation = store.write(reference, value);
      await expect(operation).rejects.toThrow(error);
      if (value && error === "Connector credential is invalid") await expect(operation).rejects.toBeInstanceOf(TypeError);
    } finally {
      vi.mocked(spawn).mockRestore();
      await rm(directory, { recursive: true, force: true });
    }
  });
});
