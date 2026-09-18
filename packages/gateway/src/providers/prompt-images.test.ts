import type { ImageContent } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import { pngDimensions, SYNTHETIC_NATIVE_IMAGE } from "../../test-fixtures/pi-sdk/computer-use-image.js";
import { syntheticPng } from "../../test-fixtures/synthetic-image.js";
import { boundPromptImages } from "./prompt-images.js";

function png(width: number, height: number): ImageContent {
  return { type: "image", data: syntheticPng(width, height).toString("base64"), mimeType: "image/png" };
}

describe("prompt image bounds", () => {
  it("bounds a full-resolution attachment to Pi's image limits without reordering attachments", async () => {
    const screenshot = png(1320, 2868);
    const small = SYNTHETIC_NATIVE_IMAGE;

    const bounded = await boundPromptImages([screenshot, small]);

    expect(bounded).toHaveLength(2);
    const first = bounded[0]!;
    const dimensions = pngDimensions(first);
    expect(Math.max(dimensions.width, dimensions.height)).toBe(2000);
    expect(dimensions.width / dimensions.height).toBeCloseTo(1320 / 2868, 2);
    expect(first.mimeType.startsWith("image/")).toBe(true);
    // Bounding must never drop or replace the attachment's identity.
    expect(bounded[1]).toEqual(small);
  });

  it("keeps an already bounded attachment byte-for-byte", async () => {
    const [bounded] = await boundPromptImages([SYNTHETIC_NATIVE_IMAGE]);
    expect(bounded).toEqual(SYNTHETIC_NATIVE_IMAGE);
  });

  it("keeps the original attachment when the pinned image backend cannot decode it", async () => {
    const undecodable: ImageContent = { type: "image", data: Buffer.from("not an image").toString("base64"), mimeType: "image/png" };
    expect(await boundPromptImages([undecodable])).toEqual([undecodable]);
  });
});
