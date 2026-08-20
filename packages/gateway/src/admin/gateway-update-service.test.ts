import { mkdir, rm, writeFile, symlink, realpath } from "node:fs/promises";
import { mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it, vi } from "vitest";
import { GatewayError } from "../errors.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import {
  GatewayUpdateService,
  gatewayRollbackHelperArgs,
  gatewayUpdateHelperArgs,
  gatewayUpdateHelperPath,
  normalizeRuntimeIdentity,
  updaterFailureMessage,
  updaterFailureProgress,
  validateGatewayUpdateRequest,
} from "./gateway-update-service.js";

const identity = {
  schema: 1,
  kind: "tron-gateway-payload",
  channel: "stable",
  version: "2026.01",
  gatewayVersion: "0.1.0",
  nodeVersion: "22",
  sourceRevision: "source-revision",
  runtimeEpoch: "epoch-1",
  payloadFingerprint: "a".repeat(64),
};
const selection = {
  schema: 1,
  kind: "tron-gateway-selection",
  channel: "stable",
  version: "2026.01",
  payloadFingerprint: identity.payloadFingerprint,
};

async function fixture(): Promise<{ root: string; state: string }> {
  const root = await mkdtemp(join(tmpdir(), "tron-gateway-update-"));
  const channel = join(root, "gateway", "payloads", "stable");
  await mkdir(join(channel, "versions", identity.version), { recursive: true });
  await writeFile(join(channel, "current.json"), `${JSON.stringify(selection)}\n`);
  await writeFile(join(channel, "versions", identity.version, "manifest.json"), `${JSON.stringify(identity)}\n`);
  return { root, state: channel };
}

