import { access, readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import * as pi from "@earendil-works/pi-coding-agent";
import * as tui from "@earendil-works/pi-tui";
import { describe, expect, it } from "vitest";
import { EXTENSION_PRESENTATION_VERSION, extensionToolAdapterCompatibility, officialExampleInventory, PINNED_PI_VERSION, remoteTuiFeasibilityCompatibility } from "./compatibility-manifest.js";

describe("pinned public Pi extension-host contract", () => {
  it("keeps exact direct dependency pins and public runtime versions", async () => {
    const packageJSON = JSON.parse(await readFile(new URL("../../package.json", import.meta.url), "utf8")) as { dependencies: Record<string, string> };
    const lock = JSON.parse(await readFile(new URL("../../package-lock.json", import.meta.url), "utf8")) as { packages: Record<string, { version?: string }> };
    const directPiPackages = [
      "@earendil-works/pi-agent-core",
      "@earendil-works/pi-ai",
      "@earendil-works/pi-coding-agent",
      "@earendil-works/pi-tui",
    ];
    for (const packageName of directPiPackages) {
      expect(packageJSON.dependencies[packageName], packageName).toBe(PINNED_PI_VERSION);
      expect(lock.packages[`node_modules/${packageName}`]?.version, packageName).toBe(PINNED_PI_VERSION);
    }
    expect(pi.VERSION).toBe(PINNED_PI_VERSION);
    expect(EXTENSION_PRESENTATION_VERSION).toBe(3);
    expect(extensionToolAdapterCompatibility).toEqual({
      zhushanwenAskUserForm: expect.objectContaining({
        classification: "native-semantic",
        capability: "form.v1",
      }),
    });
    expect(remoteTuiFeasibilityCompatibility.presentationStore.capability).toBe("presentation.aggregate-revision");
  });

  it("exposes the public component-host seams used by the Phase 4A harness", () => {
    for (const key of [
      "TuiMainScreen", "TuiAltScreen", "KeybindingsManager", "Editor", "CombinedAutocompleteProvider",
      "CURSOR_MARKER", "visibleWidth", "truncateToWidth", "setCapabilities", "getCapabilities",
    ] as const) {
      expect(tui[key], `missing public @earendil-works/pi-tui export ${key}`).toBeDefined();
    }
    for (const key of ["AgentSessionRuntime", "Theme", "initTheme", "getMarkdownTheme", "getExamplesPath"] as const) {
      expect(pi[key], `missing public coding-agent export ${key}`).toBeDefined();
    }
    expect(Object.keys(remoteTuiFeasibilityCompatibility)).toEqual([
      "terminal", "composition", "recording", "frameParser", "presentationStore", "fullFrames",
      "inputLeaseProjection", "terminalImages", "kittyKeyRelease",
    ]);
    expect(remoteTuiFeasibilityCompatibility.terminal.limitation).toContain("production read-only component widgets");
    expect(remoteTuiFeasibilityCompatibility.terminal.limitation).toContain("remote input remains unavailable");
  });

  it("keeps the feasibility harness on package-root imports", async () => {
    const hostRoot = new URL("host/", import.meta.url);
    const files = (await readdir(hostRoot)).filter((name) => name.endsWith(".ts"));
    for (const file of files) {
      const source = await readFile(new URL(file, hostRoot), "utf8");
      expect(source, file).not.toMatch(/@earendil-works\/pi-(?:coding-agent|tui)\//);
      expect(source, file).not.toContain("ProcessTerminal");
      expect(source, file).not.toContain("InteractiveMode");
    }
  });

  it("keeps production runtime binding RPC-only while the component host stays dormant", async () => {
    const source = await readFile(new URL("../sessions/runtime-slot.ts", import.meta.url), "utf8");
    expect(source).toContain('mode: "rpc"');
    expect(source).not.toContain("InteractiveMode");
    expect(source).not.toMatch(/@earendil-works\/pi-(?:coding-agent|tui)\//);
  });

  it("keeps the complete classified official example inventory in sync", async () => {
    const extensionRoot = join(pi.getExamplesPath(), "extensions");
    const discovered = (await readdir(extensionRoot, { recursive: true, withFileTypes: true }))
      .filter((entry) => entry.isFile())
      .map((entry) => join(entry.parentPath.slice(extensionRoot.length + 1), entry.name))
      .sort();
    const inventoried = officialExampleInventory.map(({ path }) => path).sort();
    expect(inventoried).toEqual(discovered);
    await Promise.all(inventoried.map((relativePath) => access(join(extensionRoot, relativePath))));
  });
});
