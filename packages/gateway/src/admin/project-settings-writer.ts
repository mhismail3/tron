import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { GatewayError } from "../errors.js";
import type { ProjectGitState } from "../kernel/settings/settings-types.js";

const GIT_TIMEOUT_MS = 15_000;
function git(cwd: string, args: string[]): Promise<{ ok: boolean; stdout: string; stderr: string }> {
  return new Promise(resolve => {
    execFile("git", ["-C", cwd, ...args], { timeout: GIT_TIMEOUT_MS, maxBuffer: 1_048_576, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" } },
      (error, stdout, stderr) => resolve({ ok: !error, stdout: String(stdout), stderr: String(stderr) }));
  });
}

export function projectSettingsPath(root: string): string {
  return join(root, ".pi", "settings.json");
}

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

export type GitHeadState = { root: string; path: string; head: string | null; branch: string | null };
export async function gitHeadState(root: string): Promise<GitHeadState | undefined> {
  const read = await git(root, ["rev-parse", "--show-toplevel", "HEAD", "--abbrev-ref", "HEAD"]);
  const [top, head, branch] = read.stdout.split("\n").map(line => line.trim());
  if (!top || !top.startsWith("/")) return undefined;
  const state = { root: top, path: relative(top, projectSettingsPath(root)) };
  if (read.ok && head && branch) return { ...state, head, branch: branch === "HEAD" ? null : branch };
  const unborn = await git(top, ["branch", "--show-current"]);
  return { ...state, head: null, branch: unborn.ok && unborn.stdout.trim() ? unborn.stdout.trim() : null };
}

export async function stagedBlob(root: string, spec: string): Promise<string | undefined> {
  const blob = await git(root, ["rev-parse", "--verify", "-q", spec]);
  return blob.ok ? blob.stdout.trim() : undefined;
}

export async function projectGitState(root: string, known?: GitHeadState | null): Promise<ProjectGitState> {
  const state = known === undefined ? await gitHeadState(root) : known ?? undefined;
  if (!state) return { kind: "local", reason: "not in a git repository" };
  if ((await git(state.root, ["check-ignore", "-q", "--", state.path])).ok) return { kind: "local", reason: ".pi is ignored by git" };
  const show = async (spec: string) => {
    const result = await git(state.root, ["show", spec]);
    if (!result.ok || !result.stdout.trim()) return undefined;
    try {
      const value = JSON.parse(result.stdout.replace(/^\uFEFF/u, "")) as unknown;
      return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
    } catch { return undefined; }
  };
  const [head, index] = await Promise.all([state.head ? show(`HEAD:${state.path}`) : undefined, show(`:${state.path}`)]);
  return { kind: "repo", ...(head ? { head } : {}), ...(index ? { index } : {}) };
}
