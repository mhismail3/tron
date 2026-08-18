import type { AuthType } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { GatewayConfig } from "../config.js";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import { PI_VERSION, GATEWAY_VERSION, MIN_PROTOCOL_VERSION, PROTOCOL_VERSION } from "../version.js";
import { arrayOfStrings, boolean, integer, object, oneOf, optionalString, string, text } from "../util/validation.js";
import type { DeviceStore } from "../security/device-store.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { FilesystemService } from "../machine/filesystem-service.js";
import type { UploadStore } from "../machine/upload-store.js";
import type { TerminalService } from "../machine/terminal-service.js";
import type { TrustService } from "../admin/trust-service.js";
import type { SettingsService } from "../admin/settings-service.js";
import type { ModelConfigService } from "../admin/model-config-service.js";
import type { PackageService } from "../admin/package-service.js";
import type { AuthBroker } from "../admin/auth-broker.js";
import type { LegacyImportService } from "../admin/legacy-import-service.js";
import type { GatewayLogger } from "./logger.js";
import type { CommandReceiptStore } from "./command-receipts.js";
import { fitSessionSnapshot, safeJson } from "../sessions/projection.js";
import { ModelCatalogPager } from "./model-pagination.js";
import { SessionListPaginationStore } from "./session-list-pagination.js";

const thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
const PROVIDER_CATALOG_MAX_ITEMS = 1_000;
const PROVIDER_CATALOG_MAX_STRING_BYTES = 4 * 1_048_576;
const PROVIDER_CATALOG_MAX_FIELD_CHARACTERS = 100_000;

const restartDrainMethods = new Set([
  "system.info", "system.logs", "command.status", "gateway.restart",
  "session.list", "session.open", "session.sync", "session.close", "session.transcript",
  "session.abort", "session.clearQueue", "session.queue.replace", "extension.respond", "extension.editor.update", "extension.toolsExpanded",
  "terminal.list", "terminal.attach", "terminal.detach", "terminal.terminate",
]);

export interface ClientContext {
  id: string;
  identity: string;
  isLocal: boolean;
  beginSynchronization(sessionId: string): string;
  establishSynchronization(sessionId: string, snapshot: import("../protocol/types.js").SessionSnapshot): void;
  completeSynchronization(sessionId: string, syncToken: string): void;
  unsubscribe(sessionId: string, subscriptionToken?: string): boolean;
  attachTerminal(terminalId: string): void;
  detachTerminal(terminalId: string): void;
  ownsTerminal(terminalId: string): boolean;
}

export interface GatewayServiceDependencies {
  config: GatewayConfig;
  modelRuntime: ModelRuntime;
  devices: DeviceStore;
  sessions: RuntimeRegistry;
  filesystem: FilesystemService;
  uploads: UploadStore;
  terminals: TerminalService;
  trust: TrustService;
  settings: SettingsService;
  modelConfig: ModelConfigService;
  packages: PackageService;
  auth: AuthBroker;
  legacyImport: LegacyImportService;
  logger: GatewayLogger;
  receipts: CommandReceiptStore;
  requestRestart: () => void;
  deviceRevoked: (deviceId: string) => void;
  broadcast: (topic: string, payload: JsonValue) => void;
}

export class GatewayService {
  private restartRequested = false;
  private readonly sessionListPages = new SessionListPaginationStore();
  private readonly modelCatalogPages = new ModelCatalogPager();

  constructor(private readonly dependencies: GatewayServiceDependencies) {}

  releaseClient(clientID: string): void {
    this.sessionListPages.releaseClient(clientID);
  }

  /**
   * Authoritative re-baseline for a subscriber whose synchronization
   * quarantine overflowed while its open handshake completed. A fresh fitted
   * snapshot converges the client without another full open handshake; clients
   * that cannot admit a re-baseline fall back to their ordinary resync path.
   */
  async recoverySnapshot(sessionId: string): Promise<import("../protocol/types.js").SessionSnapshot | undefined> {
    try {
      const slot = await this.dependencies.sessions.acquire(sessionId);
      return fitSessionSnapshot(slot.snapshot());
    } catch {
      return undefined;
    }
  }

