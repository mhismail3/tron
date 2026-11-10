import { join } from "node:path";
import layout from "./tron-home-layout.json" with { type: "json" };

type Registered = keyof typeof layout.paths;
type TronHomePath = Exclude<Registered, `${string}*${string}`>;
type TronWorkspacePath = TronHomePath extends infer P ? P extends `workspace/${infer Rest}` ? Rest : never : never;

export function tronHomePath(tronHome: string, path: TronHomePath, ...children: string[]): string {
  return join(tronHome, path, ...children);
}

export function tronWorkspacePath(workspaceRoot: string, path: TronWorkspacePath, ...children: string[]): string {
  return join(workspaceRoot, path, ...children);
}
