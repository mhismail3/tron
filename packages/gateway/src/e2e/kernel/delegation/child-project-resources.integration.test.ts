import { execFile } from "node:child_process";
import { mkdtemp, mkdir, realpath, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { createTestRegistry } from "../../../../test-support/gateway-registry.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { TrustService } from "../../../kernel/resources/trust-service.js";
import { ManagedSubagents } from "../../../kernel/delegation/managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "../../../kernel/delegation/delegated-provider.js";
import type { RuntimeRegistry } from "../../../kernel/session/runtime-registry.js";

const agent = (name: string) => `---\nname: ${name}\ndescription: ${name} probe\nmodel: tron-child-project/fixture\ntools: read\ninheritSkills: true\n---\nReturn the marker.\n`;

it("a subdirectory chat lists and launches only Project-root agents, and the child gets the host skills index", async () => {
  const root = await realpath(await mkdtemp("/tmp/cpr-"));
  const agentDir = join(root, "agent"); const project = join(root, "project"); const nested = join(project, "packages", "app"); const tronHome = join(root, "tron");
  const envKeys = ["PI_CODING_AGENT_DIR", DELEGATED_PROVIDER_ROOT_ENV, "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT", "PI_SUBAGENTS_SKILLS_RENDERER_MODULE", "PI_SUBAGENT_CHILD"];
  const previous = new Map(envKeys.map(key => [key, process.env[key]]));
  let registry: RuntimeRegistry | undefined;
  try {
    await Promise.all([mkdir(join(agentDir, "skills", "review"), { recursive: true }), mkdir(join(project, ".pi", "agents"), { recursive: true }), mkdir(join(nested, ".pi", "agents"), { recursive: true })]);
    await promisify(execFile)("git", ["init", "-q", project]);
    await writeFile(join(agentDir, "skills", "review", "SKILL.md"), "---\nname: review\ndescription: Review a change.\n---\nReview it.\n");
    await writeFile(join(project, ".pi", "agents", "root-agent.md"), agent("root-agent"));
    await writeFile(join(nested, ".pi", "agents", "nested-agent.md"), agent("nested-agent"));
    process.env.PI_CODING_AGENT_DIR = agentDir; delete process.env.PI_SUBAGENT_CHILD;
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    const faux = fauxProvider({ provider: "tron-child-project", models: [{ id: "fixture" }], tokensPerSecond: 1000000 });
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false }); runtime.registerNativeProvider(faux.provider);
    const trust = new TrustService(agentDir); await trust.set(project, true);
    registry = await createTestRegistry({ agentDir, tronHome, trust, managedSubagents, modelRuntimeFactory: async () => runtime,
      idleRuntimeMs: 60000, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
    await registry.initialize(); const slot = await registry.create(nested); await slot.setModel("tron-child-project", "fixture");
    const resources = await slot.resources() as unknown as { subagents: Array<{ name: string; source: string }> };
    expect(resources.subagents.filter(row => row.source === "project").map(row => row.name)).toEqual(["root-agent"]);
    const childContexts: string[] = []; const results: unknown[] = [];
    faux.setResponses([
      () => fauxAssistantMessage(fauxToolCall("subagent", { agent: "nested-agent", task: "Return NESTED.", async: false, acceptance: { level: "none", reason: "probe" } })),
      context => { results.push(context.messages.findLast(message => message.role === "toolResult")); return fauxAssistantMessage(fauxToolCall("subagent", { agent: "root-agent", task: "Return ROOT.", async: false, acceptance: { level: "none", reason: "probe" } })); },
      context => { childContexts.push(JSON.stringify(context)); return fauxAssistantMessage("CHILD_ROOT_DONE"); },
      context => { results.push(context.messages.findLast(message => message.role === "toolResult")); return fauxAssistantMessage("PARENT_DONE"); },
    ]);
    await slot.prompt("Launch the nested agent, then the root agent");
    await waitFor(() => !slot.isBusy, "children and parent settled");
    expect(results[0]).toMatchObject({ toolName: "subagent", isError: true });
    expect(JSON.stringify(results[0])).toContain("nested-agent");
    expect(results[1]).toMatchObject({ toolName: "subagent", isError: false });
    expect(childContexts).toHaveLength(1);
    expect(childContexts[0]).toContain('<index name=\\"skills\\"');
    expect(childContexts[0]).toContain("Review a change.");
    expect(childContexts[0]).not.toContain("available_skills");
  } finally {
    await registry?.dispose();
    for (const [key, value] of previous) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    await rm(root, { recursive: true, force: true });
  }
});
