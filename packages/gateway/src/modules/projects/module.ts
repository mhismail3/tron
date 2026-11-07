import { GatewayError } from "../../errors.js";
import { Type } from "../../kernel/pi/ai.js";
import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import type { JsonValue } from "../../protocol/types.js";
import { integer, rejectUnknownFields, string, text } from "../../util/validation.js";
import { ProjectLifecycle, type ProjectRequest } from "./project-lifecycle.js";
import { nativeChangeConfirmer } from "../../kernel/host/native-change.js";

function projectConfirmation(value: unknown): { digest: string; intent: unknown } {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("invalid_request", "Project confirmation is invalid");
  const input = value as Record<string, unknown>;
  rejectUnknownFields(input, ["digest", "intent"], "project confirmation");
  return { digest: string(input.digest, "digest", { min: 64, max: 64 }), intent: input.intent };
}

export function projectsModule(owner: ProjectLifecycle): ModuleDescriptor<ProjectLifecycle> {
  return { name: "tron-projects", purpose: "Creates and manages projects through exact paired-native review and canonical mutation receipts.", tools: ["projects"], commands: [],
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
      "projects.change": { kind: "mutation", handle: async (params, context) => {
        rejectUnknownFields(params, ["commandId", "action", "name", "reason", "confirmation"], "projects.change");
        if (params.confirmation !== undefined && context.isLocal) throw new GatewayError("auth_required", "An exact project tap requires a paired native device");
        const input: ProjectRequest = {
          action: text(params.action, "action", 16) as ProjectRequest["action"],
          name: text(params.name, "name", 64),
          reason: string(params.reason, "reason", { min: 1, max: 2000 }),
        };
        return await owner.request(input, { kind: "ui", id: context.identity },
          string(params.commandId, "commandId", { min: 8, max: 160 }), params.confirmation === undefined ? {} : { confirmation: projectConfirmation(params.confirmation) }) as unknown as JsonValue;
      } },
    }, extension: session => pi => {
      pi.registerTool({ name: "projects", label: "Projects", annotations: { openWorldHint: false }, executionMode: "sequential",
        description: "Create a direct-child Workspace project: an untrusted folder with a Git repository on main, then trusted after the exact shared native tap. Existing paths are never overwritten. Change an existing project's trust with the settings tool (permissions.projectTrust); use git and gh directly for everything else. No automatic replay after uncertain effects: inspect the filesystem, Git and trust before another action.",
        promptSnippet: "Use projects to create a project; change project trust with the settings tool; never write trust files.",
        parameters: Type.Object({ name: Type.String({ minLength: 1, maxLength: 64 }), reason: Type.String({ minLength: 1, maxLength: 2000 }),
          }, { additionalProperties: false }),
        execute: async (toolCallId, raw, signal, _update, context) => {
          const id = session.sessionId();
          const confirm = nativeChangeConfirmer(context, session.requestChange, signal);
          const input = raw as { name: string; reason: string };
          const result = await owner.request({ action: "create", name: input.name, reason: input.reason }, { kind: session.profile().settingsActor === "home" ? "home" : session.delegatedWorker() ? "worker" : "agent", id, sessionId: id, toolCallId }, toolCallId, confirm ? { confirm } : {});
          return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
        },
      });
    } }),
  };
}
