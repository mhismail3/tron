import { realpath } from "node:fs/promises";
import { GatewayError } from "../../errors.js";
import { runGit, type GitResult } from "../../util/git-inspection.js";

/**
 * The Project root of a canonical chat cwd: the directory whose `.pi/` is the
 * Project layer, keys project trust and is the SDK session's `projectDir`
 * (settings-model decision 31). It is the realpath of the enclosing Git
 * worktree's top level, so each linked worktree is its own Project. Whenever
 * Git gives no work tree (no repository, a cwd inside `.git`, a refused
 * ownership check, or no usable `git`), the cwd itself is the Project, which is
 * the behavior without a root. A timeout or oversized answer stays a retryable
 * error, so a slow Git can never key one decision to two directories. The chat
 * keeps its own cwd for tools and context files.
 */
export async function projectRoot(cwd: string): Promise<string> {
  let result: GitResult;
  try {
    result = await runGit(cwd, ["rev-parse", "--show-toplevel"], { maximumBytes: 8_192, allowedExitCodes: [0, 1, 128] });
  } catch (error) {
    if (error instanceof GatewayError && error.code === "internal") return cwd;
    throw error;
  }
  const value = result.stdout.toString("utf8").trim();
  return result.exitCode === 0 && value ? await realpath(value) : cwd;
}