describe("Gateway update control plane", () => {
  it("rejects malformed or oversized deployment state before projecting it", async () => {
    const value = await fixture();
    try {
      await writeFile(join(value.state, "deployment-state.json"), "not-json");
      await expect(new GatewayUpdateService({ tronHome: value.root }).status()).rejects.toMatchObject({ code: "conflict" });
      await writeFile(join(value.state, "deployment-state.json"), "x".repeat(64 * 1_024 + 1));
      await expect(new GatewayUpdateService({ tronHome: value.root }).status()).rejects.toMatchObject({ code: "conflict" });
    } finally { await rm(value.root, { recursive: true, force: true }); }
  });

  it("normalizes runtime build fingerprints before comparing candidates", async () => {
    const value = await fixture();
    try {
      await rm(join(value.state, "current.json"));
      await writeFile(join(value.state, "deployment-state.json"), `${JSON.stringify({
        schema: 1, kind: "tron-gateway-deployment", channel: "stable", state: "prepared",
        updatedAt: "2026-01-01T00:00:00Z", candidateIdentity: identity,
      })}\n`);
      const service = new GatewayUpdateService({
        tronHome: value.root,
        runtimeIdentity: { buildFingerprint: identity.payloadFingerprint },
      });
      const status = await service.status();
      expect(status.currentIdentity).toEqual(expect.objectContaining({ payloadFingerprint: identity.payloadFingerprint }));
      expect(status.currentIdentity).not.toHaveProperty("buildFingerprint");
      expect(status.candidateAvailable).toBe(false);
      expect(status.candidateIdentity).toBeNull();
    } finally { await rm(value.root, { recursive: true, force: true }); }
  });

  it("keeps observed live identity separate from a newly selected pointer", async () => {
    const value = await fixture();
    try {
      await writeFile(join(value.state, "deployment-state.json"), `${JSON.stringify({
        schema: 1, kind: "tron-gateway-deployment", channel: "stable", state: "published",
        updatedAt: "2026-01-01T00:00:00Z", candidateIdentity: identity,
      })}\n`);
      const observed = { buildFingerprint: "b".repeat(64), sourceRevision: "old", runtimeEpoch: "old-epoch" };
      const status = await new GatewayUpdateService({ tronHome: value.root, runtimeIdentity: observed }).status();
      expect(status.currentIdentity).toEqual({ payloadFingerprint: observed.buildFingerprint, sourceRevision: "old", runtimeEpoch: "old-epoch" });
      expect(status.candidateAvailable).toBe(true);
      expect(status.candidateIdentity).toEqual(expect.objectContaining({ version: identity.version, payloadFingerprint: identity.payloadFingerprint }));
    } finally { await rm(value.root, { recursive: true, force: true }); }
  });

  it("projects terminal automatic rollback and preserves its original error", async () => {
    const value = await fixture();
    try {
      await writeFile(join(value.state, "deployment-state.json"), `${JSON.stringify({
        schema: 1, kind: "tron-gateway-deployment", channel: "stable", state: "rolled-back",
        commandId: "command-1", error: "candidate health timed out", updatedAt: "2026-01-01T00:00:02Z",
      })}\n`);
      await writeFile(join(value.state, "update-progress.json"), `${JSON.stringify({
        schema: 1, kind: "tron-gateway-update-progress", channel: "stable", state: "rolled-back",
        commandId: "command-1", error: "candidate health timed out", updatedAt: "2026-01-01T00:00:01Z",
      })}\n`);
      const status = await new GatewayUpdateService({ tronHome: value.root }).status();
      expect(status.state).toBe("rolled-back");
      expect(status.error).toBe("candidate health timed out");
      expect(status.commandId).toBe("command-1");
    } finally { await rm(value.root, { recursive: true, force: true }); }
  });

  it("returns a bounded projection and reports unavailable candidates explicitly", async () => {
    const value = await fixture();
    try {
      const status = await new GatewayUpdateService({ tronHome: value.root }).status();
      expect(status).toEqual({
        state: "unknown",
        channel: "stable",
        currentIdentity: null,
        candidateIdentity: null,
        candidateAvailable: false,
        error: null,
        updatedAt: null,
        commandId: null,
        rollbackAvailable: false,
        candidateOrigin: null,
        candidateProvenance: null,
      });
    } finally { await rm(value.root, { recursive: true, force: true }); }
  });

  it("projects Debug provenance only when every field matches the verified candidate", async () => {
    const value = await fixture();
    try {
      const provenance = {
        version: identity.version, payloadFingerprint: identity.payloadFingerprint,
        testedPayloadFingerprint: "d".repeat(64),
        sourceRevision: identity.sourceRevision, testedRuntimeEpoch: "debug-epoch",
        candidateRuntimeEpoch: identity.runtimeEpoch,
      };
      const writeState = async (debugOriginIdentity: Record<string, unknown>) => writeFile(join(value.state, "deployment-state.json"), `${JSON.stringify({
        schema: 1, kind: "tron-gateway-deployment", channel: "stable", state: "prepared",
        updatedAt: "2026-01-01T00:00:00Z", candidateOrigin: "debug", candidateIdentity: identity,
        debugOriginIdentity,
      })}\n`);
      const service = new GatewayUpdateService({
        tronHome: value.root,
        runtimeIdentity: { buildFingerprint: "b".repeat(64), sourceRevision: "old", runtimeEpoch: "old" },
      });
      await writeState(provenance);
      const status = await service.status();
      expect(status.candidateOrigin).toBe("debug");
      expect(status.candidateProvenance).toEqual({
        origin: "debug", version: provenance.version, payloadFingerprint: provenance.payloadFingerprint,
        sourceRevision: provenance.sourceRevision, testedRuntimeEpoch: provenance.testedRuntimeEpoch,
        candidateRuntimeEpoch: provenance.candidateRuntimeEpoch,
      });
      await writeState({ ...provenance, testedRuntimeEpoch: "" });
      const malformed = await service.status();
      expect(malformed.candidateAvailable).toBe(false);
      expect(malformed.candidateOrigin).toBeNull();
      expect(malformed.candidateProvenance).toBeNull();
      await writeState({ ...provenance, sourceRevision: "different" });
      expect((await service.status()).candidateOrigin).toBeNull();
      await writeFile(join(value.state, "deployment-state.json"), `${JSON.stringify({
        schema: 1, kind: "tron-gateway-deployment", channel: "stable", state: "prepared",
        updatedAt: "2026-01-01T00:00:00Z", candidateOrigin: "debug", candidateIdentity: identity,
      })}\n`);
      const missingProof = await service.status();
      expect(missingProof.candidateAvailable).toBe(false);
      expect(missingProof.candidateIdentity).toBeNull();
      expect(missingProof.candidateOrigin).toBeNull();
      expect(missingProof.candidateProvenance).toBeNull();
    } finally { await rm(value.root, { recursive: true, force: true }); }
  });

  it("does not expose a candidate until its manifest identity is complete", async () => {
    const value = await fixture();
    try {
      await writeFile(join(value.state, "deployment-state.json"), `${JSON.stringify({
        schema: 1, kind: "tron-gateway-deployment", channel: "stable", state: "prepared",
        updatedAt: "2026-01-01T00:00:00Z", candidateIdentity: { version: "candidate", payloadFingerprint: "b".repeat(64) },
      })}\n`);
      const status = await new GatewayUpdateService({ tronHome: value.root }).status();
      expect(status.candidateAvailable).toBe(false);
      expect(status.candidateIdentity).toBeNull();
      expect(status.error).toContain("candidate");
    } finally { await rm(value.root, { recursive: true, force: true }); }
  });

  it("fails truthfully without the LaunchAgent-owned updater", async () => {
    await expect(new GatewayUpdateService({ tronHome: "/tmp", environment: {} }).update({ channel: "stable", mode: "auto" }))
      .rejects.toMatchObject({ code: "unsupported" });
  });

  it("bounds asynchronous helper failures into update progress", () => {
    const error = new Error("x".repeat(4_096));
    expect(updaterFailureMessage(error)).toHaveLength(2_048);
    expect(updaterFailureProgress("stable", "command-1", error, "2026-01-01T00:00:00.000Z")).toEqual({
      schema: 1, kind: "tron-gateway-update-progress", channel: "stable", state: "failure",
      commandId: "command-1", error: "x".repeat(2_048), updatedAt: "2026-01-01T00:00:00.000Z",
    });
  });

  it("validates the LaunchAgent helper path and constructs bounded arguments", async () => {
    const value = await mkdtemp(join(tmpdir(), "tron-update-helper-"));
    try {
      const helper = join(value, "gateway-payload-deploy.mjs");
      await writeFile(helper, "#!/usr/bin/env node\n");
      expect(gatewayUpdateHelperPath({
        TRON_GATEWAY_UPDATE_HELPER: helper, TRON_GATEWAY_PAYLOAD_ROOT: value,
        TRON_GATEWAY_SUPERVISED: "1",
      })).toBe(helper);
      expect(gatewayUpdateHelperPath({
        TRON_GATEWAY_UPDATE_HELPER: "relative-helper.mjs", TRON_GATEWAY_PAYLOAD_ROOT: value,
        TRON_GATEWAY_SUPERVISED: "1",
      })).toBeUndefined();
      expect(gatewayUpdateHelperPath({})).toBeUndefined();
      expect(gatewayUpdateHelperPath({
        TRON_GATEWAY_UPDATE_HELPER: helper, TRON_GATEWAY_PAYLOAD_ROOT: value,
        TRON_GATEWAY_SUPERVISED: "0",
      })).toBeUndefined();
      expect(gatewayUpdateHelperArgs({ channel: "dev", mode: "artifact", candidateVersion: "v1", candidateFingerprint: "a".repeat(64), commandId: "command-1" })).toEqual([
        "apply", "--channel", "dev", "--mode", "artifact", "--candidate-version", "v1", "--candidate-fingerprint", "a".repeat(64), "--command-id", "command-1",
      ]);
      expect(() => gatewayUpdateHelperArgs({ channel: "stable", mode: "artifact", commandId: "bad" })).toThrow(GatewayError);
      expect(gatewayRollbackHelperArgs({ channel: "dev", commandId: "command-1" })).toEqual([
        "rollback", "--channel", "dev", "--command-id", "command-1",
      ]);
    } finally { await rm(value, { recursive: true, force: true }); }
  });

  it("writes a validated trusted source projection and rejects symlinked repositories", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-update-config-"));
    const source = join(home, "repo");
    try {
      await mkdir(join(source, "packages", "gateway", "scripts"), { recursive: true });
      await mkdir(join(source, "scripts"), { recursive: true });
      await writeFile(join(source, "packages", "gateway", "package.json"), "{}\n");
      await writeFile(join(source, "packages", "gateway", "package-lock.json"), "{}\n");
      await writeFile(join(source, "packages", "gateway", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
      await writeFile(join(source, "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
      const service = new GatewayUpdateService({ tronHome: home });
      const configured = await service.configure({ sourceRoot: await realpath(source) });
      expect(configured).toEqual(expect.objectContaining({ schema: 1, kind: "tron-gateway-update-config", sourceRoot: await realpath(source) }));
      expect(await service.configStatus()).toEqual(configured);
      const link = join(home, "linked-repo");
      await symlink(source, link);
      await expect(service.configure({ sourceRoot: link })).rejects.toMatchObject({ code: "conflict" });
    } finally { await rm(home, { recursive: true, force: true }); }
  });

  it("rejects arbitrary parameters and invalid command values", () => {
    expect(() => validateGatewayUpdateRequest({ channel: "stable", mode: "auto", path: "/tmp" })).toThrow(GatewayError);
    expect(() => validateGatewayUpdateRequest({ channel: "other", mode: "auto" })).toThrow(GatewayError);
    expect(() => validateGatewayUpdateRequest({ channel: "dev", mode: "artifact", candidateVersion: "v1" })).toThrow(GatewayError);
    expect(validateGatewayUpdateRequest({ channel: "dev", mode: "artifact", candidateVersion: "v1", candidateFingerprint: "a".repeat(64) })).toEqual({
      channel: "dev", mode: "artifact", candidateVersion: "v1", candidateFingerprint: "a".repeat(64),
    });
  });

  it("rejects an invalid runtime channel before system identity can be projected", () => {
    expect(() => new GatewayUpdateService({
      tronHome: "/tmp",
      runtimeChannel: "other" as unknown as "stable",
    })).toThrowError("Gateway runtime channel is invalid");
  });

  it("gates the capability on an injected updater and validates mutation command IDs", async () => {
    const callback = async () => ({ accepted: true as const });
    const base = {
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac" },
      updateService: new GatewayUpdateService({ tronHome: "/tmp", updater: callback }),
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation() },
    } as unknown as GatewayServiceDependencies;
    const configured = new GatewayService(base).info() as Record<string, unknown>;
    expect(configured.capabilities).toContain("gateway-update.v1");
    expect(configured.gatewayChannel).toBe("stable");
    const unsupported = new GatewayService({
      ...base,
      updateService: new GatewayUpdateService({ tronHome: "/tmp", environment: {} }),
    }).info() as Record<string, unknown>;
    expect(unsupported.capabilities).not.toContain("gateway-update.v1");
    expect(unsupported.gatewayChannel).toBe("stable");
    const debug = new GatewayService({
      ...base,
      updateService: new GatewayUpdateService({ tronHome: "/tmp", runtimeChannel: "dev", environment: {} }),
    }).info() as Record<string, unknown>;
    expect(debug.gatewayChannel).toBe("dev");

    const client: ClientContext = {
      id: "phone", identity: "device", isLocal: false,
      beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
      unsubscribe: () => true, attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
    };
    await expect(new GatewayService(base).invoke(client, "system.info", {}))
      .resolves.toMatchObject({ gatewayChannel: "stable" });
    await expect(new GatewayService({
      ...base,
      updateService: new GatewayUpdateService({ tronHome: "/tmp", runtimeChannel: "dev" }),
    }).invoke(client, "system.info", {})).resolves.toMatchObject({ gatewayChannel: "dev" });
    await expect(new GatewayService(base).invoke(client, "gateway.update", { channel: "stable", mode: "auto" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(new GatewayService(base).invoke(client, "gateway.rollback", { channel: "stable", commandId: "command-1", mode: "auto" }))
      .rejects.toMatchObject({ code: "invalid_request" });
  });

  it("binds update and rollback controls to the runtime-owned channel", async () => {
    const callback = vi.fn(async (request) => ({ accepted: true, request }));
    const service = new GatewayUpdateService({ tronHome: "/tmp", updater: callback, runtimeChannel: "stable" });
    const base = {
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac" }, updateService: service,
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation() },
    } as unknown as GatewayServiceDependencies;
    const client: ClientContext = {
      id: "phone", identity: "device", isLocal: false,
      beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
      unsubscribe: () => true, attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
    };
    await expect(new GatewayService(base).invoke(client, "gateway.rollback", { channel: "dev", commandId: "command-1" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(new GatewayService(base).invoke(client, "gateway.update", {
      channel: "dev", mode: "artifact", candidateVersion: "v1",
      candidateFingerprint: "a".repeat(64), commandId: "command-2",
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(callback).not.toHaveBeenCalled();

    const devCallback = vi.fn(async (request) => ({ accepted: true, request }));
    const devService = new GatewayUpdateService({ tronHome: "/tmp", updater: devCallback, runtimeChannel: "dev" });
    const devGateway = new GatewayService({ ...base, updateService: devService });
    await expect(devGateway.invoke(client, "gateway.rollback", { channel: "dev", commandId: "command-3" }))
      .resolves.toMatchObject({ accepted: true });
    expect(devCallback).toHaveBeenCalledWith({ channel: "dev", commandId: "command-3", operation: "rollback" });
    await expect(devGateway.invoke(client, "gateway.update.status", { channel: "stable" }))
      .rejects.toMatchObject({ code: "invalid_request" });
  });
});
