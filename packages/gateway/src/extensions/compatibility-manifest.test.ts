import { describe, expect, it } from "vitest";
import {
  EXTENSION_PRESENTATION_VERSION,
  extensionToolAdapterCompatibility,
  remoteTuiFeasibilityCompatibility,
} from "./compatibility-manifest.js";

describe("pinned public Pi extension-host contract", () => {
  it("projects supported extension interactions into bounded Gateway capabilities", () => {
    expect(EXTENSION_PRESENTATION_VERSION).toBeGreaterThan(0);
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
