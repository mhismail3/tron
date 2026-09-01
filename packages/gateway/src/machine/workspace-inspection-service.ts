import { createHash, createHmac, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, opendir, realpath, stat } from "node:fs/promises";
import { basename, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { spawn } from "node:child_process";
import { GatewayError } from "../errors.js";

const GIT = process.env.TRON_GIT_PATH ?? "/usr/bin/git";
const GIT_TIMEOUT_MS = 5_000;
const HISTORY_TIMEOUT_MS = 10_000;
const GIT_MAX_OUTPUT_BYTES = 768 * 1_024;
const DIFF_MAX_OUTPUT_BYTES = 480 * 1_024;
const WORKSPACE_MAXIMUM_ENTRIES = 1_000;
const WORKSPACE_MAXIMUM_PROJECTED_BYTES = 768 * 1_024;
const WORKSPACE_FILE_MAXIMUM_BYTES = 25 * 1_048_576;
const WORKSPACE_MAXIMUM_CHANGES = 5_000;
const HISTORY_MAXIMUM_LIMIT = 100;
const HISTORY_CURSOR_MAXIMUM_AGE_MS = 5 * 60_000;

export type WorkspaceEntryKind = "directory" | "file" | "symlink";
export type WorkspaceChangeKind = "added" | "modified" | "deleted" | "renamed" | "copied" | "untracked" | "conflicted" | "typeChanged";
export type WorkspaceDiffScope = "current" | "staged" | "unstaged";
export type WorkspaceHistoryScope = "currentBranch" | "allReferences";

export interface WorkspaceChange {
  path: string;
  originalPath?: string;
  staged: boolean;
  unstaged: boolean;
  untracked: boolean;
  conflicted: boolean;
  kind: WorkspaceChangeKind;
}

export interface WorkspaceRepositoryInspection {
  root: string;
  branch?: string;
  head?: string;
  detached: boolean;
  unborn: boolean;
  dirty: boolean;
  changes: WorkspaceChange[];
}

export interface WorkspaceInspection {
  root: string;
  revision: string;
  repository?: WorkspaceRepositoryInspection;
}

interface GitResult {
  stdout: Buffer;
  stderr: Buffer;
  exitCode: number;
  truncated: boolean;
}

interface HistoryCursor {
  clientID: string;
  root: string;
  scope: WorkspaceHistoryScope;
  generation: string;
  offset: number;
  issuedAt: number;
}

function inside(root: string, candidate: string): boolean {
  const delta = relative(root, candidate);
  return delta === "" || (!delta.startsWith(`..${sep}`) && delta !== ".." && !isAbsolute(delta));
}

function invalidRelativePath(): never {
  throw new GatewayError("invalid_request", "Workspace path must be a relative path inside the session workspace");
}

function validateRelativePath(value: string | undefined, allowEmpty = true): string {
  const path = value ?? "";
  if ((!allowEmpty && path.length === 0) || path.length > 4_096 || isAbsolute(path) || path.includes("\0")) {
    return invalidRelativePath();
  }
  const components = path.split(/[\\/]/);
  if (components.some((component) => component === "." || component === ".." || component.length === 0) && path.length > 0) {
    return invalidRelativePath();
  }
  return components.join(sep);
}

async function canonicalRoot(path: string): Promise<string> {
  const root = await realpath(resolve(path));
  const metadata = await lstat(root);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new GatewayError("conflict", "The session workspace is no longer a directory", true);
  }
  return root;
}

async function containedPath(rootInput: string, relativePath: string, finalKind?: "directory" | "file"): Promise<string> {
  const root = await canonicalRoot(rootInput);
  const normalized = validateRelativePath(relativePath);
  let candidate = root;
  for (const component of normalized ? normalized.split(sep) : []) {
    candidate = join(candidate, component);
    const metadata = await lstat(candidate);
    if (metadata.isSymbolicLink()) {
      throw new GatewayError("invalid_request", "Workspace symbolic links cannot be followed");
    }
  }
  if (!inside(root, candidate)) return invalidRelativePath();
  const metadata = await lstat(candidate);
  if (finalKind === "directory" && !metadata.isDirectory()) {
    throw new GatewayError("invalid_request", "Workspace path is not a directory");
  }
  if (finalKind === "file" && !metadata.isFile()) {
    throw new GatewayError("invalid_request", "Workspace path is not a regular file");
  }
  return candidate;
}

