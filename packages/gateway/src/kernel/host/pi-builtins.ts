import { join, dirname } from "node:path";
import { createHash } from "node:crypto";
import { readFileSync, accessSync, constants } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import nativeBrowser from "pi-agent-browser-native";
import {
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  type ExtensionFactory,
} from "../pi/coding-agent.js";
import { managedBrowserEnabled } from "../pi/packages.js";

function browserExtension(agentDir: string): ExtensionFactory {
  const gateway = fileURLToPath(new URL("../../..", import.meta.url));
  const pin = JSON.parse(readFileSync(join(gateway, "pi-agent-browser-native-patch.json"), "utf8")) as {
    version: string; artifact: { path: string; integrity: string };
  };
  const integrity = `sha512-${createHash("sha512").update(readFileSync(join(gateway, pin.artifact.path))).digest("base64")}`;
  if (integrity !== pin.artifact.integrity) throw new Error("Managed browser artifact integrity mismatch");
  const lock = JSON.parse(readFileSync(join(gateway, "package-lock.json"), "utf8")) as {
    packages: Record<string, { version?: string; resolved?: string; integrity?: string }>;
  };
  const dependency = lock.packages["node_modules/pi-agent-browser-native"];
  if (dependency?.version !== pin.version || dependency.resolved !== `file:${pin.artifact.path}`
    || dependency.integrity !== pin.artifact.integrity) throw new Error("Managed browser lock does not match its artifact pin");
  const require = createRequire(import.meta.url);
  const browser = require.resolve("pi-agent-browser-native/package.json");
  const metadata = JSON.parse(readFileSync(browser, "utf8")) as { version: string };
  if (metadata.version !== pin.version) throw new Error("Managed browser dependency does not match its artifact pin");
  const engine = require.resolve("agent-browser/package.json", { paths: [dirname(browser)] });
  const engineExecutable = join(dirname(engine), "bin", "agent-browser.js");
  accessSync(engineExecutable, constants.X_OK);
  return (pi) => nativeBrowser(pi, { ownedProfilePath: join(agentDir, "browser", "profile"), engineExecutable });
}

export function managedBrowserExtensions(agentDir: string, settings: Parameters<typeof managedBrowserEnabled>[0]): Array<{ name: string; factory: ExtensionFactory; builtin: true; replaceable: false }> {
  return managedBrowserEnabled(settings) ? [{ name: "agent-browser", factory: browserExtension(agentDir), builtin: true, replaceable: false }] : [];
}

export function piBuiltinExtensions(
  agentDir: string,
  openMcpUrl?: (url: string) => void,
): Array<{ name: string; factory: ExtensionFactory; builtin: true; replaceable: true }> {
  return [
    { name: "codemode", factory: createCodemodeExtension(), builtin: true, replaceable: true },
    { name: "tool-search", factory: createToolSearchExtension(), builtin: true, replaceable: true },
    {
      name: "mcp",
      factory: createMcpExtension({
        logPath: join(agentDir, "mcp.log"),
        openUrl: openMcpUrl ?? (() => { throw new Error("MCP sign-in requires an active Tron authorization operation"); }),
      }),
      builtin: true,
      replaceable: true,
    },
  ];
}
