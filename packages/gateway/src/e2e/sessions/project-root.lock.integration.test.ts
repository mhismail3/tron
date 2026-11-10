import { readFile, realpath } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { expectRequestShapes, expectSystemShapes } from "../../../test-support/lock-projections.js";
import { projectRootTrustScenario } from "../../../test-support/lock-scenarios.js";

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

describe("gateway/session-catalog project-root lock", () => {
  it("projectDir: a subdirectory chat of a trusted Git project loads the root's Project layer and keeps its cwd", async () => {
    const gateway = await startLockGateway("project-root-trust");
    gateways.push(gateway);
    const { root, project, nested, systemPrompt, undecided, refused, decided, rootInspection, nestedInspection, created, sessionId, opened,
      chatSettings, projectSettings, revoked, transcript } = await projectRootTrustScenario(gateway);

    const recorded = gateway.record();
    const canonicalJsonl = await gateway.canonical(sessionId);
    const tmp = (path: string): string => path.split(root).join("<tmp>");
    const trust = Object.entries(JSON.parse(await readFile(join(gateway.agentDir, "trust.json"), "utf8"))).map(([path, trusted]) => ({ path, trusted }));
    const undecidedAnswer = { cwd: nested, projectDir: project, defaultDecision: "ask", effectiveDecision: null, requiresDecision: true, savedDecision: null };
    expect(undecided.result).toEqual(undecidedAnswer);
    expect(refused.error).toEqual({ code: "trust_required", message: "Choose whether to trust this project before loading agent resources",
      retryable: false, details: undecidedAnswer });
    expect(decided.ok, JSON.stringify(decided)).toBe(true);
    expect(decided.result.changes).toEqual([expect.objectContaining({ key: "permissions.projectTrust", layer: "global", before: null, after: true,
      qualifiers: { project } })]);
    const trustReview = (before: string, after: string, requiresTap: boolean, reason: string) => ({ status: "applied", review: { title: "Trust for this project",
      requiresTap, reason, items: [{ label: "Trust for this project", before, after, detail: "Global stored value\nglobal\nTrusting a project runs its extensions and hooks." }] } });
    expect(decided.result).toMatchObject(trustReview("Not set", "Trusted", true, "Trust the lock project"));
    expect(revoked.result).toMatchObject(trustReview("Trusted", "Not trusted", false, "Stop trusting the lock project"));
    expect(rootInspection.result).toEqual({ cwd: project, projectDir: project, defaultDecision: "ask", effectiveDecision: true, requiresDecision: true, savedDecision: true });
    expect(nestedInspection.result).toEqual({ ...undecidedAnswer, effectiveDecision: true, savedDecision: true });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    expect(opened.result.session.cwd).toBe(nested);
    expect(opened.result.session.compactionPolicy.currentBudgets).toMatchObject({ reserveTokens: 4_096, keepRecentTokens: 240 });
    const resolved = (response: { result?: any }) => response.result.keys.map((key: { key: string; layer: string; display: string }) => `${key.key}=${key.display}@${key.layer}`);
    expect(resolved(chatSettings)).toEqual(["run.retry.maxRetries=7 retries@project"]);
    expect(resolved(projectSettings)).toEqual(["permissions.projectTrust=Trusted@global", "run.retry.maxRetries=7 retries@project"]);
    expect(revoked.ok, JSON.stringify(revoked)).toBe(true);
    expect(revoked.result.changes).toEqual([expect.objectContaining({ before: true, after: false, qualifiers: { project } })]);
    expect(trust).toEqual([{ path: project, trusted: false }, { path: await realpath(gateway.cwd), trusted: true }]);
    expect(transcript.ok).toBe(true);
    expect(transcript.result.items.map((item: { kind: string; role?: string; stopReason?: string; semantic?: { lifecycle?: string }; content?: Array<{ type: string; text?: string; name?: string }> }) =>
      [item.kind === "message" ? `${item.role}${item.stopReason ? `:${item.stopReason}` : ""}` : item.kind, item.semantic?.lifecycle ?? "",
        ...(item.content ?? []).map((part) => part.type === "toolCall" ? `call:${part.name}` : part.text)].join(" | "))).toEqual([
      "modelChange | ", "thinkingChange | ",
      "user | completed | where does this chat run?",
      "assistant:toolUse |  | call:project_probe",
      `toolResult |  | cwd=${nested} projectDir=${project}`,
      "assistant:stop |  | The chat runs in the subdirectory of the trusted project.",
      "user | completed | and after revoking trust?",
      "assistant:stop |  | Trust was revoked for the project.",
    ]);
    const [header] = canonicalJsonl as Array<{ type?: string; cwd?: string }>;
    expect(header).toMatchObject({ type: "session", cwd: tmp(nested) });
    expect(canonicalJsonl.map((entry) => { const { type, customType } = entry as { type?: string; customType?: string }; return type === "custom" ? customType : type; }))
      .toEqual(["session", "model_change", "thinking_level_change", "tron.context-window.v1", "tron.settings.v1", "tron.settings.v1",
        "tron.chat-invocation.v1", "tron.chat-invocation.v1", "message", "message", "tron.chat-invocation.v1", "message", "message", "message",
        "tron.chat-invocation.v1", "tron.chat-invocation.v1", "tron.chat-invocation.v1", "message", "message", "tron.chat-invocation.v1", "message",
        "tron.chat-invocation.v1"]);
    const savedTools = canonicalJsonl.flatMap((entry) => {
      const record = entry as { customType?: string; data?: { fixed?: { "tools.active"?: { value?: string[] } } } };
      return record.customType === "tron.settings.v1" ? [record.data?.fixed?.["tools.active"]?.value ?? []] : [];
    });
    expect(savedTools).toHaveLength(2);
    for (const tools of savedTools) { expect(tools).toContain("project_probe"); expect(tools).not.toContain("nested_probe"); }
    expect(Object.fromEntries(["root-lock-skill", "nested-lock-skill", "ROOT-INSTRUCTIONS", "NESTED-INSTRUCTIONS"].map((marker) => [marker, systemPrompt().includes(marker)])))
      .toEqual({ "root-lock-skill": true, "nested-lock-skill": false, "ROOT-INSTRUCTIONS": true, "NESTED-INSTRUCTIONS": true });
    const probe = `cwd=${tmp(nested)} projectDir=${tmp(project)}`;
    expect(recorded.providerRequests.map((request) => request.messages.map((message) => {
      const { role, text, toolCalls, toolName } = message as { role: string; text?: string; toolCalls?: string[]; toolName?: string };
      return `${role}:${text ?? ""}${toolCalls ? `[${toolCalls.join(",")}]` : ""}${toolName ? `(${toolName})` : ""}`;
    }))).toEqual([
      ["user:where does this chat run?"],
      ["user:where does this chat run?", "assistant:[project_probe]", `toolResult:${probe}(project_probe)`],
      ["user:where does this chat run?", "assistant:[project_probe]", `toolResult:${probe}(project_probe)`,
        "assistant:The chat runs in the subdirectory of the trusted project.", "user:and after revoking trust?"],
    ]);
    expect(recorded.providerRequests[0]!.tools).toContain("project_probe");
    expect(recorded.providerRequests[0]!.tools).not.toContain("nested_probe");
    expect(recorded.providerRequests[2]!.tools).not.toContain("project_probe");
    expectRequestShapes(recorded.providerRequests, ["trustedProjectSubdirectory", "trustedProjectSubdirectory", "revokedProjectSubdirectory"]);
    expectSystemShapes(canonicalJsonl, ["projectSubdirectorySystem#0", "projectSubdirectorySystem#1"]);
    const receipts = canonicalJsonl.flatMap((entry) => {
      const record = entry as { customType?: string; data?: { receiptKind?: string; lifecycle?: string } };
      return record.customType === "tron.chat-invocation.v1" ? [`${record.data?.receiptKind}:${record.data?.lifecycle ?? ""}`] : [];
    });
    expect(receipts).toEqual(["start:staged", "transition:accepted", "binding:", "terminal:completed", "start:staged", "transition:accepted", "binding:", "terminal:completed"]);
  });
});
