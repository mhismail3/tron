import { join, extname } from "node:path";
import { browserExtension } from "./managed-browser.js";
import { fileURLToPath } from "node:url";
import {
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  serversSectionIntro,
  type ExtensionFactory,
  type McpElicitation,
} from "../pi/coding-agent.js";
import { mcpServersIndex } from "../resources/context-index.js";
import { managedBrowserEnabled } from "../pi/packages.js";
import type { SessionContext } from "./module-host.js";

const CHILD_BROWSER = fileURLToPath(new URL(`./agent-browser-child${extname(fileURLToPath(import.meta.url))}`, import.meta.url));

export function managedBrowserExtensions(agentDir: string, settings: Parameters<typeof managedBrowserEnabled>[0],
  requireChildExtensions?: SessionContext["requireChildExtensions"]): Array<{ name: string; factory: ExtensionFactory; builtin: true; replaceable: false }> {
  if (!managedBrowserEnabled(settings)) return [];
  const browser = browserExtension(agentDir);
  return [{ name: "agent-browser", builtin: true, replaceable: false, factory: requireChildExtensions ? (pi) => {
    browser(pi);
    let registration: { dispose(): void } | undefined;
    pi.on("session_start", async (_event, ctx) => {
      registration?.dispose();
      registration = await requireChildExtensions(ctx.sessionManager.getSessionId(), [{ id: "tron-agent-browser", path: CHILD_BROWSER }]);
    });
    pi.on("session_shutdown", () => { registration?.dispose(); registration = undefined; });
  } : browser }];
}

export function toolSearchExtension(active: boolean): { name: string; factory: ExtensionFactory; builtin: true; replaceable: true } {
  const register = createToolSearchExtension();
  return { name: "tool-search", builtin: true, replaceable: true, factory: active ? (pi) => {
    register(pi);
    pi.on("session_start", () => {
      const tools = pi.getActiveTools();
      if (!tools.includes("tool_search")) pi.setActiveTools([...tools, "tool_search"]);
    });
  } : register };
}

export function piBuiltinExtensions(
  agentDir: string,
  openMcpUrl?: (url: string) => void,
  activeToolSearch = false,
  elicitation?: McpElicitation,
): Array<{ name: string; factory: ExtensionFactory; builtin: true; replaceable: true }> {
  return [
    { name: "codemode", factory: createCodemodeExtension(), builtin: true, replaceable: true },
    toolSearchExtension(activeToolSearch),
    {
      name: "mcp",
      factory: createMcpExtension({
        logPath: join(agentDir, "mcp.log"),
        openUrl: openMcpUrl ?? (() => { throw new Error("MCP sign-in requires an active Tron authorization operation"); }),
        renderServers: servers => mcpServersIndex(servers, serversSectionIntro(new Set(servers.map(server => server.reach)))),
        ...(elicitation ? { elicitation } : {}),
      }),
      builtin: true,
      replaceable: true,
    },
  ];
}
