import { realpathSync } from "node:fs";
import { lstat, mkdir, opendir, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { GatewayError } from "../errors.js";
import { containedWithin } from "./path-containment.js";
import { WORKSPACE_MAXIMUM_ENTRIES, WORKSPACE_MAXIMUM_PROJECTED_BYTES, projectBoundedEntries } from "./workspace-bounds.js";
import { inspectGitPath } from "./workspace-inspection-service.js";

interface WorkspaceEntry {
  name: string;
  path: string;
  kind: "directory" | "file";
  hidden: boolean;
}

const FOLDER_LISTING_OVERFLOW = {
  message: "This folder contains too many entries to browse safely. Choose a more specific folder on the Mac.",
  retryable: false,
};

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
    if (!containedWithin(this.root, target)) throw new GatewayError("invalid_request", "Path is outside the allowed workspace root");
    return target;
  }

  async list(path = this.root): Promise<{ path: string; parent?: string; entries: WorkspaceEntry[] }> {
    const canonical = await this.canonical(path);
    const validated = await lstat(canonical);
    if (!validated.isDirectory() || validated.isSymbolicLink()) {
      throw new GatewayError("invalid_request", "Path is not a directory");
    }
    const maximumEntries = this.maximumEntries;
    const directory = await opendir(canonical);
    // Candidates stream out of the open handle, so both ceilings are enforced
    // while the folder is read rather than after buffering it.
    const candidates = async function* (): AsyncGenerator<WorkspaceEntry> {
      let examinedEntries = 0;
      for await (const entry of directory) {
        examinedEntries += 1;
        if (examinedEntries > maximumEntries) {
          throw new GatewayError("conflict", FOLDER_LISTING_OVERFLOW.message, FOLDER_LISTING_OVERFLOW.retryable);
        }
        if (!entry.isDirectory() && !entry.isFile()) continue;
        yield {
          name: entry.name,
          path: join(canonical, entry.name),
          kind: entry.isDirectory() ? "directory" : "file",
          hidden: entry.name.startsWith("."),
        };
      }
    };
    let projected: WorkspaceEntry[];
    try {
      const opened = await lstat(canonical);
      if (!opened.isDirectory() || opened.isSymbolicLink()
        || opened.dev !== validated.dev || opened.ino !== validated.ino) {
        throw new GatewayError("conflict", "The workspace folder changed while it was being opened", true);
      }
      projected = await projectBoundedEntries<WorkspaceEntry>(candidates(), this.maximumProjectedBytes, FOLDER_LISTING_OVERFLOW);
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
    if (!containedWithin(this.root, target)) throw new GatewayError("invalid_request", "Folder is outside the allowed workspace root");
    await mkdir(target);
    return realpath(target);
  }

  async inspectGit(path: string): ReturnType<typeof inspectGitPath> {
    return inspectGitPath(await this.canonical(path));
  }
}