function gitEnvironment(): NodeJS.ProcessEnv {
  return {
    ...process.env,
    LC_ALL: "C",
    LANG: "C",
    GIT_OPTIONAL_LOCKS: "0",
    GIT_TERMINAL_PROMPT: "0",
    GIT_PAGER: "cat",
    PAGER: "cat",
  };
}

async function runGit(
  cwd: string,
  arguments_: string[],
  options: {
    timeoutMs?: number;
    maximumBytes?: number;
    allowedExitCodes?: readonly number[];
    truncate?: boolean;
  } = {},
): Promise<GitResult> {
  const maximumBytes = options.maximumBytes ?? GIT_MAX_OUTPUT_BYTES;
  const allowedExitCodes = options.allowedExitCodes ?? [0];
  return await new Promise<GitResult>((resolvePromise, rejectPromise) => {
    const child = spawn(GIT, ["--no-pager", "-C", cwd, ...arguments_], {
      cwd,
      env: gitEnvironment(),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    const chunks: Buffer[] = [];
    const errors: Buffer[] = [];
    let bytes = 0;
    let errorBytes = 0;
    let truncated = false;
    let timedOut = false;
    let overflowed = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, options.timeoutMs ?? GIT_TIMEOUT_MS);
    timer.unref();

    child.stdout.on("data", (chunk: Buffer) => {
      if (truncated) return;
      if (chunk.length > maximumBytes - bytes) {
        if (options.truncate) {
          const remaining = Math.max(0, maximumBytes - bytes);
          if (remaining > 0) chunks.push(chunk.subarray(0, remaining));
          bytes = maximumBytes;
          truncated = true;
          child.kill("SIGKILL");
        } else {
          overflowed = true;
          child.kill("SIGKILL");
        }
        return;
      }
      chunks.push(chunk);
      bytes += chunk.length;
    });
    child.stderr.on("data", (chunk: Buffer) => {
      const remaining = Math.max(0, 16_384 - errorBytes);
      if (remaining > 0) errors.push(chunk.subarray(0, remaining));
      errorBytes += Math.min(chunk.length, remaining);
    });
    child.once("error", (error) => {
      clearTimeout(timer);
      rejectPromise(new GatewayError("internal", `Git could not be started: ${error.message}`, true));
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (timedOut) return rejectPromise(new GatewayError("busy", "Git inspection timed out", true));
      if (overflowed) return rejectPromise(new GatewayError("conflict", "Git output exceeded the bounded inspection limit", true));
      if (truncated && options.truncate) return resolvePromise({
        stdout: Buffer.concat(chunks), stderr: Buffer.concat(errors), exitCode: code ?? -1, truncated: true,
      });
      if (code === null || !allowedExitCodes.includes(code)) {
        const detail = Buffer.concat(errors).toString("utf8").trim().slice(0, 1_000);
        return rejectPromise(new GatewayError("conflict", detail ? `Git inspection failed: ${detail}` : "Git inspection failed", true));
      }
      resolvePromise({ stdout: Buffer.concat(chunks), stderr: Buffer.concat(errors), exitCode: code, truncated: false });
    });
  });
}

function splitNul(output: Buffer): string[] {
  const values = output.toString("utf8").split("\0");
  if (values.at(-1) === "") values.pop();
  return values;
}

function changeKind(code: string, untracked: boolean, conflicted: boolean): WorkspaceChangeKind {
  if (untracked) return "untracked";
  if (conflicted || code === "U") return "conflicted";
  switch (code) {
    case "A": return "added";
    case "D": return "deleted";
    case "R": return "renamed";
    case "C": return "copied";
    case "T": return "typeChanged";
    default: return "modified";
  }
}

function workspaceRelativePath(repositoryRoot: string, workspaceRoot: string, repositoryPath: string): string | undefined {
  const absolute = resolve(repositoryRoot, repositoryPath);
  if (!inside(workspaceRoot, absolute)) return undefined;
  const value = relative(workspaceRoot, absolute);
  if (!value || isAbsolute(value) || value === ".." || value.startsWith(`..${sep}`)) return undefined;
  return value.split(sep).join("/");
}

async function repositoryRoot(cwd: string): Promise<string | undefined> {
  const result = await runGit(cwd, ["rev-parse", "--show-toplevel"], {
    maximumBytes: 8_192,
    allowedExitCodes: [0, 128],
  });
  if (result.exitCode !== 0) {
    const detail = result.stderr.toString("utf8").trim();
    if (detail.includes("not a git repository")) return undefined;
    throw new GatewayError(
      "conflict",
      detail ? `Git repository inspection failed: ${detail.slice(0, 1_000)}` : "Git repository inspection failed",
      true,
    );
  }
  const value = result.stdout.toString("utf8").trim();
  if (!value) throw new GatewayError("conflict", "Git did not report a repository root", true);
  return await realpath(value);
}

async function statusInspection(workspaceInput: string): Promise<WorkspaceRepositoryInspection | undefined> {
  const workspaceRoot = await canonicalRoot(workspaceInput);
  const root = await repositoryRoot(workspaceRoot);
  if (!root) return undefined;
  const pathspec = relative(root, workspaceRoot) || ".";
  const result = await runGit(root, [
    "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--", pathspec,
  ]);
  const records = splitNul(result.stdout);
  let branch: string | undefined;
  let head: string | undefined;
  let unborn = false;
  const changes: WorkspaceChange[] = [];
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index]!;
    if (record.startsWith("# branch.oid ")) {
      const oid = record.slice("# branch.oid ".length);
      if (oid === "(initial)") unborn = true;
      else if (/^[0-9a-f]{40,64}$/.test(oid)) head = oid;
      continue;
    }
    if (record.startsWith("# branch.head ")) {
      const value = record.slice("# branch.head ".length);
      if (value !== "(detached)") branch = value;
      continue;
    }
    let xy = "..";
    let repositoryPath: string | undefined;
    let originalRepositoryPath: string | undefined;
    if (record.startsWith("1 ")) {
      const fields = record.split(" ");
      xy = fields[1] ?? "..";
      repositoryPath = fields.slice(8).join(" ");
    } else if (record.startsWith("2 ")) {
      const fields = record.split(" ");
      xy = fields[1] ?? "..";
      repositoryPath = fields.slice(9).join(" ");
      originalRepositoryPath = records[++index];
    } else if (record.startsWith("u ")) {
      const fields = record.split(" ");
      xy = fields[1] ?? "UU";
      repositoryPath = fields.slice(10).join(" ");
    } else if (record.startsWith("? ")) {
      xy = "??";
      repositoryPath = record.slice(2);
    } else {
      continue;
    }
    if (!repositoryPath) continue;
    const path = workspaceRelativePath(root, workspaceRoot, repositoryPath);
    if (!path) continue;
    const originalPath = originalRepositoryPath
      ? workspaceRelativePath(root, workspaceRoot, originalRepositoryPath)
      : undefined;
    const untracked = xy === "??";
    const conflicted = record.startsWith("u ") || xy.includes("U") || xy === "AA" || xy === "DD";
    const staged = !untracked && xy[0] !== "." && xy[0] !== " ";
    const unstaged = untracked || xy[1] !== "." && xy[1] !== " ";
    const code = conflicted ? "U" : untracked ? "?" : (staged ? xy[0]! : xy[1]!);
    changes.push({
      path,
      ...(originalPath ? { originalPath } : {}),
      staged,
      unstaged,
      untracked,
      conflicted,
      kind: changeKind(code, untracked, conflicted),
    });
    if (changes.length > WORKSPACE_MAXIMUM_CHANGES) {
      throw new GatewayError("conflict", "The workspace contains too many changes to inspect safely", true);
    }
  }
  return {
    root,
    ...(branch ? { branch } : {}),
    ...(head ? { head } : {}),
    detached: !branch && !unborn,
    unborn,
    dirty: changes.length > 0,
    changes,
  };
}

