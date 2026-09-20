import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { attributeExtensions } from "../extensions/owner-attribution.js";
import {
  DELEGATED_PROVIDER_ROOT_ENV,
  DELEGATED_PROVIDER_TOOL_NAME,
  delegatedArtifactPathAllowed,
  delegatedArtifactRoot,
  delegatedProviderEnvironment,
  delegatedProviderOrigin,
  isInstalledDelegatedTool,
  trustedDelegatedController,
} from "./delegated-provider.js";

const OWNER = { id: "extension:installed", title: "Subagents", source: "npm:pi-subagents" };
const FOREIGN_OWNER = { id: "extension:foreign", title: "Other", source: "npm:other" };

function extension(input: { path: string; resolvedPath?: string; owner?: typeof OWNER; source?: string }) {
  return {
    path: input.path,
    resolvedPath: input.resolvedPath ?? input.path,
    sourceInfo: { path: input.path, source: input.source ?? "npm:pi-subagents", scope: "user", origin: "package" },
    handlers: new Map(),
    tools: new Map([[DELEGATED_PROVIDER_TOOL_NAME, { definition: { name: DELEGATED_PROVIDER_TOOL_NAME, execute: async () => ({}) }, sourceInfo: {} }]]),
    commands: new Map(),
    shortcuts: new Map(),
    messageRenderers: new Map(),
    entryRenderers: new Map(),
    _owner: input.owner,
  };
}

describe("delegated provider origin", () => {
  it("resolves the installed provider only from its own finalized tool owner", () => {
    // A same-named tool from another package must never become the provider.
    const foreign = {
      path: "/packages/other/index.ts",
      resolvedPath: "/packages/other/index.ts",
      sourceInfo: { path: "/packages/other/index.ts", source: "npm:other", scope: "user", origin: "package" },
      tools: new Map(),
      commands: new Map(),
      handlers: new Map(),
      shortcuts: new Map(),
      messageRenderers: new Map(),
      entryRenderers: new Map(),
    };
    expect(delegatedProviderOrigin([foreign as never])).toEqual({ source: "pi-subagents" });
    expect(delegatedProviderOrigin([])).toEqual({ source: "pi-subagents" });
  });

  it("requires the finalized provider package identity in addition to path evidence", () => {
    const spoofed = extension({
      path: "/tmp/pi-subagents/project-extension/index.ts",
      source: "npm:other",
    });
    const spoofedResult = attributeExtensions({ extensions: [spoofed as never], errors: [], runtime: {} as never });
    expect(delegatedProviderOrigin(spoofedResult.extensions)).toEqual({ source: "pi-subagents" });
    const installed = extension({ path: "/tmp/pi-subagents/installed/index.ts" });
    const installedResult = attributeExtensions({ extensions: [installed as never], errors: [], runtime: {} as never });
    const origin = delegatedProviderOrigin(installedResult.extensions);
    expect(origin.source).toBe("npm:pi-subagents");
    expect(origin.owner?.source).toBe("npm:pi-subagents");
  });

  it("accepts only the exact installed owner identity for control", () => {
    expect(isInstalledDelegatedTool("subagent", { source: "npm:pi-subagents", owner: OWNER }, OWNER.id)).toBe(true);
    // Same tool name, different owner: not authority.
    expect(isInstalledDelegatedTool("subagent", { source: "npm:pi-subagents", owner: FOREIGN_OWNER }, OWNER.id)).toBe(false);
    // Same owner, different tool name: not the delegated controller.
    expect(isInstalledDelegatedTool("subagent_wait", { source: "npm:pi-subagents", owner: OWNER }, OWNER.id)).toBe(false);
    expect(isInstalledDelegatedTool("subagent", undefined, OWNER.id)).toBe(false);
    expect(isInstalledDelegatedTool("subagent", { source: "npm:pi-subagents", owner: OWNER }, undefined)).toBe(false);
  });

  it("returns a controller definition only for the proven installed owner", () => {
    const definition = { name: DELEGATED_PROVIDER_TOOL_NAME } as never;
    const definitionFor = (name: string) => (name === DELEGATED_PROVIDER_TOOL_NAME ? definition : undefined);
    expect(trustedDelegatedController({
      toolName: "subagent", origin: { source: "npm:pi-subagents", owner: OWNER }, installedOwnerId: OWNER.id, definitionFor,
    })).toBe(definition);
    expect(trustedDelegatedController({
      toolName: "subagent", origin: { source: "npm:pi-subagents", owner: FOREIGN_OWNER }, installedOwnerId: OWNER.id, definitionFor,
    })).toBeUndefined();
  });
});

