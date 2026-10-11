import type { ImageContent } from "@earendil-works/pi-ai";

/** Synthetic 3×2 RGBA PNG. It contains no user or host data. */
export const SYNTHETIC_NATIVE_IMAGE: ImageContent = {
  type: "image",
  data: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEUlEQVR4nGP4z8DwH4YZkDkAm34L9XKwuTwAAAAASUVORK5CYII=",
  mimeType: "image/png",
};

export interface PngDimensions {
  width: number;
  height: number;
}

/** Decode only PNG metadata needed by this fixture; no image pixels are written. */
export function pngDimensions(image: ImageContent): PngDimensions {
  const bytes = Buffer.from(image.data, "base64");
  if (bytes.length < 24 || bytes.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a" || bytes.subarray(12, 16).toString("ascii") !== "IHDR") {
    throw new Error("fixture image is not a PNG with an IHDR chunk");
  }
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}
