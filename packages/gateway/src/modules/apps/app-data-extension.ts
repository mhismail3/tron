import { Type } from "../../kernel/pi/ai.js";
import type { ExtensionFactory } from "../../kernel/pi/coding-agent.js";
import type { JsonValue } from "../../protocol/types.js";
import { integer, string } from "../../util/validation.js";
import type { AppsFolderStore } from "./apps-folder-store.js";

const parameters = Type.Object({
  action: Type.Union([Type.Literal("list"), Type.Literal("state"), Type.Literal("commit"), Type.Literal("clear")]),
  id: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  cursor: Type.Optional(Type.String({ minLength: 1, maxLength: 512 })),
  expectedRevision: Type.Optional(Type.Integer({ minimum: 0 })),
  confirmed: Type.Optional(Type.Boolean()),
  set: Type.Optional(Type.Array(Type.Object({ key: Type.String(), value: Type.Unknown() }, { additionalProperties: false }), { maxItems: 256 })),
  remove: Type.Optional(Type.Array(Type.String(), { maxItems: 256 })),
}, { additionalProperties: false });

interface Parameters {
  action: "list" | "state" | "commit" | "clear"; id?: string; cursor?: string;
  expectedRevision?: number; confirmed?: boolean;
  set?: Array<{ key: string; value: JsonValue }>; remove?: string[];
}

/** Saved-data management, never membership or executable access admission. */
export function createAppDataExtension(store: AppsFolderStore): ExtensionFactory {
  return pi => pi.registerTool({
    name: "app_data", label: "App saved data", annotations: { openWorldHint: false },
    description: "Read or manage folder apps' saved values on the Mac only for user-requested data management; this is not an app-runtime bridge. list returns at most 50 saved-data ids with byte counts and orphan flags; use its nextCursor for the next page. Cursors bind saved-data id membership and refuse on inventory changes; byte counts and orphan flags are live observations. State never creates an Apps entry. state reads one id and its revision; commit seeds values with set [{key,value}] and remove [key] against expectedRevision. clear erases only that id's values against expectedRevision and requires confirmed=true after separate explicit user authorization. It does not delete app files or grant runtime access. Orphan saved data is retained until explicitly cleared. Never edit state/apps or state/app-permissions directly.",
    promptSnippet: "Manage app saved data through app_data, separate from files/apps membership and first-open access grants.",
    promptGuidelines: [
      "Read state before committing and pass its expectedRevision. A stale revision refuses rather than overwriting newer values.",
      "Ask separately before clearing saved data. Set confirmed=true only after the user authorizes clearing that exact id; deleting app files is not authorization to clear its data.",
    ],
    parameters, executionMode: "sequential",
    execute: async (_callId, params: Parameters, signal) => {
      signal?.throwIfAborted();
      let details: unknown;
      if (params.action === "list") details = await store.listData(params.cursor);
      else {
        const id = string(params.id, "id", { max: 80 });
        if (params.action === "state") details = await store.managedState(id);
        else {
          const revision = integer(params.expectedRevision, "expectedRevision", 0, Number.MAX_SAFE_INTEGER);
          if (params.action === "clear") details = await store.clearData(id, revision, params.confirmed);
          else details = await store.seedData({ appId: id, expectedRevision: revision, set: params.set ?? [], remove: params.remove ?? [] });
        }
      }
      return { content: [{ type: "text", text: JSON.stringify(details) }], details };
    },
  });
}
