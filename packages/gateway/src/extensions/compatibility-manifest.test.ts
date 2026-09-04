import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  EXTENSION_PRESENTATION_VERSION,
  PINNED_PI_VERSION,
  extensionEventCompatibility,
  extensionToolAdapterCompatibility,
  remoteTuiFeasibilityCompatibility,
} from "./compatibility-manifest.js";

const gatewayPackage = JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8")) as {
  dependencies: Record<string, string>;
};
const expectedPiVersion = gatewayPackage.dependencies["@earendil-works/pi-coding-agent"];

describe("pinned public Pi extension-host contract", () => {
  it("projects supported extension interactions into bounded Gateway capabilities", () => {
    expect(EXTENSION_PRESENTATION_VERSION).toBeGreaterThan(0);
    expect(PINNED_PI_VERSION).toBe(expectedPiVersion);
    expect(extensionEventCompatibility).toMatchObject({
      session_compact_failed: { classification: "pi-runtime", capability: "event.session-compact-failed" },
      ui_prompt_start: { classification: "pi-runtime", capability: "event.ui-prompt-start" },
      ui_prompt_end: { classification: "pi-runtime", capability: "event.ui-prompt-end" },
    });
    expect(extensionToolAdapterCompatibility.tronDisplay).toMatchObject({
      classification: "native-semantic",
      capability: "display-artifacts.v1",
    });
    expect(extensionToolAdapterCompatibility.zhushanwenAskUserForm).toMatchObject({
      classification: "native-semantic",
      capability: "form.v1",
    });
    expect(remoteTuiFeasibilityCompatibility.presentationStore.capability)
      .toBe("presentation.aggregate-revision");
  });
});
