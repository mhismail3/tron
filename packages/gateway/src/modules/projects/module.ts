import { Type } from "../../kernel/pi/ai.js";
import type { ModuleDescriptor } from "../../kernel/host/module-host.js";
import { ProjectLifecycle } from "./project-lifecycle.js";
import { nativeChangeConfirmer } from "../../kernel/host/native-change.js";

export function projectsModule(owner: ProjectLifecycle): ModuleDescriptor<ProjectLifecycle> {
  return { name: "tron-projects", purpose: "Creates projects through exact native review and canonical mutation receipts; existing-project trust is the settings owner's.", tools: ["projects"], commands: [],
    start: () => ({ contract: owner, extension: session => pi => {
      pi.registerTool({ name: "projects", label: "Projects", annotations: { openWorldHint: false }, executionMode: "sequential",
        description: "Create a direct-child Workspace project: an untrusted folder with a Git repository on main, then trusted after the exact shared native tap. Existing paths are never overwritten. Only Home can change an existing project's trust with the settings tool (permissions.projectTrust); use git and gh directly for everything else. No automatic replay after uncertain effects: inspect the filesystem, Git and trust before another action.",
        promptSnippet: "Use projects to create a project; only Home can change project trust with the settings tool; never write trust files.",
        parameters: Type.Object({ name: Type.String({ minLength: 1, maxLength: 64 }), reason: Type.String({ minLength: 1, maxLength: 2000 }),
          }, { additionalProperties: false }),
        execute: async (toolCallId, raw, signal, _update, context) => {
          const confirm = nativeChangeConfirmer(context, session.requestChange, signal);
          const input = raw as { name: string; reason: string };
          const result = await owner.request({ name: input.name, reason: input.reason }, confirm ? { confirm } : {});
          return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
        },
      });
    } }),
  };
}
