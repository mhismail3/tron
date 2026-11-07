import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { publicError } from "../errors.js";
import { FilesystemService } from "./filesystem-service.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

it("answers a missing path not_found and an existing folder conflict, not an internal failure", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-filesystem-service-"));
  roots.push(root);
  await mkdir(join(root, "kept"));
  const service = new FilesystemService(root);
  const refusal = (operation: Promise<unknown>) => operation.then(() => undefined, error => publicError(error));
  const missing = { code: "not_found", message: "Path does not exist", retryable: false };
  expect(await refusal(service.list(join(root, "gone")))).toEqual(missing);
  expect(await refusal(service.inspectGit(join(root, "gone")))).toEqual(missing);
  await writeFile(join(root, "note.txt"), "x");
  expect(await refusal(service.list(join(root, "note.txt", "child")))).toEqual(missing);
  expect(await refusal(service.createDirectory(join(root, "gone"), "child"))).toEqual(missing);
  expect(await refusal(service.createDirectory(root, "kept"))).toEqual({ code: "conflict", message: "An item with that name already exists", retryable: false });
});
