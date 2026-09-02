import { describe, expect, it } from "vitest";
import {
  DISPLAY_EMBEDDED_MEDIA_MAXIMUM_BYTES,
  DISPLAY_MAXIMUM_ARTIFACT_BYTES,
  admitDisplayProjection,
  eligibleDisplaySurfaces,
  normalizePublicDisplayURL,
} from "./display-contract.js";

function details(overrides: Record<string, unknown> = {}) {
  return {
    display: {
      schema: "tron.display.v1",
      displayId: "display-id",
      revision: 1,
      title: "Preview",
      altText: "A bounded preview.",
      kind: "image",
      presentation: { requestedSurface: "floating", inlineTapAction: "sheet" },
      eligibleSurfaces: ["sheet", "inline", "floating"],
      fallbackText: "A bounded preview.",
      artifact: {
        id: "26ad0866-c22a-4c36-b9e3-22cd933bf550",
        name: "preview.png",
        mimeType: "image/png",
        size: 128,
        kind: "image",
      },
      ...overrides,
    },
  };
}

describe("display contract", () => {
  it("admits the exact reserved tool envelope and computes closed surface eligibility", () => {
    expect(admitDisplayProjection("display", details())).toMatchObject({
      schema: "tron.display.v1",
      kind: "image",
      eligibleSurfaces: ["sheet", "inline", "floating"],
    });
    expect(eligibleDisplaySurfaces("html")).toEqual(["sheet", "floating"]);
    expect(eligibleDisplaySurfaces("webpage")).toEqual(["sheet"]);
    expect(eligibleDisplaySurfaces("video", DISPLAY_EMBEDDED_MEDIA_MAXIMUM_BYTES + 1)).toEqual(["sheet"]);
  });

  it("fails closed for spoofed tools, mismatched kinds, and unsafe URLs", () => {
    expect(admitDisplayProjection("other", details())).toBeUndefined();
    expect(admitDisplayProjection("display", { ...details(), extra: true })).toBeUndefined();
    expect(admitDisplayProjection("display", details({ extra: true }))).toBeUndefined();
    expect(admitDisplayProjection("display", details({ kind: "pdf" }))).toBeUndefined();
    expect(admitDisplayProjection("display", details({
      artifact: { id: "not-a-uuid", name: "preview.png", mimeType: "image/png", size: 128, kind: "image" },
    }))).toBeUndefined();
    expect(admitDisplayProjection("display", details({
      artifact: {
        id: "26ad0866-c22a-4c36-b9e3-22cd933bf550",
        name: "preview.png",
        mimeType: "image/png",
        size: DISPLAY_MAXIMUM_ARTIFACT_BYTES + 1,
        kind: "image",
      },
    }))).toBeUndefined();
    expect(admitDisplayProjection("display", details({
      kind: "webpage",
      artifact: undefined,
      remoteURL: "http://example.com",
      eligibleSurfaces: ["sheet"],
    }))).toBeUndefined();
    expect(admitDisplayProjection("display", details({
      kind: "webpage",
      artifact: undefined,
      remoteURL: "https://user:secret@example.com",
      eligibleSurfaces: ["sheet"],
    }))).toBeUndefined();
    for (const remote of [
      "https://127.0.0.1/page",
      "https://localhost./page",
      "https://[::1]/page",
      "https://[fc00::1]/page",
      "https://[::ffff:127.0.0.1]/page",
      "https://example.com/page?token=secret",
      "https://example.com/page#credential",
    ]) expect(normalizePublicDisplayURL(remote)).toBeUndefined();
    expect(normalizePublicDisplayURL("https://example.com/page")).toBe("https://example.com/page");
  });
});
