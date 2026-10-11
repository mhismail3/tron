import { execFile } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { GitResult } from "./settings-record.js";

/**
 * The Project layer's applier (docs/settings-model.md 5.7, decision 14).
 *
 * The store is `.pi/settings.json` on disk. Tron writes the key, keeping every
 * other key and the file's indentation, then stages that one path with
 * `git add` when git can take it. It never commits, pushes or opens a pull
 * request. A file that cannot be parsed (unresolved merge markers) is refused
 * untouched; anything git cannot take leaves the write standing, unstaged, with
 * the reason recorded.
 */

const GIT_TIMEOUT_MS = 15_000;
const locks = new Map<string, AsyncMutex>();

function lockFor(path: string): AsyncMutex {
  let lock = locks.get(path);
  if (!lock) { lock = new AsyncMutex(); locks.set(path, lock); }
  return lock;
}

function git(cwd: string, args: string[]): Promise<{ ok: boolean; stdout: string; stderr: string }> {
  return new Promise(resolve => {
    execFile("git", ["-C", cwd, ...args], { timeout: GIT_TIMEOUT_MS, maxBuffer: 1_048_576, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" } },
      (error, stdout, stderr) => resolve({ ok: !error, stdout: String(stdout), stderr: String(stderr) }));
  });
}

export function projectSettingsPath(root: string): string {
  return join(root, ".pi", "settings.json");
}

/** Reads the Project store as JSON. A missing file is an empty layer. */
export async function readProjectDocument(root: string): Promise<{ text: string | undefined; document: Record<string, unknown> }> {
  let text: string | undefined;
  try {
    text = await readFile(projectSettingsPath(root), "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  if (text === undefined || !text.trim()) return { text, document: {} };
  let value: unknown;
  try {
    value = JSON.parse(text.replace(/^\uFEFF/u, ""));
  } catch {
    throw new GatewayError("conflict", "The project's .pi/settings.json cannot be parsed (it may hold unresolved merge markers); it was left untouched");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new GatewayError("conflict", "The project's .pi/settings.json is not a JSON object; it was left untouched");
  }
  return { text, document: value as Record<string, unknown> };
}

function indentation(text: string | undefined): string | number {
  const match = text ? /\n([ \t]+)"/u.exec(text) : null;
  return match ? match[1]! : 2;
}

/** Write one document update and stage the file. Returns the git result. */
export async function writeProjectSettings(
  root: string,
  update: (document: Record<string, unknown>) => Record<string, unknown>,
): Promise<{ before: Record<string, unknown>; git: GitResult }> {
  const path = projectSettingsPath(root);
  return lockFor(path).run(async () => {
    const { text, document } = await readProjectDocument(root);
    const before = structuredClone(document);
    const next = update(structuredClone(document));
    // Probe the index before writing so a maintainer's own unstaged edits to
    // this file are named in the warning (Q26, decision 29).
    const top = await git(root, ["rev-parse", "--show-toplevel"]);
    const repository = top.ok ? top.stdout.trim() : null;
    const relativePath = repository ? relative(repository, path) : path;
    const unstagedBefore = repository ? !(await git(repository, ["diff", "--quiet", "--", relativePath])).ok : false;
    await mkdir(dirname(path), { recursive: true });
    const temporary = `${path}.tron-${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify(next, null, indentation(text))}\n`, "utf8");
    await rename(temporary, path);
    return { before, git: await stage(repository, path, relativePath, unstagedBefore) };
  });
}

async function stage(repository: string | null, path: string, relativePath: string, unstagedBefore: boolean): Promise<GitResult> {
  if (!repository) return { root: null, path, staged: false, reason: "not in a git repository" };
  if ((await git(repository, ["check-ignore", "-q", "--", relativePath])).ok) {
    return { root: repository, path: relativePath, staged: false, reason: ".pi is ignored by git" };
  }
  const others = (await git(repository, ["diff", "--cached", "--name-only", "--", ".", `:(exclude)${relativePath}`])).stdout.split("\n").filter(Boolean);
  const added = await git(repository, ["add", "--", relativePath]);
  if (!added.ok) {
    return { root: repository, path: relativePath, staged: false, reason: added.stderr.includes("index.lock") ? "the git index is locked" : `git add failed: ${added.stderr.trim().slice(0, 200)}` };
  }
  const blob = await git(repository, ["rev-parse", `:${relativePath}`]);
  const warnings: string[] = [];
  if (others.length) warnings.push(`Other staged work: ${others.length === 1 ? others[0] : `${others.length} paths`}`);
  if (unstagedBefore) warnings.push("Also staged unstaged edits that were already in this file");
  return {
    root: repository, path: relativePath, staged: true,
    ...(blob.ok ? { blob: blob.stdout.trim() } : {}),
    ...(warnings.length ? { warning: warnings.join("; ") } : {}),
  };
}
