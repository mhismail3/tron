import { join } from "node:path";
import {
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  type ExtensionFactory,
} from "@earendil-works/pi-coding-agent";

/** Pi's MCP loader reads mcp.json from getAgentDir() and only reads project
 * configuration after the resource loader's TrustService-owned trust gate. The
 * Gateway pins PI_CODING_AGENT_DIR to its agent directory at startup. */
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
        // A missing session operation fails closed; it can never reach the Mac browser.
        openUrl: openMcpUrl ?? (() => { throw new Error("MCP sign-in requires an active Tron authorization operation"); }),
      }),
      builtin: true,
      replaceable: true,
    },
  ];
}
