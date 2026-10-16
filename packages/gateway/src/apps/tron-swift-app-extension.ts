import { Type } from "@earendil-works/pi-ai";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import { readSwiftAppSourceFile, type SwiftAppStore } from "./swift-app-store.js";

const parameters = Type.Object({
  action: Type.Union([Type.Literal("list"), Type.Literal("install"), Type.Literal("state"), Type.Literal("commit"), Type.Literal("remove")]),
  appId: Type.Optional(Type.String({ minLength: 1, maxLength: 63 })),
  name: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  icon: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  source: Type.Optional(Type.Object({
    kind: Type.Union([Type.Literal("path"), Type.Literal("internal_file")]),
    path: Type.String({ minLength: 1, maxLength: 4_096 }),
  }, { additionalProperties: false })),
  expectedRevision: Type.Optional(Type.Integer({ minimum: 0 })),
  set: Type.Optional(Type.Array(Type.Object({ key: Type.String(), value: Type.Unknown() }, { additionalProperties: false }), { maxItems: 256 })),
  remove: Type.Optional(Type.Array(Type.String(), { maxItems: 256 })),
}, { additionalProperties: false });

interface Parameters {
  action: "list" | "install" | "state" | "commit" | "remove";
  appId?: string;
  name?: string;
  icon?: string;
  source?: { kind: "path" | "internal_file"; path: string };
  expectedRevision?: number;
  set?: Array<{ key: string; value: JsonValue }>;
  remove?: string[];
}

function required<T>(value: T | undefined, field: string, action: string): T {
  if (value === undefined) throw new GatewayError("invalid_request", `swift_app ${action} requires ${field}`);
  return value;
}

/** The agent's interface to installed Swift apps; the store is the only writer. */
export function createTronSwiftAppExtension(input: {
  store: SwiftAppStore;
  cwd: () => string;
  internalFilesRoot: () => Promise<string>;
}): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "swift_app",
      annotations: { openWorldHint: false },
      label: "Swift app",
      description: "Manage the user's installed single-file SwiftUI apps (experimental). list shows installed apps. install copies a .swift file (source.kind=path relative to the session directory, or internal_file relative to the internal workspace files/) into an installed app with appId, name and optional SF Symbol icon; installing an existing appId replaces its source and keeps its data. state reads the app's stored key/value data and its revision. commit writes data: set [{key, value}] and remove [key] against expectedRevision (the revision state returned); a stale revision is refused. remove deletes the app and all its stored data permanently.",
      promptSnippet: "Use swift_app to install a single-file SwiftUI app the user wants to keep, or to read and seed its stored data.",
      promptGuidelines: [
        "Install only when the user wants to keep the app; displaying a .swift file is enough for a one-off preview.",
        "Read state before commit and pass its revision as expectedRevision. Never remove an app unless the user asked; removal deletes its data.",
      ],
      parameters,
      executionMode: "sequential",
      execute: async (_toolCallId, params: Parameters, signal) => {
        if (signal?.aborted) throw new Error("swift_app aborted");
        let details: unknown;
        let text: string;
        switch (params.action) {
          case "list": {
            const apps = await input.store.list();
            details = { apps };
            text = apps.length === 0 ? "No apps are installed." : JSON.stringify(details);
            break;
          }
          case "install": {
            const reference = required(params.source, "source", "install");
            const root = reference.kind === "path" ? input.cwd() : await input.internalFilesRoot();
            const source = await readSwiftAppSourceFile(root, reference.path);
            if (signal?.aborted) throw new Error("swift_app aborted");
            const result = await input.store.install({
              appId: required(params.appId, "appId", "install"),
              name: required(params.name, "name", "install"),
              ...(params.icon ? { icon: params.icon } : {}),
              source,
            });
            details = result;
            text = `${result.created ? "Installed" : "Updated"} ${result.app.name} (${result.app.id}) at source revision ${result.app.revision}${result.created ? "" : "; its data was kept"}.`;
            break;
          }
          case "state": {
            details = await input.store.state(required(params.appId, "appId", "state"));
            text = JSON.stringify(details);
            break;
          }
          case "commit": {
            const result = await input.store.commit({
              appId: required(params.appId, "appId", "commit"),
              expectedRevision: required(params.expectedRevision, "expectedRevision", "commit"),
              set: params.set ?? [],
              remove: params.remove ?? [],
            });
            details = result;
            text = `Committed ${result.appId} state at revision ${result.revision}.`;
            break;
          }
          case "remove": {
            const result = await input.store.remove(required(params.appId, "appId", "remove"));
            details = result;
            text = `Removed ${result.appId}: its source and all of its stored data were deleted.`;
            break;
          }
        }
        return { content: [{ type: "text", text }], details };
      },
    });
  };
}
