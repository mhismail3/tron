import { realpath } from "node:fs/promises";
import { GatewayError } from "../../errors.js";
import { runGit, type GitResult } from "../../util/git-inspection.js";

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