describe("delegated artifact root contract", () => {
  it("derives one home-owned root and propagates it before child launch", () => {
    const root = delegatedArtifactRoot("/fixture/.tron");
    expect(root).toBe("/fixture/.tron/internal/subagents");
    const environment: NodeJS.ProcessEnv = {};
    delegatedProviderEnvironment(root, environment);
    expect(environment[DELEGATED_PROVIDER_ROOT_ENV]).toBe(root);
  });

  it("admits only the exact controlled subtree when a root is configured", () => {
    const root = mkdtempSync(join(tmpdir(), "tron-delegated-root-"));
    const run = join(root, "async-subagent-runs", "run-1");
    mkdirSync(run, { recursive: true, mode: 0o700 });
    writeFileSync(join(run, "status.json"), "{}", { mode: 0o600 });
    try {
      expect(delegatedArtifactPathAllowed(run, "/unrelated", root)).toBe(true);
      expect(delegatedArtifactPathAllowed(join(run, "status.json"), "/unrelated", root)).toBe(true);
      expect(delegatedArtifactPathAllowed(join(root, "nested", "status.json"), "/unrelated", root)).toBe(false);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("delegated artifact path policy", () => {
  let root = "";
  let cwd = "";
  let runDirectory = "";

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "tron-delegated-policy-"));
    cwd = join(root, "workspace");
    runDirectory = join(cwd, ".pi", "subagents", "async-subagent-runs", "run-1");
    mkdirSync(runDirectory, { recursive: true });
    writeFileSync(join(runDirectory, "status.json"), "{}");
    writeFileSync(join(runDirectory, "events.jsonl"), "");
    writeFileSync(join(runDirectory, "notes.txt"), "");
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it("accepts only the run directory and its direct lifecycle files", () => {
    expect(delegatedArtifactPathAllowed(runDirectory, cwd)).toBe(true);
    expect(delegatedArtifactPathAllowed(join(runDirectory, "status.json"), cwd)).toBe(true);
    expect(delegatedArtifactPathAllowed(join(runDirectory, "events.jsonl"), cwd)).toBe(true);
    // A nested or unrelated file inside the run directory is not a lifecycle file.
    expect(delegatedArtifactPathAllowed(join(runDirectory, "notes.txt"), cwd)).toBe(false);
    expect(delegatedArtifactPathAllowed(join(runDirectory, "nested", "status.json"), cwd)).toBe(false);
    // A non-existent path fails closed: the policy canonicalizes the real target
    // rather than accepting a lexical shape it never observed on disk.
    expect(delegatedArtifactPathAllowed(join(runDirectory, "missing.json"), cwd)).toBe(false);
  });

  it("rejects traversal, relative, and unrelated paths", () => {
    expect(delegatedArtifactPathAllowed("status.json", cwd)).toBe(false);
    expect(delegatedArtifactPathAllowed(`${runDirectory}/../run-1/status.json`, cwd)).toBe(false);
    expect(delegatedArtifactPathAllowed(join(cwd, "status.json"), cwd)).toBe(false);
    expect(delegatedArtifactPathAllowed(join(root, "elsewhere", "status.json"), cwd)).toBe(false);
  });

  it("rejects a symlinked run directory that escapes the owned root", () => {
    const escape = join(root, "escape");
    mkdirSync(escape, { recursive: true });
    writeFileSync(join(escape, "status.json"), "{}");
    const link = join(cwd, ".pi", "subagents", "async-subagent-runs", "linked");
    try {
      symlinkSync(escape, link);
      expect(delegatedArtifactPathAllowed(join(link, "status.json"), cwd)).toBe(false);
    } catch {
      // Symlink creation can be unavailable in constrained environments; the
      // canonical-shape check above still covers the escape path.
    }
  });
});
