import { join } from "node:path";
import layout from "./tron-home-layout.json" with { type: "json" };

/**
 * The one declaration of every path under a Tron home (docs/tron-home.md).
 * Each entry names its owner, writer, lifecycle, rebuild, backup, sensitivity
 * and retention; `scripts/tron home-layout check` refuses a home-relative path
 * literal anywhere else.
 */
type Registered = keyof typeof layout.paths;
/** Patterns (`*`) describe families; code resolves exact entries. */
type TronHomePath = Exclude<Registered, `${string}*${string}`>;
type TronWorkspacePath = TronHomePath extends infer P ? P extends `workspace/${infer Rest}` ? Rest : never : never;

export function tronHomePath(tronHome: string, path: TronHomePath, ...children: string[]): string {
  return join(tronHome, path, ...children);
}

/** Workspace owners hold the workspace root, not the Tron home; the registry key stays home-relative. */
export function tronWorkspacePath(workspaceRoot: string, path: TronWorkspacePath, ...children: string[]): string {
  return join(workspaceRoot, path, ...children);
}
