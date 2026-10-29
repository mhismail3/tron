import { constants } from "node:fs";
import { mkdir, mkdtemp, open, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, inject, it } from "vitest";
import { manifestReplacer } from "./directory-publication.js";

const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-native-metadata-"))); roots.push(root);
  const stage = join(root, "stage"), entry = join(root, "entry");
  await mkdir(stage, { mode: 0o700 }); await mkdir(entry);
  await writeFile(join(stage, "app.json"), '{"title":"Updated"}\n', { mode: 0o600 });
  await writeFile(join(entry, "app.json"), '{"title":"Original"}');
  const flags = constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW;
  const source = await open(stage, flags), destination = await open(entry, flags);
  return { root, stage, entry, source, destination, replace: manifestReplacer(inject("nativePublicationBinary")) };
}

it("replaces only the pinned original incarnation when the visible entry is replaced by a foreign symlink", async () => {
  const f = await fixture(), outside = join(f.root, "outside"), moved = join(f.root, "moved");
  await mkdir(outside); await writeFile(join(outside, "app.json"), "foreign bytes");
  await rename(f.entry, moved); await symlink(outside, f.entry);
  try {
    await f.replace(f.source.fd, f.destination.fd);
    expect(await readFile(join(moved, "app.json"), "utf8")).toBe('{"title":"Updated"}\n');
    expect(await readFile(join(outside, "app.json"), "utf8")).toBe("foreign bytes");
    await expect(readFile(join(f.stage, "app.json"))).rejects.toMatchObject({ code: "ENOENT" });
  } finally { await Promise.all([f.source.close(), f.destination.close()]); }
});

it("owns duplicated descriptors through the actual callback even after the caller closes its handles", async () => {
  const f = await fixture(), pending = f.replace(f.source.fd, f.destination.fd);
  await Promise.all([f.source.close(), f.destination.close()]); await pending;
  expect(await readFile(join(f.entry, "app.json"), "utf8")).toBe('{"title":"Updated"}\n');
});

it("refuses a linked staged manifest without changing either its target or the entry", async () => {
  const f = await fixture(), outside = join(f.root, "outside.json");
  await writeFile(outside, "foreign bytes"); await rm(join(f.stage, "app.json")); await symlink(outside, join(f.stage, "app.json"));
  try {
    await expect(f.replace(f.source.fd, f.destination.fd)).rejects.toBeInstanceOf(Error);
    expect(await readFile(outside, "utf8")).toBe("foreign bytes");
    expect(await readFile(join(f.entry, "app.json"), "utf8")).toBe('{"title":"Original"}');
  } finally { await Promise.all([f.source.close(), f.destination.close()]); }
});
