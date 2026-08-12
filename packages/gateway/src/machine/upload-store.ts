import { randomUUID } from "node:crypto";
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { basename, extname, join } from "node:path";
import type { ImageContent } from "@earendil-works/pi-ai";
import { GatewayError } from "../errors.js";
import { atomicWriteJson, readJson } from "../util/json.js";

interface UploadMetadata {
  version: 1;
  id: string;
  name: string;
  mimeType: string;
  size: number;
  path: string;
  createdAt: string;
  sessionId?: string;
}

function safeName(input: string): string {
  const name = basename(input).replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 160);
  return name || "attachment";
}

function xml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

export class UploadStore {
  private readonly directory: string;

  constructor(
    tronHome: string,
    private readonly maximumBytes: number,
  ) {
    this.directory = join(tronHome, "gateway", "uploads");
  }

  async save(nameInput: string, mimeType: string, body: Buffer): Promise<UploadMetadata> {
    if (body.length === 0 || body.length > this.maximumBytes) {
      throw new GatewayError("invalid_request", `Upload must contain 1 through ${this.maximumBytes} bytes`);
    }
    const id = randomUUID();
    const name = safeName(nameInput);
    const extension = extname(name).slice(0, 20);
    const folder = join(this.directory, id);
    await mkdir(folder, { recursive: true, mode: 0o700 });
    const path = join(folder, `content${extension}`);
    await writeFile(path, body, { mode: 0o600, flag: "wx" });
    const metadata: UploadMetadata = {
      version: 1,
      id,
      name,
      mimeType: mimeType.slice(0, 200) || "application/octet-stream",
      size: body.length,
      path: await realpath(path),
      createdAt: new Date().toISOString(),
    };
    await atomicWriteJson(join(folder, "metadata.json"), metadata);
    return metadata;
  }

  async prepareSessionImport(id: string): Promise<string> {
    if (!/^[0-9a-f-]{36}$/.test(id)) throw new GatewayError("invalid_request", "Upload id is invalid");
    const metadata = await readJson<UploadMetadata | null>(join(this.directory, id, "metadata.json"), null);
    if (!metadata || metadata.id !== id) throw new GatewayError("not_found", "Upload was not found");
    const actual = await realpath(metadata.path);
    const ownedDirectory = await realpath(join(this.directory, id));
    if (!actual.startsWith(`${ownedDirectory}/`)) throw new GatewayError("conflict", "Upload metadata escaped its owned directory");
    const importPath = join(ownedDirectory, `tron-import-${id}.jsonl`);
    await writeFile(importPath, await readFile(actual), { mode: 0o600, flag: "wx" }).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "EEXIST") throw error;
    });
    return realpath(importPath);
  }

  async materialize(ids: string[], sessionId: string): Promise<{ images: ImageContent[]; envelope: string }> {
    if (ids.length > 10) throw new GatewayError("invalid_request", "At most 10 attachments may be sent with one prompt");
    const images: ImageContent[] = [];
    const envelopes: string[] = [];
    for (const id of ids) {
      if (!/^[0-9a-f-]{36}$/.test(id)) throw new GatewayError("invalid_request", "Upload id is invalid");
      const metadataPath = join(this.directory, id, "metadata.json");
      const metadata = await readJson<UploadMetadata | null>(metadataPath, null);
      if (!metadata || metadata.id !== id) throw new GatewayError("not_found", "Upload was not found");
      const actual = await realpath(metadata.path);
      const ownedDirectory = await realpath(join(this.directory, id));
      if (!actual.startsWith(`${ownedDirectory}/`)) throw new GatewayError("conflict", "Upload metadata escaped its owned directory");
      if (metadata.mimeType.startsWith("image/")) {
        images.push({ type: "image", data: (await readFile(actual)).toString("base64"), mimeType: metadata.mimeType });
      } else {
        envelopes.push(`<attachment name="${xml(metadata.name)}" mime-type="${xml(metadata.mimeType)}" size="${metadata.size}" path="${xml(actual)}" />`);
      }
      await atomicWriteJson(metadataPath, { ...metadata, sessionId });
    }
    return { images, envelope: envelopes.join("\n") };
  }
}
