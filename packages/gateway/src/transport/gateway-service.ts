import { performance } from "node:perf_hooks";
import type { AuthType } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { GatewayConfig } from "../config.js";
import { GatewayError } from "../errors.js";
import { runtimeIdentity } from "./runtime-identity.js";
import type { JsonValue } from "../protocol/types.js";
import { PI_VERSION, GATEWAY_VERSION, MIN_PROTOCOL_VERSION, PROTOCOL_VERSION } from "../version.js";
import { arrayOfStrings, boolean, integer, object, oneOf, optionalString, string, text as boundedText } from "../util/validation.js";
import type { DeviceStore } from "../security/device-store.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { EXTENSION_ACTIVITY_HISTORY_CAPABILITY } from "../sessions/extension-activity-history.js";
import { PROCESS_ACTIVITY_CAPABILITY, PROCESS_ACTIVITY_HISTORY_CAPABILITY, PROCESS_TRANSCRIPT_CAPABILITY } from "../sessions/process-activity.js";
import { ProcessTranscriptLeaseStore } from "./process-transcript-leases.js";
import type { FilesystemService } from "../machine/filesystem-service.js";
import { GitWorktreeService, type SessionSourceControlRequest } from "../machine/git-worktree-service.js";
import type { UploadStore } from "../machine/upload-store.js";
import type { TerminalService } from "../machine/terminal-service.js";
import type { TrustService } from "../admin/trust-service.js";
import type { SettingsService } from "../admin/settings-service.js";
import type { ModelConfigService } from "../admin/model-config-service.js";
import type { PackageService } from "../admin/package-service.js";
import type { AuthBroker } from "../admin/auth-broker.js";
import type { LegacyImportService } from "../admin/legacy-import-service.js";
import { GatewayUpdateService, validateGatewayUpdateRequest } from "../admin/gateway-update-service.js";
import type { GatewayLogger } from "./logger.js";
import type { CommandReceiptStore } from "./command-receipts.js";
import { fitSessionSnapshot, safeJson } from "../sessions/projection.js";
import { ModelCatalogPager } from "./model-pagination.js";
import { SessionListPaginationStore } from "./session-list-pagination.js";
import type { NotificationService } from "../notifications/notification-service.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { admitPromptText, admitResourceInvocation, canonicalResourceName } from "../sessions/resource-invocation.js";

const thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
const PROVIDER_CATALOG_MAX_ITEMS = 1_000;
const PROVIDER_CATALOG_MAX_STRING_BYTES = 4 * 1_048_576;
const PROVIDER_CATALOG_MAX_FIELD_CHARACTERS = 100_000;

interface MobileIdentityLane {
  mutex: AsyncMutex;
  users: number;
}

function parseSessionSourceControl(value: unknown): SessionSourceControlRequest | undefined {
  if (value === undefined || value === null) return undefined;
  const source = object(value, "sourceControl");
  const mode = oneOf(source.mode, "sourceControl.mode", [
    "existingCheckout",
    "newBranchWorktree",
    "existingBranchWorktree",
  ] as const);
  const keys = new Set(Object.keys(source));
  const requireKeys = (allowed: readonly string[]) => {
    if ([...keys].some((key) => !allowed.includes(key))) {
      throw new GatewayError("invalid_request", "sourceControl contains unknown fields");
    }
  };
  if (mode === "existingCheckout") {
    requireKeys(["mode"]);
    return { mode };
  }
  const branch = string(source.branch, "sourceControl.branch", { max: 255 });
  if (mode === "newBranchWorktree") {
    requireKeys(["mode", "branch", "base"]);
    if (source.base === null) throw new GatewayError("invalid_request", "sourceControl.base must be omitted or a string");
    const base = optionalString(source.base, "sourceControl.base", 255);
    return base === undefined ? { mode, branch } : { mode, branch, base };
  }
  requireKeys(["mode", "branch"]);
  return { mode, branch };
}

