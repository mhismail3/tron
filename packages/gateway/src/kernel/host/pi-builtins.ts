import { join } from "node:path";
import {
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  type ExtensionFactory,
} from "../pi/coding-agent.js";

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
