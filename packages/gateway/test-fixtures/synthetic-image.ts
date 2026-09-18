import { crc32, deflateSync } from "node:zlib";

/**
 * Synthetic PNG bytes for image-bound tests. The encoder writes only a
 * gradient RGB raster, so the fixture stays small while remaining a real PNG
 * the pinned image backend can decode. It contains no user or host data.
 */
export function syntheticPng(width: number, height: number): Buffer {
  const stride = width * 3 + 1;
  const raster = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y += 1) {
    const row = y * stride;
    raster[row] = 0;
    for (let x = 0; x < width; x += 1) {
      const pixel = row + 1 + x * 3;
      raster[pixel] = (x * 7) & 0xff;
      raster[pixel + 1] = (y * 11) & 0xff;
      raster[pixel + 2] = ((x + y) * 3) & 0xff;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8; // bit depth
  header[9] = 2; // color type: truecolor
  return Buffer.concat([
    Buffer.from("89504e470d0a1a0a", "hex"),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(raster)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function pngChunk(type: string, data: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(body) >>> 0);
  return Buffer.concat([length, body, checksum]);
}
