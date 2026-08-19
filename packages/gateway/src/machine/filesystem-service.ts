import { realpathSync } from "node:fs";
import { lstat, mkdir, opendir, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { spawn } from "node:child_process";
import { GatewayError } from "../errors.js";

export interface WorkspaceEntry {
  name: string;
  path: string;
  kind: "directory" | "file";
  hidden: boolean;
}

function inside(root: string, candidate: string): boolean {
  const delta = relative(root, candidate);
  return delta === "" || (!delta.startsWith(`..${sep}`) && delta !== ".." && !isAbsolute(delta));
}

export const WORKSPACE_MAXIMUM_ENTRIES = 1_000;
export const WORKSPACE_MAXIMUM_PROJECTED_BYTES = 768 * 1_024;

interface FilesystemServiceOptions {
  maximumEntries?: number;
  maximumProjectedBytes?: number;
}

export class FilesystemService {
  readonly root: string;
  private readonly maximumEntries: number;
  private readonly maximumProjectedBytes: number;

  constructor(root = homedir(), options: FilesystemServiceOptions = {}) {
    this.root = realpathSync(resolve(root));
    this.maximumEntries = options.maximumEntries ?? WORKSPACE_MAXIMUM_ENTRIES;
    this.maximumProjectedBytes = options.maximumProjectedBytes ?? WORKSPACE_MAXIMUM_PROJECTED_BYTES;
    if (!Number.isSafeInteger(this.maximumEntries) || this.maximumEntries < 1
      || !Number.isSafeInteger(this.maximumProjectedBytes) || this.maximumProjectedBytes < 1) {
      throw new Error("Workspace listing bounds are invalid");
    }
  }

  private async canonical(path: string): Promise<string> {
    const target = await realpath(resolve(path));
    if (!inside(this.root, target)) throw new GatewayError("invalid_request", "Path is outside the allowed workspace root");
    return target;
  }

  async list(path = this.root): Promise<{ path: string; parent?: string; entries: WorkspaceEntry[] }> {
    const canonical = await this.canonical(path);
    const validated = await lstat(canonical);
    if (!validated.isDirectory() || validated.isSymbolicLink()) {
      throw new GatewayError("invalid_request", "Path is not a directory");
    }
    const projected: WorkspaceEntry[] = [];
    let projectedBytes = 2;
    let examinedEntries = 0;
    const directory = await opendir(canonical);
    try {
      const opened = await lstat(canonical);
      if (!opened.isDirectory() || opened.isSymbolicLink()
        || opened.dev !== validated.dev || opened.ino !== validated.ino) {
        throw new GatewayError("conflict", "The workspace folder changed while it was being opened", true);
      }
      for await (const entry of directory) {
        examinedEntries += 1;
        if (examinedEntries > this.maximumEntries) {
          throw new GatewayError(
            "conflict",
            "This folder contains too many entries to browse safely. Choose a more specific folder on the Mac.",
          );
        }
        if (!entry.isDirectory() && !entry.isFile()) continue;
        const candidate: WorkspaceEntry = {
          name: entry.name,
          path: join(canonical, entry.name),
          kind: entry.isDirectory() ? "directory" : "file",
          hidden: entry.name.startsWith("."),
        };
        const candidateBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
        if (candidateBytes > this.maximumProjectedBytes - projectedBytes) {
          throw new GatewayError(
            "conflict",
            "This folder contains too many entries to browse safely. Choose a more specific folder on the Mac.",
          );
        }
        projected.push(candidate);
        projectedBytes += candidateBytes;
      }
    } finally {
      await directory.close().catch((error: NodeJS.ErrnoException) => {
        if (error.code !== "ERR_DIR_CLOSED") throw error;
      });
    }
    projected.sort((a, b) => (a.kind === b.kind ? a.name.localeCompare(b.name) : a.kind === "directory" ? -1 : 1));
    const parent = canonical === this.root ? undefined : dirname(canonical);
    return { path: canonical, ...(parent ? { parent } : {}), entries: projected };
  }

  async createDirectory(parent: string, name: string): Promise<string> {
    if (!/^[^/\\\0]{1,120}$/.test(name) || name === "." || name === "..") {
      throw new GatewayError("invalid_request", "Folder name is invalid");
    }
    const canonicalParent = await this.canonical(parent);
    const target = join(canonicalParent, name);
    if (!inside(this.root, target)) throw new GatewayError("invalid_request", "Folder is outside the allowed workspace root");
    await mkdir(target);
    return realpath(target);
  }

  async inspectGit(path: string): Promise<{ isRepository: boolean; branch?: string; dirty?: boolean }> {
    const cwd = await this.canonical(path);
    return new Promise((resolvePromise) => {
      const child = spawn("/usr/bin/git", ["status", "--porcelain=v1", "--branch", "--untracked-files=all"], {
        cwd,
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 3_000,
      });
      let output = "";
      child.stdout.on("data", (chunk: Buffer) => {
        if (output.length < 128_000) output += chunk.toString("utf8");
      });
      child.on("error", () => resolvePromise({ isRepository: false }));
      child.on("close", (code) => {
        if (code !== 0) return resolvePromise({ isRepository: false });
        const lines = output.split("\n");
        const header = lines[0] ?? "";
        const branch = header.replace(/^## /, "").split("...")[0]?.trim();
        resolvePromise({ isRepository: true, ...(branch ? { branch } : {}), dirty: lines.slice(1).some(Boolean) });
      });
    });
  }
}
