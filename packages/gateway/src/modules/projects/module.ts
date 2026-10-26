import { StringEnum, Type } from "../../kernel/pi/ai.js";
import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import { ProjectLifecycle, type ProjectRequest } from "./project-lifecycle.js";

export function projectsModule(owner: ProjectLifecycle): ModuleDescriptor<ProjectLifecycle> {
  return { name: "tron-projects", purpose: "Creates projects and requests maintainer-approved trust, rename, recoverable archive and untrust through the canonical approvals owner.", tools: ["projects"], commands: [],
    start: () => ({ contract: owner, extension: session => pi => {
      pi.registerTool({ name: "projects", label: "Projects", annotations: { openWorldHint: false }, executionMode: "sequential",
        description: "Manage direct-child projects in ~/Workspace. create exclusively creates a folder and git repository on main, then requests trust. trust, rename, archive and untrust request the maintainer's tap (24h expiry); never self-approve. Optional github creates a private repository and origin only after approval, without pushing. Existing paths, symlinks and worker/worktree/claim ownership are refused. Archive retains files in ~/Workspace/.archive. Failures may retain partial untrusted work: inspect before retrying.",
        promptSnippet: "Use projects for project creation and maintainer-approved lifecycle changes; never write trust files.",
        parameters: Type.Object({ action: StringEnum(["create", "trust", "rename", "archive", "untrust"] as const), name: Type.String({ minLength: 1, maxLength: 64 }),
          newName: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })), github: Type.Optional(Type.Boolean()), reason: Type.String({ minLength: 1, maxLength: 2000 }) }, { additionalProperties: false }),
        execute: async (toolCallId, input) => {
          const id = session.sessionId();
          const result = await owner.request(input as ProjectRequest, { kind: session.profile().settingsActor === "home" ? "home" : session.delegatedWorker() ? "worker" : "agent", id, sessionId: id, toolCallId }, toolCallId);
          return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
        },
      });
    } }),
  };
}