function revisionFor(root: string, repository: WorkspaceRepositoryInspection | undefined): string {
  return createHash("sha256").update(JSON.stringify({ root, repository })).digest("base64url");
}

export async function inspectGitPath(path: string): Promise<{ isRepository: boolean; branch?: string; dirty?: boolean }> {
  const repository = await statusInspection(path);
  if (!repository) return { isRepository: false };
  return {
    isRepository: true,
    ...(repository.branch ? { branch: repository.branch } : {}),
    dirty: repository.dirty,
  };
}

function mimeTypeFor(path: string): string {
  switch (extname(path).toLowerCase()) {
    case ".md": case ".markdown": return "text/markdown; charset=utf-8";
    case ".txt": case ".log": case ".csv": return "text/plain; charset=utf-8";
    case ".json": return "application/json";
    case ".pdf": return "application/pdf";
    case ".png": return "image/png";
    case ".jpg": case ".jpeg": return "image/jpeg";
    case ".gif": return "image/gif";
    case ".webp": return "image/webp";
    case ".svg": return "image/svg+xml";
    default: return "application/octet-stream";
  }
}

async function readBoundedFile(
  handle: Awaited<ReturnType<typeof open>>,
  maximumBytes: number,
): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let total = 0;
  while (total <= maximumBytes) {
    const buffer = Buffer.allocUnsafe(Math.min(64 * 1_024, maximumBytes + 1 - total));
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
    if (bytesRead === 0) break;
    chunks.push(buffer.subarray(0, bytesRead));
    total += bytesRead;
  }
  if (total > maximumBytes) {
    throw new GatewayError("conflict", "Workspace file exceeds the 25 MiB preview limit");
  }
  return Buffer.concat(chunks, total);
}

