import { realpathSync } from "node:fs";
import { mkdir, readdir, realpath, stat } from "node:fs/promises";
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

export class FilesystemService {
  readonly root: string;

  constructor(root = homedir()) {
    this.root = realpathSync(resolve(root));
  }

  private async canonical(path: string): Promise<string> {
    const target = await realpath(resolve(path));
    if (!inside(this.root, target)) throw new GatewayError("invalid_request", "Path is outside the allowed workspace root");
    return target;
  }

  async list(path = this.root): Promise<{ path: string; parent?: string; entries: WorkspaceEntry[] }> {
    const canonical = await this.canonical(path);
    if (!(await stat(canonical)).isDirectory()) throw new GatewayError("invalid_request", "Path is not a directory");
    const entries = await readdir(canonical, { withFileTypes: true });
    const projected = entries
      .filter((entry) => entry.isDirectory() || entry.isFile())
      .map((entry) => ({
        name: entry.name,
        path: join(canonical, entry.name),
        kind: entry.isDirectory() ? "directory" as const : "file" as const,
        hidden: entry.name.startsWith("."),
      }))
      .sort((a, b) => (a.kind === b.kind ? a.name.localeCompare(b.name) : a.kind === "directory" ? -1 : 1));
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
      const child = spawn("/usr/bin/git", ["status", "--porcelain=v1", "--branch", "--untracked-files=no"], {
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
