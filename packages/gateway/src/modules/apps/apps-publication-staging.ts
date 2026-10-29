import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, readdir, realpath, rm, type FileHandle } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { fileIdentity } from "./apps-folder-files.js";

type Root = { path: string; workspace: string; handle: FileHandle };
function unsafe(): never { throw new GatewayError("conflict", "Apps publication staging is unsafe or unavailable"); }
export function publicationFilesystemMismatch(): never {
  throw new GatewayError("unsupported", "Apps staging and destination must share a filesystem; restore their placement before displaying", false, { reason: "apps_staging_filesystem_mismatch" });
}
/** Gateway-owned state, never user membership. One index owns recovery, active
 * stage cleanup and the pinned root until all accepted publication work joins. */
export class AppPublicationStaging {
  private initialization: Promise<Root> | undefined;
  constructor(private readonly workspace: TronWorkspace, private readonly signal: AbortSignal) {}
  private async fence(root: Root): Promise<void> {
    if (!(await this.workspace.describe()).available || await realpath(root.path) !== root.path) unsafe();
    const info = await lstat(root.path);
    if (info.isSymbolicLink() || !info.isDirectory() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700
      || fileIdentity(info) !== fileIdentity(await root.handle.stat())) unsafe();
  }
  private async initialize(): Promise<Root> {
    this.signal.throwIfAborted();
    return this.initialization ??= this.recover().catch(error => { this.initialization = undefined; throw error; });
  }
  private async recover(): Promise<Root> {
    const descriptor = await this.workspace.describe(); if (!descriptor.available) unsafe();
    let path = descriptor.root;
    for (const part of ["state", "apps-publication-staging"]) {
      this.signal.throwIfAborted(); path = join(path, part);
      try { await mkdir(path, { mode: 0o700 }); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
      const info = await lstat(path);
      if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700 || await realpath(path) !== path) unsafe();
    }
    const root: Root = { path, workspace: descriptor.root, handle: await open(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW) };
    try {
      await this.fence(root);
      for (const name of await readdir(path)) {
        this.signal.throwIfAborted();
        // The reserved private root contains only stages created by this owner.
        // Unknown/corrupt entries are refused, not mistaken for owned garbage.
        if (!/^stage-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(name)) unsafe();
        const info = await lstat(join(path, name));
        if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) unsafe();
        await this.fence(root); await rm(join(path, name), { recursive: true });
      }
      await this.fence(root); return root;
    } catch (error) { await root.handle.close(); throw error; }
  }
  async recoverAtStartup(): Promise<void> {
    try { await this.initialize(); } catch (error) { if (!this.signal.aborted) throw error; }
  }
  async create() {
    const root = await this.initialize(); await this.fence(root); this.signal.throwIfAborted();
    const cuts: Array<{ path: string; identity: string }> = [];
    let destination = root.workspace, device = (await lstat(destination)).dev;
    for (const part of ["", "files", "apps"]) {
      if (part) destination = join(destination, part);
      try {
        const info = await lstat(destination);
        if (!info.isDirectory() || info.isSymbolicLink()) unsafe();
        if (part === "files") await this.workspace.filesRoot();
        cuts.push({ path: destination, identity: fileIdentity(info) }); device = info.dev;
      } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") break; throw error; }
    }
    if ((await root.handle.stat()).dev !== device) publicationFilesystemMismatch();
    const fence = async () => {
      await this.fence(root); this.signal.throwIfAborted();
      for (const cut of cuts) {
        const info = await lstat(cut.path);
        if (!info.isDirectory() || info.isSymbolicLink() || fileIdentity(info) !== cut.identity) unsafe();
      }
    };
    await fence(); const path = join(root.path, `stage-${randomUUID()}`); await mkdir(path, { mode: 0o700 });
    return { path, fence, release: async () => { await this.fence(root); await rm(path, { recursive: true, force: true }); } };
  }
  async dispose(): Promise<void> {
    const root = await this.initialization?.catch(() => undefined); await root?.handle.close();
  }
}
