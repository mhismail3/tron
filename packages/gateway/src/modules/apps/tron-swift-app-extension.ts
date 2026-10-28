import { Type } from "../../kernel/pi/ai.js";
import { randomUUID } from "node:crypto";
import type { DisplayArtifactStore } from "../../display/display-artifact-store.js";
import { eligibleDisplaySurfaces } from "../../display/display-contract.js";
import { DISPLAY_SCHEMA, type DisplayProjection } from "../display/contract.js";
import { readSwiftDisplaySource } from "./swift-app-display.js";
import type { ExtensionFactory } from "../../kernel/pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import type { JsonValue } from "../../protocol/types.js";
import { readSwiftAppSourceFile, type SwiftAppStore } from "./swift-app-store.js";

const parameters = Type.Object({
  action: Type.Union([Type.Literal("list"), Type.Literal("install"), Type.Literal("offer"), Type.Literal("discardOffer"), Type.Literal("state"), Type.Literal("commit"), Type.Literal("remove")]),
  appId: Type.Optional(Type.String({ minLength: 1, maxLength: 63 })),
  name: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  icon: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
  source: Type.Optional(Type.Object({
    kind: Type.Union([Type.Literal("path"), Type.Literal("internal_file")]),
    path: Type.String({ minLength: 1, maxLength: 4_096 }),
  }, { additionalProperties: false })),
  feeds: Type.Optional(Type.Array(Type.String(), { maxItems: 1 })),
  artifactId: Type.Optional(Type.String({ minLength: 1, maxLength: 256 })),
  expectedInstanceId: Type.Optional(Type.String({ maxLength: 36 })),
  expectedRevision: Type.Optional(Type.Integer({ minimum: 0 })),
  set: Type.Optional(Type.Array(Type.Object({ key: Type.String(), value: Type.Unknown() }, { additionalProperties: false }), { maxItems: 256 })),
  remove: Type.Optional(Type.Array(Type.String(), { maxItems: 256 })),
}, { additionalProperties: false });

interface Parameters {
  action: "list" | "install" | "offer" | "discardOffer" | "state" | "commit" | "remove";
  appId?: string;
  name?: string;
  icon?: string;
  source?: { kind: "path" | "internal_file"; path: string };
  feeds?: string[];
  artifactId?: string;
  expectedInstanceId?: string;
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
  artifacts: DisplayArtifactStore;
  cwd: () => string;
  sessionId: () => string;
  internalFilesRoot: () => Promise<string>;
}): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "swift_app",
      annotations: { openWorldHint: false },
      label: "Swift app",
      description: "Prepare and manage single-file SwiftUI apps. offer snapshots source with appId/name/icon and explicit feeds (only ios-builds); the offer itself displays the exact source for iPhone Install App or Update App review. Offering never installs. discardOffer removes an unused offer by artifactId in its own producing session. v2 app removal requires expectedInstanceId from list. The install action below is the named v1-only contract; it never upgrades v1 or downgrades v2. Manage the user's installed single-file SwiftUI apps (experimental). list shows installed apps. install copies a .swift file (source.kind=path relative to the session directory, or internal_file relative to the internal workspace files/) into an installed app with appId, name and optional SF Symbol icon; installing an existing v1 appId replaces its source and keeps its data; an existing v2 app refuses this action and requires an offer/review update. state reads the app's stored key/value data and its revision. commit writes data: set [{key, value}] and remove [key] against expectedRevision (the revision state returned); a stale revision is refused. remove deletes the app and all its stored data permanently.",
      promptSnippet: "Use swift_app offer to display exact Swift source for the user to review and install. It declares read-only feeds without installing. The legacy install action writes v1 apps only. Read or seed installed data through state/commit.",
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
          case "offer": {
            const reference = required(params.source, "source", "offer");
            const root = reference.kind === "path" ? input.cwd() : await input.internalFilesRoot();
            const source = await readSwiftAppSourceFile(root, reference.path);
            if (signal?.aborted) throw new Error("swift_app aborted");
            const sessionId = input.sessionId();
            const artifact = await input.artifacts.ingest(root, reference.path, sessionId);
            try {
              const displayed = await readSwiftDisplaySource(await input.artifacts.acquire(artifact.id, sessionId));
              if (displayed !== source || artifact.kind !== "code") throw new Error("The source changed while preparing review; prepare the offer again");
              const result = await input.store.offer({ appId: required(params.appId, "appId", "offer"),
                name: required(params.name, "name", "offer"), ...(params.icon ? { icon: params.icon } : {}), source, feeds: required(params.feeds, "feeds", "offer"), reference: { sessionId, artifactId: artifact.id } },
              { kind: "session", id: sessionId });
              const display: DisplayProjection = { schema: DISPLAY_SCHEMA, displayId: randomUUID(), revision: 1,
                title: result.offer.name, caption: "Review to Install App", altText: `Review ${result.offer.name} before installing this Swift app`,
                kind: "code", presentation: { requestedSurface: "inline", inlineTapAction: "sheet" },
                eligibleSurfaces: eligibleDisplaySurfaces("code", artifact.size), fallbackText: "Review this app's source and declared access before installing.", artifact };
              details = { ...result, display };
              text = `Prepared ${result.offer.name} for explicit Install App review (${result.offer.id}). The exact source is displayed; the app is not installed yet.`;
            } catch (error) {
              await input.artifacts.revoke(artifact.id, sessionId);
              throw error;
            }
            break;
          }
          case "discardOffer": {
            await input.store.discardOffer({ sessionId: input.sessionId(), artifactId: required(params.artifactId, "artifactId", "discardOffer") });
            details = { discarded: true }; text = "Discarded the unused app offer; installed apps were not changed.";
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
            const result = await input.store.remove(required(params.appId, "appId", "remove"), params.expectedInstanceId);
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