export class WorkspaceInspectionService {
  private readonly cursorSecret = randomBytes(32);

  constructor(private readonly registerBlob: (data: Buffer, mimeType: string) => string) {}

  async inspect(workspace: string): Promise<WorkspaceInspection> {
    const root = await canonicalRoot(workspace);
    const repository = await statusInspection(root);
    return {
      root,
      revision: revisionFor(root, repository),
      ...(repository ? { repository: { ...repository, root } } : {}),
    };
  }

  async list(workspace: string, requestedPath?: string): Promise<{
    root: string;
    path: string;
    parent?: string;
    revision: string;
    entries: Array<{ name: string; path: string; kind: WorkspaceEntryKind; hidden: boolean; size?: number; modifiedAt?: string }>;
  }> {
    const root = await canonicalRoot(workspace);
    const relativePath = validateRelativePath(requestedPath);
    const directoryPath = await containedPath(root, relativePath, "directory");
    const directory = await opendir(directoryPath);
    const entries: Array<{ name: string; path: string; kind: WorkspaceEntryKind; hidden: boolean; size?: number; modifiedAt?: string }> = [];
    let bytes = 2;
    let examined = 0;
    try {
      for await (const entry of directory) {
        examined += 1;
        if (examined > WORKSPACE_MAXIMUM_ENTRIES) {
          throw new GatewayError("conflict", "This folder contains too many entries to browse safely", true);
        }
        const absolute = join(directoryPath, entry.name);
        const metadata = await lstat(absolute);
        const kind: WorkspaceEntryKind | undefined = metadata.isSymbolicLink()
          ? "symlink"
          : metadata.isDirectory() ? "directory" : metadata.isFile() ? "file" : undefined;
        if (!kind) continue;
        const path = relative(root, absolute).split(sep).join("/");
        const candidate = {
          name: entry.name,
          path,
          kind,
          hidden: entry.name.startsWith("."),
          ...(kind === "file" ? { size: metadata.size } : {}),
          modifiedAt: metadata.mtime.toISOString(),
        };
        const candidateBytes = Buffer.byteLength(JSON.stringify(candidate)) + 1;
        if (candidateBytes > WORKSPACE_MAXIMUM_PROJECTED_BYTES - bytes) {
          throw new GatewayError("conflict", "This folder contains too much metadata to browse safely", true);
        }
        entries.push(candidate);
        bytes += candidateBytes;
      }
    } finally {
      await directory.close().catch((error: NodeJS.ErrnoException) => {
        if (error.code !== "ERR_DIR_CLOSED") throw error;
      });
    }
    entries.sort((left, right) => left.kind === right.kind
      ? left.name.localeCompare(right.name)
      : left.kind === "directory" ? -1 : right.kind === "directory" ? 1 : left.name.localeCompare(right.name));
    const fingerprint = createHash("sha256");
    for (const entry of entries) fingerprint.update(JSON.stringify(entry)).update("\0");
    return {
      root,
      path: relativePath.split(sep).join("/"),
      ...(relativePath ? { parent: relativePath.split(sep).slice(0, -1).join("/") } : {}),
      revision: fingerprint.digest("base64url"),
      entries,
    };
  }

