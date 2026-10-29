import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { TestProject } from "vitest/node";

declare module "vitest" { export interface ProvidedContext { nativePublicationBinary: string } }

/** Global setup owns compiler/cache lifetime; per-file hooks only open readers. */
export default async function setup(project: TestProject) {
  const supplied = process.env.TRON_DIRECTORY_PUBLICATION_TEST_BINARY;
  if (supplied) { project.provide("nativePublicationBinary", supplied); return; }
  const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
  const child = spawn("python3", [resolve(repo, "packages/gateway/test-support/native-publication-fixture.py"), repo,
    resolve(repo, "test-results/native-publication/cache"), resolve(dirname(process.execPath), "../include/node")], { stdio: ["pipe", "pipe", "inherit"] });
  const exited = new Promise<number | null>((resolve, reject) => { child.once("exit", resolve); child.once("error", reject); });
  try {
    const ready = await new Promise<{ artifact: string; sourceHash: string; cacheHit: boolean }>((resolve, reject) => {
      let buffer = "";
      child.stdout.setEncoding("utf8").on("data", chunk => {
        buffer += chunk;
        if (buffer.length > 8192) { reject(new Error("Native fixture readiness exceeds bounds")); return; }
        if (!buffer.includes("\n")) return;
        try { resolve(JSON.parse(buffer)); } catch (error) { reject(error); }
      });
      void exited.then(code => reject(new Error(`Native fixture preparation exited before readiness (${code})`)), reject);
    });
    project.provide("nativePublicationBinary", ready.artifact);
    console.log(`[native fixture] ${ready.cacheHit ? "reuse" : "compiled"} ${ready.sourceHash}`);
    return async () => {
      child.stdin.end();
      const code = await exited;
      if (code !== 0) throw new Error(`Native fixture owner exited ${code}`);
    };
  } catch (error) { child.stdin.end(); await exited; throw error; }
}
