import { stat } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { Type } from "../../kernel/pi/ai.js";
import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import type { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";

const PARAMETERS = Type.Object({
  path: Type.String({ minLength: 1, maxLength: 4_096, description: "Absolute path to a Tron session .jsonl file on this Mac." }),
  cwd: Type.Optional(Type.String({ minLength: 1, maxLength: 4_096,
    description: "Tron Home only (required there): the workspace folder the imported session joins. Ordinary chats omit it." })),
}, { additionalProperties: false });

export interface SessionImportOwners {
  registry: RuntimeRegistry;
  maxBytes: number;
}

export function sessionImportModule(owners: () => SessionImportOwners): ModuleDescriptor {
  return {
    name: "tron-session-import",
    purpose: "Imports a session file the user names as a new canonical session, through the registry's import owner.",
    tools: ["session_import"],
    commands: [],
    start: () => ({ extension: session => pi => {
      pi.registerTool({
        name: "session_import", label: "Session import", annotations: { openWorldHint: false }, executionMode: "sequential",
        description: "Import a Tron session .jsonl file into a workspace as a new session. The import is a new canonical session with its own id; the file is never replayed. Returns the new session id only.",
        promptSnippet: "Use session_import when the user asks to import a session file they name.",
        parameters: PARAMETERS,
        execute: async (_toolCallId, raw) => {
          const input = raw as { path: string; cwd?: string };
          const home = session.profile().settingsActor === "home";
          if (home && input.cwd === undefined) throw new Error("session_import: cwd is required in Home; name the workspace the session joins");
          if (!home && input.cwd !== undefined && input.cwd !== session.cwd()) {
            throw new Error("session_import: an ordinary chat imports into its own workspace; omit cwd");
          }
          if (!isAbsolute(input.path) || !input.path.endsWith(".jsonl")) throw new Error("session_import: path must be an absolute .jsonl file");
          const { maxBytes, registry } = owners();
          const info = await stat(input.path);
          if (!info.isFile() || info.size < 1 || info.size > maxBytes) {
            throw new Error(`session_import: the file must be a regular file of 1 byte through ${maxBytes} bytes`);
          }
          const cwd = input.cwd ?? session.cwd();
          const slot = await registry.importFromJsonl(input.path, cwd);
          const result = { sessionId: slot.id, summary: `Imported as a new session in ${cwd}.` };
          return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
        },
      });
    } }),
  };
}
