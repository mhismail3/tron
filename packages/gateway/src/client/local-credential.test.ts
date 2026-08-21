import { chmod, mkdir, mkdtemp, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { readLocalCredential } from "./local-credential.js";

async function credentialPath(): Promise<{ root: string; path: string }> {
  const root = await mkdtemp(join(tmpdir(), "tron-local-credential-"));
  const directory = join(root, "gateway");
  await mkdir(directory);
  return { root, path: join(directory, "local-auth.json") };
}

function document(token = "t".repeat(32)) {
  return {
    version: 2,
    bearerToken: token,
    purpose: "local-wrapper-health",
    lastUpdated: "2026-01-01T00:00:00.000Z",
  };
}

describe("bounded local wrapper credential", () => {
  it("admits the exact file ceiling", async () => {
    const { root, path } = await credentialPath();
    const compact = JSON.stringify(document());
    const exact = `${compact}${" ".repeat(64 * 1_024 - Buffer.byteLength(compact))}`;
    await writeFile(path, exact, { mode: 0o600 });

    await expect(readLocalCredential(root)).resolves.toBe("t".repeat(32));
  });

  it.each([
    ["missing", undefined],
    ["malformed", "{not-json"],
    ["oversized", "x".repeat(64 * 1_024 + 1)],
    ["wrong purpose", JSON.stringify({ ...document(), purpose: "device" })],
    ["unknown field", JSON.stringify({ ...document(), extra: true })],
    ["short token", JSON.stringify(document("short"))],
    ["empty", ""],
  ])("rejects %s credentials consistently", async (_label, content) => {
    const { root, path } = await credentialPath();
    if (content !== undefined) await writeFile(path, content, { mode: 0o600 });

    await expect(readLocalCredential(root)).rejects.toThrow(/missing or invalid/);
  });

  it.each(["permissive mode", "symlink"])("rejects %s credentials", async (boundary) => {
    const { root, path } = await credentialPath();
    if (boundary === "permissive mode") {
      await writeFile(path, JSON.stringify(document()), { mode: 0o640 });
      await chmod(path, 0o640);
    } else {
      const external = join(root, "external-auth.json");
      await writeFile(external, JSON.stringify(document()), { mode: 0o600 });
      await symlink(external, path);
    }

    await expect(readLocalCredential(root)).rejects.toThrow(/missing or invalid/);
  });
});