  async file(workspace: string, requestedPath: string): Promise<{
    blobId: string;
    name: string;
    mimeType: string;
    size: number;
    revision: string;
  }> {
    const root = await canonicalRoot(workspace);
    const relativePath = validateRelativePath(requestedPath, false);
    const source = await containedPath(root, relativePath, "file");
    let handle: Awaited<ReturnType<typeof open>>;
    try {
      handle = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ELOOP") {
        throw new GatewayError("invalid_request", "Workspace symbolic links cannot be opened");
      }
      throw error;
    }
    try {
      const before = await handle.stat();
      if (!before.isFile() || before.size > WORKSPACE_FILE_MAXIMUM_BYTES) {
        throw new GatewayError("conflict", "Workspace file exceeds the 25 MiB preview limit");
      }
      const data = await readBoundedFile(handle, WORKSPACE_FILE_MAXIMUM_BYTES);
      const after = await handle.stat();
      const current = await lstat(source);
      if (!after.isFile() || current.isSymbolicLink() || !current.isFile()
        || before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || current.dev !== before.dev || current.ino !== before.ino
        || data.length !== before.size) {
        throw new GatewayError("conflict", "Workspace file changed while its preview was captured", true);
      }
      const mimeType = mimeTypeFor(source);
      return {
        blobId: this.registerBlob(data, mimeType),
        name: basename(source),
        mimeType,
        size: data.length,
        revision: createHash("sha256").update(data).digest("base64url"),
      };
    } finally {
      await handle.close().catch(() => {});
    }
  }

  async diff(workspace: string, requestedPath: string, scope: WorkspaceDiffScope): Promise<{
    path: string;
    patch: string;
    binary: boolean;
    truncated: boolean;
    revision: string;
  }> {
    const root = await canonicalRoot(workspace);
    const relativePath = validateRelativePath(requestedPath, false).split(sep).join("/");
    const repository = await statusInspection(root);
    if (!repository) throw new GatewayError("invalid_request", "The session workspace is not a Git repository");
    const absolute = resolve(root, relativePath);
    if (!inside(root, absolute)) return invalidRelativePath();
    const repositoryPath = relative(repository.root, absolute).split(sep).join("/");
    const change = repository.changes.find((candidate) => candidate.path === relativePath);
    const common = ["--no-ext-diff", "--no-textconv", "--no-color", "--unified=3"];
    let results: GitResult[];
    if (scope === "staged") {
      results = [await runGit(repository.root, ["diff", "--cached", ...common, "--", repositoryPath], {
        maximumBytes: DIFF_MAX_OUTPUT_BYTES,
        truncate: true,
      })];
    } else if (scope === "unstaged") {
      results = [await runGit(repository.root, ["diff", ...common, "--", repositoryPath], {
        maximumBytes: DIFF_MAX_OUTPUT_BYTES,
        truncate: true,
      })];
    } else if (change?.untracked) {
      await containedPath(root, relativePath, "file");
      results = [await runGit(repository.root, ["diff", "--no-index", ...common, "--", "/dev/null", absolute], {
        maximumBytes: DIFF_MAX_OUTPUT_BYTES,
        allowedExitCodes: [0, 1],
        truncate: true,
      })];
    } else {
      const staged = await runGit(repository.root, ["diff", "--cached", ...common, "--", repositoryPath], {
        maximumBytes: DIFF_MAX_OUTPUT_BYTES,
        truncate: true,
      });
      const remaining = Math.max(1, DIFF_MAX_OUTPUT_BYTES - staged.stdout.length);
      const unstaged = await runGit(repository.root, ["diff", ...common, "--", repositoryPath], {
        maximumBytes: remaining,
        truncate: true,
      });
      results = [staged, unstaged];
    }
    const patch = results.map((result) => result.stdout.toString("utf8")).filter(Boolean).join("\n");
    return {
      path: relativePath,
      patch,
      binary: patch.includes("Binary files ") || patch.includes("GIT binary patch"),
      truncated: results.some((result) => result.truncated),
      revision: revisionFor(root, repository),
    };
  }

  async historyList(
    workspace: string,
    clientID: string,
    scope: WorkspaceHistoryScope,
    rawCursor: string | undefined,
    limit: number,
  ): Promise<{
    commits: Array<{ oid: string; shortOid: string; parents: string[]; subject: string; authorName: string; authoredAt: string; decorations: string[] }>;
    nextCursor?: string;
    revision: string;
  }> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > HISTORY_MAXIMUM_LIMIT) {
      throw new GatewayError("invalid_request", `History limit must be between 1 and ${HISTORY_MAXIMUM_LIMIT}`);
    }
    const root = await canonicalRoot(workspace);
    const repository = await statusInspection(root);
    if (!repository) throw new GatewayError("invalid_request", "The session workspace is not a Git repository");
    const generation = await this.historyGeneration(repository.root, scope, repository.head);
    let offset = 0;
    if (rawCursor !== undefined) {
      const cursor = this.decodeCursor(rawCursor);
      if (cursor.clientID !== clientID || cursor.root !== repository.root || cursor.scope !== scope
        || cursor.generation !== generation || Date.now() - cursor.issuedAt > HISTORY_CURSOR_MAXIMUM_AGE_MS) {
        throw new GatewayError("conflict", "Repository history changed or the cursor expired; restart the listing", true);
      }
      offset = cursor.offset;
    }
    const pathspec = relative(repository.root, root) || ".";
    const source = scope === "allReferences" ? ["--all"] : ["HEAD"];
    if (scope === "currentBranch" && repository.unborn) {
      return { commits: [], revision: generation };
    }
    const result = await runGit(repository.root, [
      "log", "-z", "--topo-order", `--skip=${offset}`, `--max-count=${limit + 1}`,
      "--format=%H%x1f%h%x1f%P%x1f%an%x1f%aI%x1f%D%x1f%s", ...source, "--", pathspec,
    ], { timeoutMs: HISTORY_TIMEOUT_MS });
    const parsed = splitNul(result.stdout).filter(Boolean).map((record) => {
      const [oid = "", shortOid = "", parents = "", authorName = "", authoredAt = "", decorations = "", subject = ""] = record.split("\x1f");
      if (!/^[0-9a-f]{40,64}$/.test(oid)) throw new GatewayError("conflict", "Git returned an invalid history entry", true);
      return {
        oid,
        shortOid,
        parents: parents ? parents.split(" ").filter(Boolean) : [],
        subject: subject.slice(0, 8_192),
        authorName: authorName.slice(0, 2_048),
        authoredAt,
        decorations: decorations.split(",").map((value) => value.trim()).filter(Boolean).slice(0, 64),
      };
    });
    const hasMore = parsed.length > limit;
    const commits = parsed.slice(0, limit);
    return {
      commits,
      ...(hasMore ? { nextCursor: this.encodeCursor({
        clientID,
        root: repository.root,
        scope,
        generation,
        offset: offset + commits.length,
        issuedAt: Date.now(),
      }) } : {}),
      revision: generation,
    };
  }

  async historyGet(workspace: string, oid: string): Promise<{
    oid: string;
    shortOid: string;
    parents: string[];
    subject: string;
    message: string;
    authorName: string;
    authorEmail?: string;
    authoredAt: string;
    decorations: string[];
    changes: Array<{ path: string; originalPath?: string; kind: WorkspaceChangeKind }>;
    revision: string;
  }> {
    if (!/^[0-9a-f]{40,64}$/.test(oid)) throw new GatewayError("invalid_request", "Commit ID is invalid");
    const root = await canonicalRoot(workspace);
    const repository = await statusInspection(root);
    if (!repository) throw new GatewayError("invalid_request", "The session workspace is not a Git repository");
    const pathspec = relative(repository.root, root) || ".";
    const visible = await runGit(repository.root, [
      "log", "-1", "--format=%H", oid, "--", pathspec,
    ], { maximumBytes: 8_192 });
    if (visible.stdout.toString("utf8").trim() !== oid) {
      throw new GatewayError("invalid_request", "Commit is not part of this session workspace's history");
    }
    const metadata = await runGit(repository.root, [
      "show", "-s", "-z", "--format=%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%D%x1f%s%x1f%B", oid,
    ], { maximumBytes: 128 * 1_024 });
    const fields = metadata.stdout.toString("utf8").replace(/\0+$/, "").split("\x1f");
    const [full = "", shortOid = "", parents = "", authorName = "", authorEmail = "", authoredAt = "", decorations = "", subject = "", ...messageParts] = fields;
    if (full !== oid) throw new GatewayError("conflict", "Git returned a different commit", true);
    const names = await runGit(repository.root, [
      "diff-tree", "--root", "--no-commit-id", "--name-status", "-z", "-r", "-M", oid, "--", pathspec,
    ], { maximumBytes: 256 * 1_024 });
    const records = splitNul(names.stdout);
    const changes: Array<{ path: string; originalPath?: string; kind: WorkspaceChangeKind }> = [];
    for (let index = 0; index < records.length;) {
      const statusCode = records[index++] ?? "M";
      const sourcePath = records[index++] ?? "";
      let destinationPath = sourcePath;
      let originalRepositoryPath: string | undefined;
      if (statusCode.startsWith("R") || statusCode.startsWith("C")) {
        originalRepositoryPath = sourcePath;
        destinationPath = records[index++] ?? "";
      }
      const path = workspaceRelativePath(repository.root, root, destinationPath);
      if (!path) continue;
      const originalPath = originalRepositoryPath
        ? workspaceRelativePath(repository.root, root, originalRepositoryPath)
        : undefined;
      changes.push({
        path,
        ...(originalPath ? { originalPath } : {}),
        kind: changeKind(statusCode[0] ?? "M", false, false),
      });
      if (changes.length > WORKSPACE_MAXIMUM_CHANGES) {
        throw new GatewayError("conflict", "Commit contains too many changed files to inspect safely", true);
      }
    }
    return {
      oid,
      shortOid,
      parents: parents ? parents.split(" ").filter(Boolean) : [],
      subject: subject.slice(0, 8_192),
      message: messageParts.join("\x1f").slice(0, 64 * 1_024),
      authorName: authorName.slice(0, 2_048),
      ...(authorEmail ? { authorEmail: authorEmail.slice(0, 2_048) } : {}),
      authoredAt,
      decorations: decorations.split(",").map((value) => value.trim()).filter(Boolean).slice(0, 64),
      changes,
      revision: revisionFor(root, repository),
    };
  }

  private async historyGeneration(root: string, scope: WorkspaceHistoryScope, head?: string): Promise<string> {
    if (scope === "currentBranch") return head ?? "unborn";
    const refs = await runGit(root, ["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads", "refs/remotes", "refs/tags"], {
      timeoutMs: HISTORY_TIMEOUT_MS,
      maximumBytes: 256 * 1_024,
    });
    return createHash("sha256").update(head ?? "unborn").update("\0").update(refs.stdout).digest("base64url");
  }

  private encodeCursor(cursor: HistoryCursor): string {
    const payload = Buffer.from(JSON.stringify(cursor)).toString("base64url");
    const signature = createHmac("sha256", this.cursorSecret).update(payload).digest("base64url").slice(0, 22);
    return `${payload}.${signature}`;
  }

  private decodeCursor(value: string): HistoryCursor {
    if (value.length > 2_048) throw new GatewayError("invalid_request", "History cursor is invalid");
    const [payload, signature, extra] = value.split(".");
    if (!payload || !signature || extra !== undefined) throw new GatewayError("invalid_request", "History cursor is invalid");
    const expected = createHmac("sha256", this.cursorSecret).update(payload).digest("base64url").slice(0, 22);
    if (signature !== expected) throw new GatewayError("invalid_request", "History cursor is invalid");
    let parsed: Partial<HistoryCursor>;
    try { parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as Partial<HistoryCursor>; }
    catch { throw new GatewayError("invalid_request", "History cursor is invalid"); }
    if (typeof parsed.clientID !== "string" || typeof parsed.root !== "string"
      || (parsed.scope !== "currentBranch" && parsed.scope !== "allReferences")
      || typeof parsed.generation !== "string" || !Number.isSafeInteger(parsed.offset) || (parsed.offset ?? -1) < 0
      || !Number.isSafeInteger(parsed.issuedAt)) {
      throw new GatewayError("invalid_request", "History cursor is invalid");
    }
    return parsed as HistoryCursor;
  }
}
