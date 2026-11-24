import { join, dirname } from "node:path";
import { createHash } from "node:crypto";
import { readFileSync, accessSync, constants } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import nativeBrowser from "pi-agent-browser-native";
import type { ExtensionFactory } from "../pi/coding-agent.js";

function pinnedArtifact(gateway: string, pinFile: string, name: string, lock: { packages: Record<string, { version?: string; resolved?: string; integrity?: string }> }): void {
  const pin = JSON.parse(readFileSync(join(gateway, pinFile), "utf8")) as { version: string; artifact: { path: string; integrity: string } };
  const integrity = `sha512-${createHash("sha512").update(readFileSync(join(gateway, pin.artifact.path))).digest("base64")}`;
  if (integrity !== pin.artifact.integrity) throw new Error(`Managed browser artifact ${name} integrity mismatch`);
  const dependency = lock.packages[`node_modules/${name}`];
  if (dependency?.version !== pin.version || dependency.resolved !== `file:${pin.artifact.path}`
    || dependency.integrity !== pin.artifact.integrity) throw new Error(`Managed browser lock for ${name} does not match its artifact pin`);
  const require = createRequire(import.meta.url);
  const metadata = JSON.parse(readFileSync(require.resolve(`${name}/package.json`), "utf8")) as { version: string };
  if (metadata.version !== pin.version) throw new Error(`Managed browser dependency ${name} does not match its artifact pin`);
}

export function browserExtension(agentDir: string): ExtensionFactory {
  const gateway = fileURLToPath(new URL("../../..", import.meta.url));
  const lock = JSON.parse(readFileSync(join(gateway, "package-lock.json"), "utf8")) as {
    packages: Record<string, { version?: string; resolved?: string; integrity?: string }>;
  };
  pinnedArtifact(gateway, "pi-agent-browser-native-patch.json", "pi-agent-browser-native", lock);
  pinnedArtifact(gateway, "agent-browser-patch.json", "agent-browser", lock);
  const require = createRequire(import.meta.url);
  const browser = require.resolve("pi-agent-browser-native/package.json");
  const engine = require.resolve("agent-browser/package.json", { paths: [dirname(browser)] });
  const engineExecutable = join(dirname(engine), "bin", "agent-browser.js");
  accessSync(engineExecutable, constants.X_OK);
  return (pi) => nativeBrowser(pi, { ownedProfilePath: join(agentDir, "browser", "profile"), engineExecutable });
}
