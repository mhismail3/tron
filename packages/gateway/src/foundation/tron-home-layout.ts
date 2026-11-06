import { lstat } from "node:fs/promises";
import { join } from "node:path";
import layout from "./tron-home-layout.json" with { type: "json" };

/**
 * The one declaration of every path under a Tron home (docs/tron-home.md).
 * Each entry names its owner, writer, lifecycle, rebuild, backup, sensitivity
 * and retention; `scripts/tron home-layout check` refuses a home-relative path
 * literal anywhere else, and `audit` reports on-disk entries it does not list.
 */
type Registered = keyof typeof layout.paths;
/** Patterns (`*`) describe families for the audit; code resolves exact entries. */
export type TronHomePath = Exclude<Registered, `${string}*${string}`>;
export type TronWorkspacePath = TronHomePath extends infer P ? P extends `workspace/${infer Rest}` ? Rest : never : never;

export function tronHomePath(tronHome: string, path: TronHomePath, ...children: string[]): string {
  return join(tronHome, path, ...children);
}

/** Workspace owners hold the workspace root, not the Tron home; the registry key stays home-relative. */
export function tronWorkspacePath(workspaceRoot: string, path: TronWorkspacePath, ...children: string[]): string {
  return join(workspaceRoot, path, ...children);
}

/**
 * A home still holding a retired location has not run the offline layout
 * migration. Startup refuses it rather than reading either place: the
 * migration is the only reader of old locations.
 */
export async function assertTronHomeLayoutCurrent(tronHome: string): Promise<void> {
  const pending: string[] = [];
  for (const { from, to } of layout.retired) {
    const present = await lstat(join(tronHome, from)).then(() => true, (error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return false;
      throw error;
    });
    if (present) pending.push(`${from} -> ${to}`);
  }
  if (pending.length > 0) {
    throw new Error(`Tron home ${tronHome} uses a retired layout (${pending.join(", ")}). `
      + `Stop Tron and run: scripts/tron home-layout migrate --home ${tronHome}`);
  }
}
