import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { TrustService } from "./trust-service.js";

describe("TrustService", () => {
  it("blocks project executable resources until an explicit decision", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-trust-"));
    const workspace = join(root, "workspace");
    const agentDir = join(root, "agent");
    await mkdir(join(workspace, ".pi"), { recursive: true });
    await writeFile(join(workspace, ".pi", "settings.json"), "{}\n");
    const trust = new TrustService(agentDir);

    await expect(trust.requireResolved(workspace)).rejects.toMatchObject({ code: "trust_required" });
    await expect(trust.set(workspace, true)).resolves.toMatchObject({ effectiveDecision: true });
    const resolved = await trust.requireResolved(workspace);
    expect(resolved.trusted).toBe(true);
    expect(resolved.cwd).toMatch(/\/workspace$/);
    await expect(trust.set(workspace, false)).resolves.toMatchObject({ effectiveDecision: false });
  });
});
