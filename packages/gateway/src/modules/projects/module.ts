import { StringEnum, Type } from "../../kernel/pi/ai.js";
import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import type { JsonValue } from "../../protocol/types.js";
import { boolean, integer, rejectUnknownFields, string, text } from "../../util/validation.js";
import { ProjectLifecycle, type ProjectRequest } from "./project-lifecycle.js";
import { approvalFormPresenter } from "../../kernel/host/approval-form.js";
import { approvalWaitParameter } from "../../kernel/settings/tool-contract.js";

export function projectsModule(owner: ProjectLifecycle): ModuleDescriptor<ProjectLifecycle> {
  return { name: "tron-projects", purpose: "Creates projects and requests maintainer-approved trust, rename, recoverable archive and untrust through the canonical approvals owner.", tools: ["projects"], commands: [],
    start: () => ({ contract: owner, capabilities: ["projects.lifecycle.v1"], rpc: {
      "projects.list": { kind: "read", handle: async (params, context) => {
        rejectUnknownFields(params, ["limit", "after"], "projects.list");
        return await owner.list({ limit: params.limit === undefined ? 25 : integer(params.limit, "limit", 1, 50),
          ...(params.after === undefined ? {} : { after: text(params.after, "after", 255) }) }, context.signal) as unknown as JsonValue;
      } },
      "projects.inspect": { kind: "read", handle: async (params, context) => {
        rejectUnknownFields(params, ["cwd"], "projects.inspect");
        return await owner.read(text(params.cwd, "cwd", 4096), context.signal) as unknown as JsonValue;
      } },
      "projects.request": { kind: "mutation", handle: async (params, context) => {
        rejectUnknownFields(params, ["commandId", "action", "name", "newName", "github", "reason"], "projects.request");
        const input: ProjectRequest = {
          action: text(params.action, "action", 16) as ProjectRequest["action"],
          name: text(params.name, "name", 64),
          reason: string(params.reason, "reason", { min: 1, max: 2000 }),
          ...(params.newName === undefined ? {} : { newName: text(params.newName, "newName", 64) }),
          ...(params.github === undefined ? {} : { github: boolean(params.github, "github") }),
        };
        return await owner.request(input, { kind: "ui", id: context.identity },
          string(params.commandId, "commandId", { min: 8, max: 160 })) as unknown as JsonValue;
      } },
    }, extension: session => pi => {
      pi.registerTool({ name: "projects", label: "Projects", annotations: { openWorldHint: false }, executionMode: "sequential",
        description: "Manage direct-child projects in ~/Workspace. create exclusively creates a folder and git repository on main, then requests trust. trust, rename, archive and untrust request the maintainer's tap (24h expiry); never self-approve. The request shows in this chat; wait true waits for his decision, otherwise it returns pending at once. Optional github creates a private repository and origin only after approval, without pushing. Existing paths, symlinks and worker/worktree/claim ownership are refused. Archive retains files in ~/Workspace/.archive. Failures may retain partial untrusted work: inspect before retrying.",
        promptSnippet: "Use projects for project creation and maintainer-approved lifecycle changes; never write trust files.",
        parameters: Type.Object({ action: StringEnum(["create", "trust", "rename", "archive", "untrust"] as const), name: Type.String({ minLength: 1, maxLength: 64 }),
          newName: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })), github: Type.Optional(Type.Boolean()), reason: Type.String({ minLength: 1, maxLength: 2000 }),
          wait: approvalWaitParameter(false) }, { additionalProperties: false }),
        execute: async (toolCallId, raw, signal, _update, context) => {
          const id = session.sessionId();
          const { wait, ...input } = raw as ProjectRequest & { wait?: boolean };
          const requested = await owner.request(input, { kind: session.profile().settingsActor === "home" ? "home" : session.delegatedWorker() ? "worker" : "agent", id, sessionId: id, toolCallId }, toolCallId);
          // One approval request either way (#2050): wait in this chat, or return pending.
          const result = requested.status === "pending" && wait ? await owner.wait(requested.approval!.requestId, id, approvalFormPresenter(context), signal) : requested;
          return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
        },
      });
    } }),
  };
}