const restartDrainMethods = new Set([
  "system.info", "system.logs", "command.status", "push.registration.status", "gateway.update.config.status", "gateway.update.status", "gateway.restart", "gateway.drain.status",
  "session.list", "session.open", "session.sync", "session.close", "session.transcript", "session.attention.read",
  "session.abort", "session.clearQueue", "session.queue.replace", "session.extensionActivity.list", "session.extensionActivity.get", "session.processHistory.list", "session.processHistory.get", "session.processTranscript.open", "session.processTranscript.page", "session.processTranscript.close", "extension.respond", "extension.editor.update", "extension.toolsExpanded", "auth.respond", "auth.callback", "auth.resume", "auth.cancel",
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
  /** Direct connection-local event delivery for opaque read-only leases. */
  sendEvent?(topic: string, sessionId: string, payload: JsonValue): void;
}

export interface GatewayServiceDependencies {
  config: GatewayConfig;
  modelRuntime: ModelRuntime;
  devices: DeviceStore;
  sessions: RuntimeRegistry;
  filesystem: FilesystemService;
  gitWorktrees?: GitWorktreeService;
  uploads: UploadStore;
  terminals: TerminalService;
  trust: TrustService;
  settings: SettingsService;
  modelConfig: ModelConfigService;
  packages: PackageService;
  auth: AuthBroker;
  legacyImport: LegacyImportService;
  /** Configured only by the LaunchAgent-owned update helper; never from RPC params. */
  updateService?: GatewayUpdateService;
  logger: GatewayLogger;
  receipts: CommandReceiptStore;
  requestRestart: () => void;
  deviceRevoked: (deviceId: string) => void;
  sessionDeleted: (sessionId: string) => void;
  broadcast: (topic: string, payload: JsonValue) => void;
  notifications?: NotificationService;
  workRegistry?: GatewayWorkRegistry;
}

export class GatewayService {
  private restartRequested = false;
  private restartScheduled = false;
  private readonly gitWorktrees: GitWorktreeService;
  private readonly sessionListPages = new SessionListPaginationStore();
  private readonly modelCatalogPages = new ModelCatalogPager();
  private readonly updateService: GatewayUpdateService;
  private readonly workRegistry: GatewayWorkRegistry | undefined;
  private readonly mobileIdentityLanes = new Map<string, MobileIdentityLane>();
  private readonly processTranscriptLeases: ProcessTranscriptLeaseStore;

  constructor(private readonly dependencies: GatewayServiceDependencies) {
    this.updateService = dependencies.updateService ?? new GatewayUpdateService({
      tronHome: dependencies.config?.tronHome ?? process.cwd(),
      runtimeIdentity: runtimeIdentity(),
    });
    this.gitWorktrees = dependencies.gitWorktrees ?? new GitWorktreeService(
      dependencies.config?.tronHome ?? process.env.TRON_HOME ?? process.cwd(),
    );
    this.workRegistry = dependencies.workRegistry ?? dependencies.sessions?.administrativeWorkRegistry;
    this.processTranscriptLeases = new ProcessTranscriptLeaseStore(dependencies.sessions);
  }

  releaseClient(clientID: string): void {
    this.sessionListPages.releaseClient(clientID);
    this.processTranscriptLeases.releaseClient(clientID);
  }

  releaseSessionProcessTranscripts(sessionID: string): void {
    this.processTranscriptLeases.releaseSession(sessionID);
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
      machineGroupID: config.machineGroupID,
      machineName: config.machineName,
      gatewayChannel: this.updateService.channel,
      ...runtimeIdentity(),
      capabilities: [
        ...(process.env.TRON_GATEWAY_SUPERVISED === "1" ? ["restart-supervised.v1"] : []),
        "sessions.v1",
        "auth.v1",
        "settings.v1",
        "packages.v1",
        "trust.v1",
        "filesystem.v1",
        "source-control.v1",
        "uploads.v1",
        "uploads-status.v2",
        "terminal.v1",
        "extension-presentation.v1",
        EXTENSION_ACTIVITY_HISTORY_CAPABILITY,
        PROCESS_ACTIVITY_CAPABILITY,
        PROCESS_ACTIVITY_HISTORY_CAPABILITY,
        PROCESS_TRANSCRIPT_CAPABILITY,
        "queue-management.v1",
        "skill-prompt.v1",
        "restart-drain.v1",
        "drain-status.v1",
        ...(this.updateService.isUsable ? ["gateway-update.v1"] : []),
        ...(this.dependencies.notifications ? ["push-notifications.v1", "notification-inbox.v1"] : []),
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
      case "uploads.status":
        if (Object.keys(params).length > 0) throw new GatewayError("invalid_request", "Upload status accepts no parameters");
        return safeJson(await this.dependencies.uploads.status());
      case "command.status":
        return safeJson(await this.dependencies.receipts.status(
          client.identity,
          string(params.method, "method", { max: 160 }),
          string(params.commandId, "commandId", { min: 8, max: 160 }),
        ));
      case "gateway.drain.status": {
        if (Object.keys(params).length > 0) throw new GatewayError("invalid_request", "Gateway drain status accepts no parameters");
        return safeJson(this.dependencies.sessions.administrativeDrainSnapshot());
      }
      case "gateway.update.config.status": {
        if (Object.keys(params).length > 0) throw new GatewayError("invalid_request", "Gateway update config status accepts no parameters");
        return safeJson(await this.updateService.configStatus());
      }
      case "gateway.update.config":
        return this.mutation(client, method, params, async () => {
          const keys = Object.keys(params);
          if (keys.some((key) => !["commandId", "sourceRoot", "artifactRoot"].includes(key))) {
            throw new GatewayError("invalid_request", "Gateway update config accepts only sourceRoot and artifactRoot");
          }
          const sourceRoot = string(params.sourceRoot, "sourceRoot", { max: 4_096 });
          const artifactRoot = params.artifactRoot === undefined || params.artifactRoot === null
            ? params.artifactRoot : string(params.artifactRoot, "artifactRoot", { max: 4_096 });
          return safeJson(await this.updateService.configure({ sourceRoot, artifactRoot }));
        });
      case "gateway.update.status": {
        if (Object.keys(params).some((key) => key !== "channel")) throw new GatewayError("invalid_request", "Gateway update status accepts only channel");
        const channel = params.channel === undefined ? this.updateService.channel : oneOf(params.channel, "channel", ["stable", "dev"] as const);
        return safeJson(await this.updateService.status(channel));
      }
      case "gateway.update":
        return this.mutation(client, method, params, async () => {
          const commandId = string(params.commandId, "commandId", { min: 8, max: 160 });
          return safeJson(await this.updateService.update({
            ...validateGatewayUpdateRequest(params),
            commandId,
          }));
        });
      case "gateway.rollback":
        return this.mutation(client, method, params, async () => {
          if (Object.keys(params).some((key) => !["commandId", "channel"].includes(key))) {
            throw new GatewayError("invalid_request", "Gateway rollback accepts only channel and commandId");
          }
          const commandId = string(params.commandId, "commandId", { min: 8, max: 160 });
          const channel = oneOf(params.channel === undefined ? "stable" : params.channel, "channel", ["stable", "dev"] as const);
          return safeJson(await this.updateService.rollback({ channel, commandId }));
        });
      case "device.list":
        return safeJson({ devices: await this.dependencies.devices.listDevices() });
      case "device.revoke": {
        const deviceId = string(params.deviceId, "deviceId", { max: 100 });
        return this.mutation(client, method, params, () => this.withMobileIdentityLane(deviceId, async () => {
          await this.dependencies.notifications?.removeDevice(deviceId);
          const revoked = await this.dependencies.devices.revoke(deviceId);
          if (revoked) this.dependencies.deviceRevoked(deviceId);
          return { revoked };
        }));
      }
      case "push.registration.status": {
        if (Object.keys(params).length > 0) throw new GatewayError("invalid_request", "Push registration status accepts no parameters");
        const notifications = this.requireNotifications();
        return safeJson(await notifications.status(client.isLocal ? undefined : client.identity));
      }
      case "notification.inbox.list": {
        if (Object.keys(params).some((key) => key !== "cursor" && key !== "limit")) {
          throw new GatewayError("invalid_request", "Notification inbox list accepts only cursor and limit");
        }
        const cursor = params.cursor === undefined ? undefined : string(params.cursor, "cursor", { min: 1, max: 256 });
        const limit = params.limit === undefined ? 50 : integer(params.limit, "limit", 1, 50);
        return safeJson(await this.requireNotifications().inbox(cursor, limit));
      }
      case "notification.inbox.read":
        return this.mutation(client, method, params, async () => {
          const allowed = new Set(["commandId", "id", "requestId"]);
          if (Object.keys(params).some((key) => !allowed.has(key))) {
            throw new GatewayError("invalid_request", "Notification read accepts only one notification identity");
          }
          const id = params.id === undefined ? undefined : string(params.id, "id", { min: 8, max: 160 });
          const requestId = params.requestId === undefined ? undefined : string(params.requestId, "requestId", { min: 8, max: 160 });
          if ((id === undefined) === (requestId === undefined)) {
            throw new GatewayError("invalid_request", "Notification read requires exactly one notification or request ID");
          }
          return safeJson(await this.requireNotifications().markInboxRead({
            ...(id === undefined ? {} : { id }),
            ...(requestId === undefined ? {} : { requestId }),
          }));
        });
      case "notification.inbox.readAll":
        return this.mutation(client, method, params, async () => {
          if (Object.keys(params).some((key) => key !== "commandId")) {
            throw new GatewayError("invalid_request", "Notification read-all accepts no parameters beyond commandId");
          }
          return safeJson(await this.requireNotifications().markAllInboxRead());
        });
      case "push.registration.upsert":
        if (client.isLocal) throw new GatewayError("auth_required", "Only an authenticated mobile device can register push delivery");
        return this.mutation(client, method, params, () => this.withMobileIdentityLane(client.identity, async () => {
          const allowed = new Set(["commandId", "installationId", "grantId", "secret", "previewsEnabled", "relayOrigin", "notifyWhenAskPresented"]);
          if (Object.keys(params).some((key) => !allowed.has(key))) throw new GatewayError("invalid_request", "Push registration contains unknown fields");
          const notifications = this.requireNotifications();
          const input = {
            deviceId: client.identity,
            installationId: string(params.installationId, "installationId", { min: 8, max: 160 }),
            grantId: string(params.grantId, "grantId", { min: 8, max: 160 }),
            secret: string(params.secret, "secret", { min: 43, max: 171 }),
            previewsEnabled: params.previewsEnabled === undefined ? false : boolean(params.previewsEnabled, "previewsEnabled"),
            relayOrigin: string(params.relayOrigin, "relayOrigin", { min: 1, max: 512 }),
            ...(params.notifyWhenAskPresented === undefined ? {} : { notifyWhenAskPresented: boolean(params.notifyWhenAskPresented, "notifyWhenAskPresented") }),
          };
          if (!await this.dependencies.devices.hasDevice(client.identity)) {
            throw new GatewayError("unauthenticated", "The authenticated mobile device is no longer paired");
          }
          return safeJson(await notifications.upsertGrant(input));
        }));
      case "push.registration.remove":
        if (client.isLocal) throw new GatewayError("auth_required", "Only an authenticated mobile device can remove its push registration");
        return this.mutation(client, method, params, () => this.withMobileIdentityLane(client.identity, async () => {
          if (Object.keys(params).some((key) => key !== "commandId")) throw new GatewayError("invalid_request", "Push registration removal accepts no parameters beyond commandId");
          return { removed: await this.requireNotifications().removeDevice(client.identity) };
        }));
      case "gateway.restart": {
        if (process.env.TRON_GATEWAY_SUPERVISED !== "1") {
          throw new GatewayError("unsupported", "Gateway restart requires an external supervisor");
        }
        if (this.restartRequested) {
          throw new GatewayError("busy", "Gateway restart is already draining; inspect gateway.drain.status or command.status", true);
        }
        let ownsSchedule = false;
        try {
          return await this.mutation(client, method, params, async () => {
            if (!this.dependencies.terminals.beginRestartDrain()) {
              throw new GatewayError("busy", "Close active terminal sessions before restarting the Gateway", true);
            }
            const activeSessionIds = this.dependencies.sessions.activeSessionIds();
            const drain = this.dependencies.sessions.beginAdministrativeDrain();
            this.dependencies.logger?.log(
              "info",
              `Gateway restart requested; draining ${activeSessionIds.length} active session${activeSessionIds.length === 1 ? "" : "s"}`,
              { event: "gateway.restart.requested", source: "transport" }
            );
            if (!this.restartRequested) {
              this.restartRequested = true;
              ownsSchedule = true;
            }
            return safeJson({
              restarting: drain.blockerCount === 0,
              scheduled: drain.blockerCount > 0,
              activeSessionIds,
              drainId: drain.drainId,
              drainRevision: drain.revision,
              drain,
            });
          });
        } finally {
          // CommandReceiptStore has completed (or failed) its terminal write
          // attempt before this boundary. A failed receipt cannot reopen the
          // already accepted drain, so replacement still progresses exactly once.
          if (ownsSchedule && !this.restartScheduled) {
            this.restartScheduled = true;
            setTimeout(this.dependencies.requestRestart, 100).unref();
          }
        }
      }
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
          return safeJson(await this.sessionListPages.nextPage(client.id, scope, cursor, limit));
        }
        const source = await this.dependencies.sessions.pageSource(scope);
        return safeJson(await this.sessionListPages.firstPage(client.id, scope, source, limit));
      }
      case "session.create": {
        const created = await this.mutation(client, method, params, async () => {
          const cwd = string(params.cwd, "cwd", { max: 4_096 });
          const sourceControl = parseSessionSourceControl(params.sourceControl);
          const createsWorktree = sourceControl !== undefined && sourceControl.mode !== "existingCheckout";
          if (createsWorktree) await this.dependencies.trust.requireResolved(cwd);
          const prepared = await this.gitWorktrees.prepare(cwd, sourceControl);
          let propagatedTrust: Awaited<ReturnType<TrustService["propagateResolvedDecision"]>> | undefined;
          try {
            if (createsWorktree) {
              propagatedTrust = await this.dependencies.trust.propagateResolvedDecision(cwd, prepared.cwd);
            }
            const slot = await this.dependencies.sessions.create(prepared.cwd);
            return safeJson({ sessionId: slot.id });
          } catch (error) {
            let cleanupError: unknown;
            let trustRollbackError: unknown;
            try {
              await propagatedTrust?.rollback();
            } catch (rollbackError) {
              trustRollbackError = rollbackError;
            }
            try {
              await prepared.cleanup();
            } catch (worktreeError) {
              cleanupError = worktreeError;
            }
            if (cleanupError || trustRollbackError) {
              throw new GatewayError(
                "internal",
                "Session creation failed and temporary Git state could not be fully cleaned up",
                false,
                {
                  failure: error instanceof Error ? error.message : "Unknown session creation failure",
                  ...(cleanupError ? { cleanup: cleanupError instanceof Error ? cleanupError.message : "Unknown worktree cleanup failure" } : {}),
                  ...(trustRollbackError ? { trustRollback: trustRollbackError instanceof Error ? trustRollbackError.message : "Unknown trust cleanup failure" } : {}),
                },
              );
            }
            throw error;
          }
        }) as { sessionId: string };
        return safeJson(created);
      }
      case "session.import": {
        const imported = await this.mutation(client, method, params, async () => {
          const uploadId = string(params.uploadId, "uploadId", { max: 100 });
          const importLease = await this.dependencies.uploads.prepareSessionImport(uploadId);
          try {
            const slot = await this.dependencies.sessions.importFromJsonl(
              importLease.path,
              string(params.cwd, "cwd", { max: 4_096 }),
            );
            await this.dependencies.uploads.remove(uploadId).catch(() => {});
            return safeJson({ sessionId: slot.id });
          } finally {
            await importLease.release();
          }
        }) as { sessionId: string };
        return safeJson(imported);
      }
      case "session.open": {
        const sessionId = string(params.sessionId, "sessionId", { max: 200 });
        const startedAt = performance.now();
        const slot = await this.dependencies.sessions.acquire(sessionId);
        // Join the exact canonical completion barrier before snapshotting. The
        // response and completionRevision therefore describe one admitted cut.
        await slot.reconcileAttention();
        const acquiredAt = performance.now();
        const syncToken = client.beginSynchronization(sessionId);
        const snapshot = slot.snapshot();
        client.establishSynchronization(sessionId, snapshot);
        const completedAt = performance.now();
        this.dependencies.logger.log(
          completedAt - startedAt >= 1_000 ? "warning" : "info",
          `Session open prepared in ${Math.max(0, Math.round(completedAt - startedAt))}ms (acquire ${Math.max(0, Math.round(acquiredAt - startedAt))}ms, snapshot ${Math.max(0, Math.round(completedAt - acquiredAt))}ms)`,
          { event: "session.open.prepared", source: "sessions" },
        );
        return safeJson({
          session: snapshot,
          syncToken,
          subscriptionToken: syncToken,
          completionRevision: this.dependencies.sessions.attentionProjection(sessionId).completionRevision,
        });
      }
      case "session.attention.read": {
        const sessionId = string(params.sessionId, "sessionId", { max: 200 });
        const throughCompletionRevision = integer(params.throughCompletionRevision, "throughCompletionRevision", 0, Number.MAX_SAFE_INTEGER);
        return safeJson(await this.dependencies.sessions.setAttention(sessionId, false, throughCompletionRevision));
      }
      case "session.attention.set":
        return this.mutation(client, method, params, async () => {
          const sessionId = string(params.sessionId, "sessionId", { max: 200 });
          const unread = boolean(params.unread, "unread");
          const throughCompletionRevision = params.throughCompletionRevision === undefined
            ? undefined
            : integer(params.throughCompletionRevision, "throughCompletionRevision", 0, Number.MAX_SAFE_INTEGER);
          if (!unread && throughCompletionRevision === undefined) {
            throw new GatewayError("invalid_request", "Mark read requires a completion revision");
          }
          return safeJson(await this.dependencies.sessions.setAttention(sessionId, unread, throughCompletionRevision));
        });
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
        const expectedRuntimeGeneration = optionalString(params.expectedRuntimeGeneration, "expectedRuntimeGeneration", 200);
        const expectedLeafEntryId = optionalString(params.expectedLeafEntryId, "expectedLeafEntryId", 200);
        const slot = await this.openedSlot(client, params);
        // Paging is a bounded read for an already-open presentation. It must
        // never create or revive event-subscription ownership after a close.
        return safeJson(slot.transcriptPage(
          before,
          expectedNextEntryId,
          expectedRuntimeGeneration,
          expectedLeafEntryId,
        ));
      }
      case "session.extensionActivity.list": {
        const slot = await this.openedSlot(client, params);
        const cursor = optionalString(params.cursor, "cursor", 200);
        const limit = params.limit === undefined ? 25 : integer(params.limit, "limit", 1, 50);
        const ownerId = optionalString(params.ownerId, "ownerId", 256);
        const runId = optionalString(params.runId, "runId", 256);
        const state = params.state === undefined ? undefined : oneOf(params.state, "state", ["completed", "failed", "stopped", "rejected"] as const);
        try {
          return safeJson(slot.extensionActivityHistory(cursor, limit, {
            ...(ownerId ? { ownerId } : {}), ...(runId ? { runId } : {}), ...(state ? { state } : {}),
          }));
        } catch (error) {
          if (error instanceof Error && /cursor conflict/u.test(error.message)) {
            throw new GatewayError("conflict", "Extension activity history changed; restart paging", true);
          }
          throw new GatewayError("invalid_request", error instanceof Error ? error.message : "Invalid extension activity history request");
        }
      }
      case "session.extensionActivity.get": {
        const slot = await this.openedSlot(client, params);
        const activityId = string(params.activityId, "activityId", { max: 256 });
        const generation = optionalString(params.historyRevision, "historyRevision", 64);
        const activity = slot.extensionActivityDetail(activityId, generation);
        if (!activity) throw new GatewayError("not_found", "Extension activity is not available");
        return safeJson({ activity });
      }
      case "session.processHistory.list": {
        const slot = await this.openedSlot(client, params);
        const cursor = optionalString(params.cursor, "cursor", 200);
        const limit = params.limit === undefined ? 25 : integer(params.limit, "limit", 1, 50);
        const kind = params.kind === undefined ? undefined : oneOf(params.kind, "kind", ["command", "subagent"] as const);
        const state = params.state === undefined ? undefined : oneOf(params.state, "state", [
          "queued", "running", "paused", "completed", "failed", "stopped", "rejected", "interrupted", "unknown",
        ] as const);
        try {
          return safeJson(slot.processHistory(cursor, limit, {
            ...(kind ? { kind } : {}),
            ...(state ? { state } : {}),
          }));
        } catch (error) {
          if (error instanceof Error && /cursor conflict/u.test(error.message)) {
            throw new GatewayError("conflict", "Process history changed; restart paging", true);
          }
          throw new GatewayError("invalid_request", error instanceof Error ? error.message : "Invalid process history request");
        }
      }
      case "session.processHistory.get": {
        const slot = await this.openedSlot(client, params);
        const processId = string(params.processId, "processId", { max: 256 });
        const generation = optionalString(params.historyRevision, "historyRevision", 64);
        const activity = slot.processDetail(processId, generation);
        if (!activity) throw new GatewayError("not_found", "Process activity is unavailable");
        return safeJson({ activity });
      }
      case "session.processTranscript.open": {
        const slot = await this.openedSlot(client, params);
        if (!client.sendEvent) throw new GatewayError("unsupported", "This connection cannot observe subagent transcripts");
        const processId = string(params.processId, "processId", { max: 256 });
        await slot.reconcileProcessChildSessionBinding(processId);
        const binding = slot.processChildSessionBinding(processId);
        if (!binding?.runId) throw new GatewayError("not_found", "Subagent session ownership is unavailable");
        const live = slot.processChildSessionPath(processId);
        return safeJson(await this.processTranscriptLeases.open(
          client.id,
          slot.id,
          processId,
          binding.ref,
          binding.runId,
          live?.path,
          client.sendEvent,
        ));
      }
      case "session.processTranscript.page": {
        const leaseId = string(params.leaseId, "leaseId", { max: 200 });
        const before = params.before === undefined ? undefined : integer(params.before, "before", 0, Number.MAX_SAFE_INTEGER);
        const expectedNextEntryId = optionalString(params.expectedNextEntryId, "expectedNextEntryId", 200);
        const expectedRevision = optionalString(params.expectedRevision, "expectedRevision", 64);
        return safeJson(await this.processTranscriptLeases.page(
          client.id,
          leaseId,
          before,
          expectedNextEntryId,
          expectedRevision,
        ));
      }
      case "session.processTranscript.close": {
        const leaseId = string(params.leaseId, "leaseId", { max: 200 });
        return { closed: this.processTranscriptLeases.closeOwned(client.id, leaseId) };
      }
      case "session.close": {
        const sessionId = string(params.sessionId, "sessionId", { max: 200 });
        const subscriptionToken = string(params.subscriptionToken, "subscriptionToken", { max: 200 });
        this.processTranscriptLeases.releaseParent(client.id, sessionId);
        return { closed: client.unsubscribe(sessionId, subscriptionToken) };
      }
      case "session.delete":
        return this.mutation(client, method, params, async () => {
          const sessionId = string(params.sessionId, "sessionId", { max: 200 });
          client.unsubscribe(sessionId);
          this.processTranscriptLeases.releaseSession(sessionId);
          await this.dependencies.sessions.delete(sessionId);
          this.dependencies.sessionDeleted(sessionId);
          try {
            await this.dependencies.uploads.removeSession(sessionId);
          } catch {
            this.dependencies.logger?.log(
              "warning",
              "A canonical session was deleted, but its attachment cleanup remains pending",
              { event: "uploads.session-cleanup-pending", source: "uploads" },
            );
          }
          return { deleted: true };
        });
      case "session.prompt":
        return this.mutation(client, method, params, async () => {
          const slot = await this.openedSlot(client, params);
          if (params.text !== undefined && typeof params.text !== "string") {
            throw new GatewayError("invalid_request", "text must be a string");
          }
          const text = params.text === undefined ? "" : admitPromptText(params.text);
          const uploadIds = params.uploadIds === undefined ? [] : arrayOfStrings(params.uploadIds, "uploadIds", 10);
          const resourceInvocation = params.resourceInvocation === undefined || params.resourceInvocation === null
            ? undefined : admitResourceInvocation(params.resourceInvocation);
          const resourceSource = resourceInvocation?.source;
          const resourceName = resourceInvocation?.name;
          const resourceArguments = resourceInvocation?.arguments;
          if (resourceInvocation === undefined && !text.trim() && uploadIds.length === 0) {
            throw new GatewayError("invalid_request", "Prompt text or attachments are required");
          }
          if (resourceInvocation !== undefined && resourceArguments !== text) {
            throw new GatewayError("invalid_request", "Prompt text must exactly match resourceInvocation.arguments");
          }
          const catalogResourceName = resourceSource === undefined
            ? undefined : canonicalResourceName(resourceSource, resourceName!);
          if (resourceSource !== undefined) {
            const commands = slot.commands();
            if (resourceSource === "extension" && uploadIds.length > 0) {
              throw new GatewayError("invalid_request", "Extension commands cannot include attachments");
            }
            const matches = commands.filter(
              (command) => command.source === resourceSource && command.name === catalogResourceName,
            );
            const shadowed = resourceSource !== "extension" && commands.some(
              (command) => command.source === "extension" && command.name === catalogResourceName,
            );
            if (matches.length !== 1 || shadowed) {
              throw new GatewayError("conflict", "The selected resource is no longer unambiguous for this session");
            }
          }
          const attachments = await this.dependencies.uploads.materialize(uploadIds, slot.id);
          const visiblePrompt = [resourceArguments ?? text, attachments.envelope].filter(Boolean).join("\n\n");
          const prompt = resourceSource === undefined
            ? visiblePrompt
            : `/${catalogResourceName!}${visiblePrompt ? ` ${visiblePrompt}` : ""}`;
          const behavior = params.behavior === undefined ? undefined : oneOf(params.behavior, "behavior", ["steer", "followUp"] as const);
          let resolveAdmission!: (result: { operationId: string }) => void;
          let rejectAdmission!: (error: unknown) => void;
          const admission = new Promise<{ operationId: string }>((resolve, reject) => {
            resolveAdmission = resolve;
            rejectAdmission = reject;
          });
          const execution = slot.prompt(prompt, attachments.images, behavior, {
            text,
            ...(resourceSource === undefined ? {} : {
              resourceInvocation: {
                source: resourceSource,
                name: resourceName!,
                arguments: resourceArguments!,
              },
            }),
            attachmentEnvelope: attachments.envelope,
            attachmentCount: uploadIds.length,
            ...(attachments.photoCount > 0 ? { photoCount: attachments.photoCount } : {}),
            ...(attachments.fileAttachmentCount > 0 ? { fileAttachmentCount: attachments.fileAttachmentCount } : {}),
            ...(attachments.attachments.length > 0 ? { attachments: attachments.attachments } : {}),
          }, resolveAdmission);
          void execution.then(resolveAdmission, rejectAdmission);
          return safeJson(await admission);
        });
      case "session.abort":
        return this.mutation(client, method, params, async () => {
          await (await this.openedSlot(client, params)).abort(
            params.kind === undefined
              ? "agent"
              : oneOf(params.kind, "kind", ["agent", "compaction", "retry", "branchSummary", "bash"] as const),
            optionalString(params.operationId, "operationId", 200),
          );
          return { aborted: true };
        }, true);
      case "session.clearQueue":
        return this.mutation(client, method, params, async () => {
          await (await this.openedSlot(client, params)).clearQueue();
          return { cleared: true };
        }, true);
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
        }, true);
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
      case "session.commandDetail": {
        const slot = await this.openedSlot(client, params);
        return safeJson(await slot.commandDetail(
          oneOf(params.source, "source", ["extension", "skill", "prompt"] as const),
          string(params.name, "name", { max: 8_192 }),
        ));
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
        }, true);
      case "extension.editor.update":
        return this.mutation(client, method, params, async () => (await this.openedSlot(client, params)).updateExtensionEditor(
          string(params.hostEpoch, "hostEpoch", { max: 100 }),
          integer(params.baseRevision, "baseRevision", 0, Number.MAX_SAFE_INTEGER),
          string(params.operationId, "operationId", { max: 256 }),
          boundedText(params.text, "text", 192 * 1_024),
        ), true);
      case "extension.toolsExpanded":
        return this.mutation(client, method, params, async () => (await this.openedSlot(client, params)).setExtensionToolsExpanded(
          string(params.hostEpoch, "hostEpoch", { max: 100 }),
          integer(params.presentationRevision, "presentationRevision", 0, Number.MAX_SAFE_INTEGER),
          boolean(params.expanded, "expanded"),
        ), true);

      case "provider.list":
        return this.providers(await this.modelRuntime(params));
      case "model.list":
        return this.models(await this.modelRuntime(params), params.cursor, params.limit);
      case "auth.begin": {
        const sessionId = optionalString(params.sessionId, "sessionId", 200);
        const operationId = this.dependencies.auth.start(
          client.id,
          string(params.providerId, "providerId", { max: 120 }),
          oneOf(params.authType, "authType", ["api_key", "oauth"] as const) as AuthType,
          await this.modelRuntime(params),
          client.identity,
          params.commandId === undefined
            ? undefined
            : string(params.commandId, "commandId", { min: 8, max: 160 }),
          sessionId === undefined ? "global" : `session:${sessionId}`,
        );
        return { operationId };
      }
      case "auth.respond": {
        const answered = this.dependencies.auth.respond(
          client.identity,
          string(params.operationId, "operationId", { max: 100 }),
          string(params.promptId, "promptId", { max: 100 }),
          typeof params.value === "string" ? params.value : "",
        );
        return { answered };
      }
      case "auth.callback": {
        const forwarded = await this.dependencies.auth.forwardCallback(
          client.identity,
          string(params.operationId, "operationId", { max: 100 }),
          string(params.callbackId, "callbackId", { max: 100 }),
          string(params.query, "query", { max: 16 * 1_024 }),
        );
        return { forwarded };
      }
      case "auth.resume":
        return this.dependencies.auth.resume(
          client.identity,
          client.id,
          string(params.operationId, "operationId", { max: 100 }),
        );
      case "auth.cancel": {
        const cancelled = this.dependencies.auth.cancel(client.identity, string(params.operationId, "operationId", { max: 100 }));
        return { cancelled };
      }
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
      case "models.refresh": {
        const controller = new AbortController();
        const work = this.workRegistry?.begin({
          kind: "administrative-provider-package-operation",
          hostEpoch: this.workRegistry.runtimeEpoch,
          cancellation: () => controller.abort(),
        });
        try {
          return await this.mutation(client, method, params, async () => {
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
        } finally {
          work?.settle();
        }
      }

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
        }, true);
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

  private requireNotifications(): NotificationService {
    if (!this.dependencies.notifications) throw new GatewayError("unsupported", "Push notifications are unavailable in this Gateway build");
    return this.dependencies.notifications;
  }

  private async withMobileIdentityLane<T>(deviceId: string, operation: () => Promise<T>): Promise<T> {
    const lane = this.mobileIdentityLanes.get(deviceId) ?? { mutex: new AsyncMutex(), users: 0 };
    lane.users += 1;
    this.mobileIdentityLanes.set(deviceId, lane);
    try {
      return await lane.mutex.run(operation);
    } finally {
      lane.users -= 1;
      if (lane.users === 0 && this.mobileIdentityLanes.get(deviceId) === lane) {
        this.mobileIdentityLanes.delete(deviceId);
      }
    }
  }

  private async mutation(
    client: ClientContext,
    method: string,
    params: Record<string, unknown>,
    operation: () => Promise<JsonValue>,
    settlementDuringDrain = false,
  ): Promise<JsonValue> {
    const commandId = string(params.commandId, "commandId", { min: 8, max: 160 });
    const work = this.workRegistry
      ? (settlementDuringDrain && !this.workRegistry.isAdmissionOpen
          ? this.workRegistry.beginDerived({
              kind: "terminal-receipt-persistence",
              hostEpoch: this.workRegistry.runtimeEpoch,
            })
          : this.workRegistry.begin({
              kind: "terminal-receipt-persistence",
              hostEpoch: this.workRegistry.runtimeEpoch,
            }))
      : undefined;
    try {
      return await this.dependencies.receipts.execute(client.identity, method, commandId, operation);
    } finally {
      work?.settle();
    }
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
