import { execFile } from "node:child_process";
import { mkdtemp, mkdir, realpath, rm, symlink, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";
import { WorkspaceInspectionService, inspectGitPath } from "./workspace-inspection-service.js";

const execFileAsync = promisify(execFile);
const roots: string[] = [];

async function git(cwd: string, ...arguments_: string[]): Promise<string> {
  return (await execFileAsync(process.env.TRON_GIT_PATH ?? "/usr/bin/git", ["-C", cwd, ...arguments_])).stdout.trim();
}

async function repository(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "tron-workspace-inspector-"));
  roots.push(root);
  await git(root, "init", "-q");
  await git(root, "config", "user.email", "workspace-tests@example.invalid");
  await git(root, "config", "user.name", "Workspace Tests");
  await writeFile(join(root, "README.md"), "base\n");
  await git(root, "add", "README.md");
  await git(root, "commit", "-qm", "base");
  await git(root, "switch", "-qc", "feature/workspace.inspector");
  return root;
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("WorkspaceInspectionService", () => {
  it("reports the exact branch and structured staged, unstaged, and untracked changes", async () => {
    const root = await repository();
    await writeFile(join(root, "README.md"), "working\n");
    await writeFile(join(root, "staged.txt"), "staged\n");
    await git(root, "add", "staged.txt");
    await writeFile(join(root, "untracked.txt"), "new\n");
    const service = new WorkspaceInspectionService(() => "blob");

    const inspection = await service.inspect(root);
    expect(inspection.repository).toMatchObject({
      branch: "feature/workspace.inspector",
      detached: false,
      unborn: false,
      dirty: true,
    });
    expect(inspection.repository?.changes).toEqual(expect.arrayContaining([
      expect.objectContaining({ path: "README.md", unstaged: true, staged: false }),
      expect.objectContaining({ path: "staged.txt", staged: true, unstaged: false }),
      expect.objectContaining({ path: "untracked.txt", untracked: true, unstaged: true }),
    ]));
    await expect(inspectGitPath(root)).resolves.toMatchObject({
      isRepository: true,
      branch: "feature/workspace.inspector",
      dirty: true,
    });
  });

  it("keeps listing and file reads inside the workspace without following symbolic links", async () => {
    const root = await repository();
    await mkdir(join(root, "Sources"));
    await writeFile(join(root, "Sources", "File.swift"), "let value = 1\n");
    await symlink(join(root, "Sources"), join(root, "linked"));
    let registered = Buffer.alloc(0);
    const service = new WorkspaceInspectionService((data) => {
      registered = data;
      return "blob-id";
    });

    const listing = await service.list(root);
    expect(listing.entries).toEqual(expect.arrayContaining([
      expect.objectContaining({ path: "Sources", kind: "directory" }),
      expect.objectContaining({ path: "linked", kind: "symlink" }),
    ]));
    const file = await service.file(root, "Sources/File.swift");
    expect(file).toMatchObject({ blobId: "blob-id", name: "File.swift", size: 14, revision: "blob-id" });
    expect(registered.toString("utf8")).toBe("let value = 1\n");
    await expect(service.list(root, "linked")).rejects.toMatchObject({ code: "invalid_request" });
    await expect(service.file(root, "../outside")).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("rejects directory listings above the bounded entry ceiling", async () => {
    const root = await repository();
    const crowded = join(root, "crowded");
    await mkdir(crowded);
    await Promise.all(Array.from({ length: 1_001 }, (_, index) => mkdir(join(crowded, `entry-${index}`))));
    const service = new WorkspaceInspectionService(() => "blob");

    await expect(service.list(root, "crowded")).rejects.toMatchObject({ code: "conflict" });
  });

  it("rejects oversized file snapshots before blob registration", async () => {
    const root = await repository();
    const large = join(root, "large.bin");
    await writeFile(large, "x");
    await truncate(large, 25 * 1_048_576 + 1);
    let registered = false;
    const service = new WorkspaceInspectionService(() => {
      registered = true;
      return "blob";
    });

    await expect(service.file(root, "large.bin")).rejects.toMatchObject({ code: "conflict" });
    expect(registered).toBe(false);
  });

  it("produces bounded current and untracked diffs", async () => {
    const root = await repository();
    await writeFile(join(root, "README.md"), "changed\n");
    await writeFile(join(root, "new.txt"), "new line\n");
    const service = new WorkspaceInspectionService(() => "blob");

    await expect(service.diff(root, "README.md", "current")).resolves.toMatchObject({
      binary: false,
      truncated: false,
      patch: expect.stringContaining("+changed"),
    });
    await expect(service.diff(root, "new.txt", "current")).resolves.toMatchObject({
      binary: false,
      patch: expect.stringContaining("+new line"),
    });
  });

  it("keeps nested-workspace history and reported roots inside the session workspace", async () => {
    const root = await repository();
    const workspace = join(root, "Package");
    await mkdir(workspace);
    await writeFile(join(root, "outside.txt"), "outside\n");
    await git(root, "add", "outside.txt");
    await git(root, "commit", "-qm", "outside only");
    const outsideOID = await git(root, "rev-parse", "HEAD");
    await writeFile(join(workspace, "inside.txt"), "inside\n");
    await git(root, "add", "Package/inside.txt");
    await git(root, "commit", "-qm", "inside");
    const service = new WorkspaceInspectionService(() => "blob");

    const canonicalWorkspace = await realpath(workspace);
    const inspection = await service.inspect(workspace);
    expect(inspection.root).toBe(canonicalWorkspace);
    expect(inspection.repository?.root).toBe(canonicalWorkspace);
    const history = await service.historyList(workspace, "client", "currentBranch", undefined, 10);
    expect(history.commits.map((commit) => commit.subject)).toEqual(["inside"]);
    await expect(service.historyGet(workspace, outsideOID)).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("pages history with a client-bound cursor and returns commit details", async () => {
    const root = await repository();
    await writeFile(join(root, "one.txt"), "one\n");
    await git(root, "add", "one.txt");
    await git(root, "commit", "-qm", "one");
    await writeFile(join(root, "two.txt"), "two\n");
    await git(root, "add", "two.txt");
    await git(root, "commit", "-qm", "two");
    const service = new WorkspaceInspectionService(() => "blob");

    const first = await service.historyList(root, "client-a", "currentBranch", undefined, 1);
    expect(first.commits).toHaveLength(1);
    expect(first.commits[0]?.subject).toBe("two");
    expect(first.nextCursor).toBeTruthy();
    await expect(service.historyList(root, "client-b", "currentBranch", first.nextCursor, 1))
      .rejects.toMatchObject({ code: "conflict" });
    const second = await service.historyList(root, "client-a", "currentBranch", first.nextCursor, 1);
    expect(second.commits[0]?.subject).toBe("one");

    const detail = await service.historyGet(root, first.commits[0]!.oid);
    expect(detail).toMatchObject({ subject: "two" });
    expect(detail.changes).toContainEqual(expect.objectContaining({ path: "two.txt", kind: "added" }));
    await expect(service.historyDiff(root, detail.oid, "two.txt")).resolves.toMatchObject({
      path: "two.txt",
      binary: false,
      truncated: false,
      patch: expect.stringContaining("+two"),
    });
    await expect(service.historyDiff(root, detail.oid, "../outside.txt"))
      .rejects.toMatchObject({ code: "invalid_request" });
  });
});
