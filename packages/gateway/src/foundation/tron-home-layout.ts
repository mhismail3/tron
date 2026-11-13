import { lstat, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
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

export async function assertHomeLayout(home: string): Promise<void> {
  const instruction = () => new GatewayError("conflict", `Tron home requires the offline layout migration: scripts/tron home-layout migrate --home '${home.replaceAll("'", "'\\''")}' --apply`);
  const exists = async (path: string) => {
    try { return await lstat(path); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
  };
  const state = await exists(tronHomePath(home, "state"));
  if (state && (!state.isDirectory() || state.isSymbolicLink())) throw instruction();
  const stamp = tronHomePath(home, "state/layout.json");
  const stampInfo = await exists(stamp);
  let stamped = false;
  if (stampInfo) {
    if (!stampInfo.isFile() || stampInfo.isSymbolicLink() || stampInfo.size > 128) throw instruction();
    try { stamped = JSON.stringify(JSON.parse(await readFile(stamp, "utf8"))) === '{"version":2}'; }
    catch { throw instruction(); }
    if (!stamped) throw instruction();
  }
  const marker = "retired by layout 2; merge main\n";
  for (const { from, to } of layout.retired) {
    if (from.includes("/") || to.startsWith("~/")) continue;
    const path = join(home, from);
    const info = await exists(path);
    if (info && (!stamped || !info.isFile() || info.isSymbolicLink() || info.size !== Buffer.byteLength(marker) || await readFile(path, "utf8") !== marker)) throw instruction();
  }
}

export async function initializeHomeLayout(home: string): Promise<void> {
  await assertHomeLayout(home);
  const directory = tronHomePath(home, "state");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  try { await writeFile(tronHomePath(home, "state/layout.json"), '{"version":2}\n', { mode: 0o600, flag: "wx" }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; await assertHomeLayout(home); }
}