  info(): JsonValue {
    const { config } = this.dependencies;
    return {
      gatewayVersion: GATEWAY_VERSION,
      piVersion: PI_VERSION,
      protocolVersion: PROTOCOL_VERSION,
      minProtocolVersion: MIN_PROTOCOL_VERSION,
      machineId: config.machineId,
      machineName: config.machineName,
      capabilities: [
        "sessions.v1",
        "auth.v1",
        "settings.v1",
        "packages.v1",
        "trust.v1",
        "filesystem.v1",
        "uploads.v1",
        "terminal.v1",
        "extension-presentation.v1",
        "queue-management.v1",
        "restart-drain.v1",
      ],
    };
  }

  async invoke(client: ClientContext, method: string, rawParams: unknown): Promise<JsonValue> {
    const params = object(rawParams ?? {}, "params");
    if (this.restartRequested && !restartDrainMethods.has(method)) {
      throw new GatewayError("busy", "The Gateway is draining accepted work before restart", true);
    }
    switch (method) {
      case "system.info":
        return this.info();
      case "system.logs":
        return safeJson({ records: this.dependencies.logger.recent(integer(params.limit ?? 200, "limit", 1, 1_000)) });
      case "command.status":
        return safeJson(await this.dependencies.receipts.status(
          client.identity,
          string(params.method, "method", { max: 160 }),
          string(params.commandId, "commandId", { min: 8, max: 160 }),
        ));
      case "device.list":
        return safeJson({ devices: await this.dependencies.devices.listDevices() });
      case "device.revoke":
        return this.mutation(client, method, params, async () => {
          const deviceId = string(params.deviceId, "deviceId", { max: 100 });
          const revoked = await this.dependencies.devices.revoke(deviceId);
          if (revoked) this.dependencies.deviceRevoked(deviceId);
          return { revoked };
        });
      case "gateway.restart":
        return this.mutation(client, method, params, async () => {
          const terminalIds = this.dependencies.terminals.activeTerminalIds();
          if (terminalIds.length > 0) {
            throw new GatewayError("busy", "Close active terminal sessions before restarting the Gateway", true);
          }
          const activeSessionIds = this.dependencies.sessions.activeSessionIds();
          if (!this.restartRequested) {
            this.restartRequested = true;
            setTimeout(this.dependencies.requestRestart, 100).unref();
          }
          return {
            restarting: activeSessionIds.length === 0,
            scheduled: activeSessionIds.length > 0,
            activeSessionIds,
          };
        });
      case "legacy.inspect":
        return safeJson(await this.dependencies.legacyImport.inspect());
      case "legacy.import":
        return this.mutation(client, method, params, async () => safeJson(await this.dependencies.legacyImport.import(
          params.port === undefined ? 9849 : integer(params.port, "port", 1, 65_535),
        )));

      case "session.list": {
        const scope = params.scope === undefined ? "user" : oneOf(params.scope, "scope", ["user", "all"] as const);
        const cursor = optionalString(params.cursor, "cursor", 96);
        const limit = params.limit === undefined ? 100 : integer(params.limit, "limit", 1, 500);
        if (cursor !== undefined) {
          return safeJson(this.sessionListPages.nextPage(client.id, scope, cursor, limit));
        }
        const catalog = await this.dependencies.sessions.catalog(scope);
        return safeJson(this.sessionListPages.firstPage(client.id, scope, catalog, limit));
      }
      case "session.create": {
        const created = await this.mutation(client, method, params, async () => {
          const slot = await this.dependencies.sessions.create(string(params.cwd, "cwd", { max: 4_096 }));
          return safeJson({ sessionId: slot.id });
        }) as { sessionId: string };
        return safeJson(created);
      }
      case "session.import": {
        const imported = await this.mutation(client, method, params, async () => {
          const uploadId = string(params.uploadId, "uploadId", { max: 100 });
          const path = await this.dependencies.uploads.prepareSessionImport(uploadId);
          const slot = await this.dependencies.sessions.importFromJsonl(path, string(params.cwd, "cwd", { max: 4_096 }));
          await this.dependencies.uploads.remove(uploadId).catch(() => {});
          return safeJson({ sessionId: slot.id });
        }) as { sessionId: string };
        return safeJson(imported);
      }
      case "session.open": {
        const sessionId = string(params.sessionId, "sessionId", { max: 200 });
        const slot = await this.dependencies.sessions.acquire(sessionId);
        const syncToken = client.beginSynchronization(sessionId);
        const snapshot = slot.snapshot();
        client.establishSynchronization(sessionId, snapshot);
        return safeJson({ session: snapshot, syncToken, subscriptionToken: syncToken });
      }
      case "session.sync": {
        const sessionId = string(params.sessionId, "sessionId", { max: 200 });
        client.completeSynchronization(sessionId, string(params.syncToken, "syncToken", { max: 200 }));
        return { synchronized: true };
      }
      case "session.transcript": {
        const sessionId = string(params.sessionId, "sessionId", { max: 200 });
        const before = params.before === undefined
          ? undefined
          : integer(params.before, "before", 0, Number.MAX_SAFE_INTEGER);
        const expectedNextEntryId = optionalString(params.expectedNextEntryId, "expectedNextEntryId", 200);
        const slot = await this.openedSlot(client, params);
        // Paging is a bounded read for an already-open presentation. It must
        // never create or revive event-subscription ownership after a close.
        return safeJson(slot.transcriptPage(before, expectedNextEntryId));
      }
      case "session.close": {
        const sessionId = string(params.sessionId, "sessionId", { max: 200 });
        const subscriptionToken = string(params.subscriptionToken, "subscriptionToken", { max: 200 });
        return { closed: client.unsubscribe(sessionId, subscriptionToken) };
      }
      case "session.delete":
        return this.mutation(client, method, params, async () => {
          const sessionId = string(params.sessionId, "sessionId", { max: 200 });
          client.unsubscribe(sessionId);
          await this.dependencies.sessions.delete(sessionId);
          await this.dependencies.uploads.removeSession(sessionId).catch(() => {});
          return { deleted: true };
        });
      case "session.prompt":
        return this.mutation(client, method, params, async () => {
          const slot = await this.openedSlot(client, params);
          const text = typeof params.text === "string" ? params.text.trim() : "";
          const uploadIds = params.uploadIds === undefined ? [] : arrayOfStrings(params.uploadIds, "uploadIds", 10);
          if (!text && uploadIds.length === 0) throw new GatewayError("invalid_request", "Prompt text or attachments are required");
          const attachments = await this.dependencies.uploads.materialize(uploadIds, slot.id);
          const prompt = [text, attachments.envelope].filter(Boolean).join("\n\n");
          const behavior = params.behavior === undefined ? undefined : oneOf(params.behavior, "behavior", ["steer", "followUp"] as const);
          return safeJson(await slot.prompt(prompt, attachments.images, behavior, {
            text,
            attachmentEnvelope: attachments.envelope,
            attachmentCount: uploadIds.length,
          }));
        });
      case "session.abort":
        return this.mutation(client, method, params, async () => {
          await (await this.openedSlot(client, params)).abort(
            params.kind === undefined
              ? "agent"
              : oneOf(params.kind, "kind", ["agent", "compaction", "retry", "branchSummary", "bash"] as const),
          );
          return { aborted: true };
        });
      case "session.clearQueue":
        return this.mutation(client, method, params, async () => safeJson(await (await this.openedSlot(client, params)).clearQueue()));
      case "session.queue.replace":
        return this.mutation(client, method, params, async () => {
          if (!Array.isArray(params.items)) throw new GatewayError("invalid_request", "items must be an array");
          const items = params.items.map((value, index) => {
            const item = object(value, `items[${index}]`);
            return {
              id: string(item.id, `items[${index}].id`, { max: 100 }),
              behavior: oneOf(item.behavior, `items[${index}].behavior`, ["steer", "followUp"] as const),
              text: string(item.text, `items[${index}].text`, { max: 64 * 1_024 }),
            };
          });
          return safeJson(await (await this.openedSlot(client, params)).replaceQueue(
            integer(params.expectedRevision, "expectedRevision", 0, Number.MAX_SAFE_INTEGER),
            items,
          ));
        });
      case "session.bash":
        return this.mutation(client, method, params, async () => (await this.openedSlot(client, params)).executeBash(
          string(params.command, "command", { max: 100_000 }),
          params.excludeFromContext === undefined ? false : boolean(params.excludeFromContext, "excludeFromContext"),
        ));
      case "session.setModel":
        return this.mutation(client, method, params, async () => {
          await (await this.openedSlot(client, params)).setModel(string(params.provider, "provider", { max: 120 }), string(params.modelId, "modelId", { max: 300 }));
          return { updated: true };
        });
      case "session.setThinking":
        return this.mutation(client, method, params, async () => {
          await (await this.openedSlot(client, params)).setThinking(oneOf(params.level, "level", thinkingLevels));
          return { updated: true };
        });
      case "session.setTools":
        return this.mutation(client, method, params, async () => {
          await (await this.openedSlot(client, params)).setTools(arrayOfStrings(params.tools, "tools", 256));
          return { updated: true };
        });
      case "session.compact":
        return this.mutation(client, method, params, async () => {
          const result = await (await this.openedSlot(client, params)).compact(optionalString(params.instructions, "instructions", 20_000));
          return { compacted: true, queued: result.queued };
        });
      case "session.rename":
        return this.mutation(client, method, params, async () => {
          await (await this.slot(params)).rename(string(params.name, "name", { max: 200 }));
          return { updated: true };
        });
      case "session.fork":
        return this.mutation(client, method, params, async () => safeJson(await (await this.openedSlot(client, params)).fork(
          string(params.entryId, "entryId", { max: 200 }),
          params.position === undefined ? "at" : oneOf(params.position, "position", ["before", "at"] as const),
        )));
      case "session.navigate":
        return this.mutation(client, method, params, async () => safeJson(await (await this.openedSlot(client, params)).navigate(
          string(params.entryId, "entryId", { max: 200 }),
          {
            summarize: params.summarize === undefined ? false : boolean(params.summarize, "summarize"),
            ...(params.instructions === undefined ? {} : { instructions: string(params.instructions, "instructions", { max: 20_000 }) }),
            ...(params.replaceInstructions === undefined ? {} : { replaceInstructions: boolean(params.replaceInstructions, "replaceInstructions") }),
            ...(params.label === undefined ? {} : { label: string(params.label, "label", { max: 200 }) }),
          },
        )));
      case "session.label":
        return this.mutation(client, method, params, async () => {
          await (await this.openedSlot(client, params)).setLabel(
            string(params.entryId, "entryId", { max: 200 }),
            optionalString(params.label, "label", 200),
          );
          return { updated: true };
        });
      case "session.tree": {
        const slot = await this.openedSlot(client, params);
        return safeJson(slot.tree());
      }
      case "session.commands": {
        const slot = await this.openedSlot(client, params);
        return safeJson({ commands: slot.commands() });
      }
      case "session.export": {
        const slot = await this.openedSlot(client, params);
        return safeJson(await slot.export(oneOf(params.format, "format", ["html", "jsonl"] as const)));
      }
      case "session.context":
        return (await this.openedSlot(client, params)).context();
      case "session.resources":
        return (await this.openedSlot(client, params)).resources();
      case "session.reloadResources":
        return this.mutation(client, method, params, async () => {
          await (await this.openedSlot(client, params)).reload();
          return { reloaded: true };
        });
      case "extension.respond":
        return this.mutation(client, method, params, async () => {
          (await this.openedSlot(client, params)).respondToInteraction(
            string(params.interactionId, "interactionId", { max: 100 }),
            string(params.hostEpoch, "hostEpoch", { max: 100 }),
            integer(params.presentationRevision, "presentationRevision", 0, Number.MAX_SAFE_INTEGER),
            params.value,
            params.cancelled === undefined ? false : boolean(params.cancelled, "cancelled"),
          );
          return { answered: true };
        });
      case "extension.editor.update":
        return this.mutation(client, method, params, async () => (await this.openedSlot(client, params)).updateExtensionEditor(
          string(params.hostEpoch, "hostEpoch", { max: 100 }),
          integer(params.baseRevision, "baseRevision", 0, Number.MAX_SAFE_INTEGER),
          string(params.operationId, "operationId", { max: 256 }),
          text(params.text, "text", 192 * 1_024),
        ));
      case "extension.toolsExpanded":
        return this.mutation(client, method, params, async () => (await this.openedSlot(client, params)).setExtensionToolsExpanded(
          string(params.hostEpoch, "hostEpoch", { max: 100 }),
          integer(params.presentationRevision, "presentationRevision", 0, Number.MAX_SAFE_INTEGER),
          boolean(params.expanded, "expanded"),
        ));

      case "provider.list":
        return this.providers(await this.modelRuntime(params));
      case "model.list":
        return this.models(await this.modelRuntime(params), params.cursor, params.limit);
      case "auth.begin": {
        const operationId = this.dependencies.auth.start(
          client.id,
          string(params.providerId, "providerId", { max: 120 }),
          oneOf(params.authType, "authType", ["api_key", "oauth"] as const) as AuthType,
          await this.modelRuntime(params),
        );
        return { operationId };
      }
      case "auth.respond":
        this.dependencies.auth.respond(client.id, string(params.operationId, "operationId", { max: 100 }), string(params.promptId, "promptId", { max: 100 }), typeof params.value === "string" ? params.value : "");
        return { answered: true };
      case "auth.cancel":
        this.dependencies.auth.cancel(client.id, string(params.operationId, "operationId", { max: 100 }));
        return { cancelled: true };
      case "auth.logout":
        return this.mutation(client, method, params, async () => {
          await (await this.modelRuntime(params)).logout(string(params.providerId, "providerId", { max: 120 }));
          this.dependencies.broadcast("providers.changed", {});
          return { loggedOut: true };
        });

      case "settings.get": {
        const cwd = optionalString(params.cwd, "cwd", 4_096) ?? process.cwd();
        const scope = params.scope === undefined ? "project" : oneOf(params.scope, "scope", ["global", "project"] as const);
        if (scope === "global") return safeJson(this.dependencies.settings.get(cwd, false));
        const inspection = await this.dependencies.trust.inspect(cwd);
        return safeJson(this.dependencies.settings.get(inspection.cwd, inspection.effectiveDecision === true));
      }
      case "settings.update":
        return this.mutation(client, method, params, async () => {
          const scope = params.scope === undefined ? "global" : oneOf(params.scope, "scope", ["global", "project"] as const);
          const cwdInput = optionalString(params.cwd, "cwd", 4_096) ?? process.cwd();
          const resolved = scope === "project"
            ? await this.dependencies.trust.requireResolved(cwdInput)
            : { cwd: await this.dependencies.trust.canonicalDirectory(cwdInput), trusted: false };
          const result = await this.dependencies.settings.update(params.patch, {
            cwd: resolved.cwd,
            scope,
            projectTrusted: scope === "project" && resolved.trusted,
          });
          this.dependencies.broadcast("settings.changed", { scope, cwd: resolved.cwd });
          return safeJson(result);
        });
      case "trust.inspect":
        return safeJson(await this.dependencies.trust.inspect(string(params.cwd, "cwd", { max: 4_096 })));
      case "trust.set":
        return this.mutation(client, method, params, async () => {
          const decision = params.decision === null ? null : boolean(params.decision, "decision");
          const result = await this.dependencies.trust.setAndApply(
            string(params.cwd, "cwd", { max: 4_096 }),
            decision,
            async (inspection) => this.dependencies.sessions.reloadProject(
              inspection.cwd,
              inspection.effectiveDecision === true,
              false,
            ),
            async (inspection) => this.dependencies.sessions.commitProjectReload(inspection.cwd),
          );
          this.dependencies.broadcast("trust.changed", safeJson(result));
          return safeJson(result);
        });
      case "packages.list":
        return safeJson(await this.dependencies.packages.list(optionalString(params.cwd, "cwd", 4_096) ?? process.cwd()));
      case "packages.checkUpdates":
        return safeJson(await this.dependencies.packages.checkUpdates(optionalString(params.cwd, "cwd", 4_096) ?? process.cwd()));
      case "packages.install":
      case "packages.remove":
      case "packages.update":
        return this.mutation(client, method, params, async () => {
          const cwd = optionalString(params.cwd, "cwd", 4_096) ?? process.cwd();
          const result = await this.dependencies.packages.mutate(
            method.slice("packages.".length) as "install" | "remove" | "update",
            method === "packages.update" ? optionalString(params.source, "source", 2_000) : string(params.source, "source", { max: 2_000 }),
            cwd,
            params.local === undefined ? false : boolean(params.local, "local"),
          );
          this.dependencies.broadcast("packages.changed", { cwd });
          return safeJson(result);
        });
      case "models.custom.get":
        return safeJson(await this.dependencies.modelConfig.get());
      case "models.custom.validate":
        return safeJson(await this.dependencies.modelConfig.validate(params.document));
      case "models.custom.put":
        return this.mutation(client, method, params, async () => {
          const result = await this.dependencies.modelConfig.put(params.document);
          this.dependencies.broadcast("models.customChanged", {});
          return safeJson(result);
        });
      case "models.refresh":
        return this.mutation(client, method, params, async () => {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 60_000);
          timer.unref();
          try {
            const result = await (await this.modelRuntime(params)).refresh({
              allowNetwork: true,
              force: params.force === undefined ? false : boolean(params.force, "force"),
              signal: controller.signal,
            });
            return safeJson({ aborted: result.aborted, errors: Object.fromEntries([...result.errors].map(([key, error]) => [key, error.message])) });
          } finally {
            clearTimeout(timer);
          }
        });

      case "filesystem.home":
        return { path: this.dependencies.filesystem.root };
      case "filesystem.list":
        return safeJson(await this.dependencies.filesystem.list(optionalString(params.path, "path", 4_096)));
      case "filesystem.mkdir":
        return this.mutation(client, method, params, async () => ({ path: await this.dependencies.filesystem.createDirectory(string(params.parent, "parent", { max: 4_096 }), string(params.name, "name", { max: 120 })) }));
      case "git.inspect":
        return safeJson(await this.dependencies.filesystem.inspectGit(string(params.path, "path", { max: 4_096 })));

      case "terminal.list": {
        const slot = await this.openedSlot(client, params);
        return safeJson({ terminals: this.dependencies.terminals.list(slot.id) });
      }
      case "terminal.open":
        return this.mutation(client, method, params, async () => {
          const slot = await this.openedSlot(client, params);
          const terminal = this.dependencies.terminals.open(
            slot.id,
            slot.cwd,
            params.columns === undefined ? 100 : integer(params.columns, "columns", 20, 500),
            params.rows === undefined ? 30 : integer(params.rows, "rows", 5, 300),
            slot.sessionEnvironment(),
          );
          client.attachTerminal(terminal.id);
          return safeJson({ terminal, replay: this.dependencies.terminals.attach(terminal.id, 0) });
        });
      case "terminal.attach": {
        const terminalId = string(params.terminalId, "terminalId", { max: 100 });
        const replay = this.dependencies.terminals.attach(terminalId, params.afterSequence === undefined ? 0 : integer(params.afterSequence, "afterSequence", 0, Number.MAX_SAFE_INTEGER));
        client.attachTerminal(terminalId);
        return safeJson(replay);
      }
      case "terminal.detach": {
        const terminalId = string(params.terminalId, "terminalId", { max: 100 });
        client.detachTerminal(terminalId);
        return { detached: true };
      }
      case "terminal.write":
        return this.mutation(client, method, params, async () => {
          const terminalId = string(params.terminalId, "terminalId", { max: 100 });
          this.requireOwnedTerminal(client, terminalId);
          this.dependencies.terminals.write(
            terminalId,
            string(params.writeId, "writeId", { max: 100 }),
            typeof params.data === "string" && params.data.length <= 65_536 ? params.data : (() => { throw new GatewayError("invalid_request", "Terminal data is too large"); })(),
          );
          return { written: true };
        });
      case "terminal.resize":
        return this.mutation(client, method, params, async () => {
          const terminalId = string(params.terminalId, "terminalId", { max: 100 });
          this.requireOwnedTerminal(client, terminalId);
          this.dependencies.terminals.resize(terminalId, integer(params.columns, "columns", 20, 500), integer(params.rows, "rows", 5, 300));
          return { resized: true };
        });
      case "terminal.terminate":
        return this.mutation(client, method, params, async () => {
          const terminalId = string(params.terminalId, "terminalId", { max: 100 });
          this.requireOwnedTerminal(client, terminalId);
          await this.dependencies.terminals.terminate(terminalId);
          return { terminated: true };
        });
      default:
        throw new GatewayError("not_found", `Unknown gateway method: ${method}`);
    }
  }

  terminalBelongsToSession(terminalId: string, sessionId: string): boolean {
    return this.dependencies.terminals.belongsToSession(terminalId, sessionId);
  }

  private requireOwnedTerminal(client: ClientContext, terminalId: string): void {
    if (!client.ownsTerminal(terminalId)) {
      throw new GatewayError("invalid_request", "Attach the terminal before controlling it");
    }
  }

  private async openedSlot(client: ClientContext, params: Record<string, unknown>) {
    const sessionId = string(params.sessionId, "sessionId", { max: 200 });
    if (!this.dependencies.sessions.isSubscribed(client.id, sessionId)) {
      throw new GatewayError("invalid_request", "Open the session before reading its live runtime projection");
    }
    return this.dependencies.sessions.acquire(sessionId);
  }

  private async slot(params: Record<string, unknown>) {
    return this.dependencies.sessions.acquire(string(params.sessionId, "sessionId", { max: 200 }));
  }

  private async mutation(
    client: ClientContext,
    method: string,
    params: Record<string, unknown>,
    operation: () => Promise<JsonValue>,
  ): Promise<JsonValue> {
    const commandId = string(params.commandId, "commandId", { min: 8, max: 160 });
    return this.dependencies.receipts.execute(client.identity, method, commandId, operation);
  }

  private async modelRuntime(params: Record<string, unknown>): Promise<ModelRuntime> {
    if (params.sessionId === undefined) return this.dependencies.modelRuntime;
    return (await this.dependencies.sessions.acquire(string(params.sessionId, "sessionId", { max: 200 }))).modelRuntime;
  }

  private async providers(modelRuntime: ModelRuntime): Promise<JsonValue> {
    const credentials = new Map((await modelRuntime.listCredentials()).map((credential) => [credential.providerId, credential.type]));
    const providers = await Promise.all(modelRuntime.getProviders().map(async (provider) => {
      const auth = await modelRuntime.checkAuth(provider.id).catch(() => undefined);
      return {
        id: provider.id,
        name: provider.name,
        configured: auth !== undefined,
        authSource: auth?.source ?? null,
        credentialType: credentials.get(provider.id) ?? null,
        authMethods: [provider.auth.apiKey?.login ? "api_key" : null, provider.auth.oauth ? "oauth" : null]
          .filter((value): value is string => value !== null),
        modelCount: provider.getModels().length,
      };
    }));
    validateProviderCatalog(providers);
    return safeJson({ providers });
  }

  private async models(modelRuntime: ModelRuntime, cursor: unknown, limit: unknown): Promise<JsonValue> {
    const page = await this.modelCatalogPages.page(modelRuntime, cursor, limit, async () => {
      const available = new Set((await modelRuntime.getAvailable()).map((model) => `${model.provider}\0${model.id}`));
      return modelRuntime.getModels().map((model) => ({
        provider: model.provider,
        id: model.id,
        name: model.name,
        reasoning: model.reasoning,
        input: model.input,
        contextWindow: model.contextWindow,
        maxTokens: model.maxTokens,
        available: available.has(`${model.provider}\0${model.id}`),
      }));
    });
    return safeJson({ models: page.items, ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}) });
  }
}

export function validateProviderCatalog(providers: Array<{
  id: string;
  name: string;
  authSource: string | null;
  credentialType: string | null;
  authMethods: string[];
}>): void {
  if (providers.length > PROVIDER_CATALOG_MAX_ITEMS) {
    throw new GatewayError("conflict", "Provider catalog exceeds the item limit");
  }
  const identities = new Set<string>();
  let stringBytes = 0;
  for (const provider of providers) {
    if (identities.has(provider.id)) {
      throw new GatewayError("conflict", "Provider catalog contains duplicate IDs");
    }
    identities.add(provider.id);
    const values = [provider.id, provider.name, ...provider.authMethods];
    if (provider.authSource) values.push(provider.authSource);
    if (provider.credentialType) values.push(provider.credentialType);
    for (const value of values) {
      const bytes = Buffer.byteLength(value);
      if (value.length > PROVIDER_CATALOG_MAX_FIELD_CHARACTERS
        || bytes > PROVIDER_CATALOG_MAX_STRING_BYTES - stringBytes) {
        throw new GatewayError("conflict", "Provider catalog exceeds the string limit");
      }
      stringBytes += bytes;
    }
  }
}
