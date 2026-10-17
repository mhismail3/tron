import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { UploadStore } from "../machine/upload-store.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import { INVOCATION_RECEIPT_TYPE } from "./invocation-receipts.js";

/** Repeatable evidence for #311: `npx vitest run src/sessions/multi-resource-message.e2e.test.ts`. */
const REPORT = "test-results/multi-resource-message.json";

afterEach(disposeFixtures);

function lastUserText(messages: readonly { role: string; content?: unknown }[]): string {
  const content = messages.filter(message => message.role === "user").at(-1)?.content;
  return typeof content === "string" ? content
    : (content as Array<{ type: string; text?: string }>).filter(part => part.type === "text").map(part => part.text).join("");
}

describe("one message invoking several skills and prompts (#311)", () => {
  it("expands a skill and two prompts in chip order, sends the text once, and projects every resource", async () => {
    const f = await fixture();
    await mkdir(join(f.agentDir, "skills", "review"), { recursive: true });
    const skillPath = join(f.agentDir, "skills", "review", "SKILL.md");
    await writeFile(skillPath, "---\nname: review\ndescription: Review carefully\n---\nREVIEW SKILL BODY\n");
    await mkdir(join(f.agentDir, "prompts"), { recursive: true });
    await writeFile(join(f.agentDir, "prompts", "tests.md"), "---\ndescription: Tests\n---\nWRITE TESTS for ${1:-the change}$ARGUMENTS\n");
    await writeFile(join(f.agentDir, "prompts", "docs.md"), "UPDATE DOCS\n");
    const slot = await f.registry.create(f.cwd);
    await slot.setModel(f.model.provider, f.model.id);

    const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: f.registry.homeOwner(),
      uploads: new UploadStore(join(f.root, "composer-uploads"), 1024),
      receipts: new CommandReceiptStore(join(f.root, "composer-receipts")) } as unknown as GatewayServiceDependencies);
    const client = { id: "composer-client", identity: "device:composer-test", isLocal: true, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;

    const requests: string[] = [];
    f.faux.setResponses([(context) => { requests.push(lastUserText(context.messages)); return fauxAssistantMessage("done"); }]);
    const resourceInvocations = [
      { source: "skill", name: "review", arguments: "" },
      { source: "prompt", name: "tests", arguments: "" },
      { source: "prompt", name: "docs", arguments: "" },
    ];
    const params = { commandId: "multi-resource-0001", sessionId: slot.id, text: "/compact the parser", resourceInvocations };
    const first = await service.invoke(client, "session.prompt", params) as { operationId: string };
    await waitFor(() => requests.length === 1 && !slot.isBusy, "the composed message to settle");
    // Resubmitting the same command returns its receipt; it never sends the message twice.
    expect(await service.invoke(client, "session.prompt", params)).toEqual(first);

    // The model receives each expansion in chip order and the typed text once. Text that
    // looks like an extension command is message text, not a command.
    const skillBlock = `<skill name="review" location="${skillPath}">\nReferences are relative to ${join(f.agentDir, "skills", "review")}.\n\nREVIEW SKILL BODY\n</skill>`;
    expect(requests).toEqual([`${skillBlock}\n\nWRITE TESTS for the change\n\nUPDATE DOCS\n\n/compact the parser`]);

    // The receipt records the whole ordered set and the typed text.
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const start = entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE).map(entry => entry.data)
      .find(receipt => receipt.receiptKind === "start");
    expect(start).toMatchObject({ source: "skill", name: "review", submittedText: "/compact the parser",
      resources: [{ source: "skill", name: "review" }, { source: "prompt", name: "tests" }, { source: "prompt", name: "docs" }] });
    expect(start).not.toHaveProperty("arguments");

    // The sent row shows every invoked resource and only the typed text, live and after a cold restart.
    const projected = (transcript: Array<{ role?: string; content?: unknown; semantic?: Record<string, unknown> }>) => {
      const row = transcript.find(item => item.role === "user")!;
      return { text: (row.content as Array<{ type: string; text?: string }>)[0]?.text, resources: row.semantic?.resourceInvocations, kind: row.semantic?.kind };
    };
    const expected = { text: "/compact the parser", resources: resourceInvocations, kind: "resourcePrompt" };
    const live = projected(slot.snapshot().transcript as never);
    expect(live).toEqual(expected);
    // An extension command is exclusive, and a resource is listed at most once.
    await expect(service.invoke(client, "session.prompt", { commandId: "multi-resource-0002", sessionId: slot.id, text: "now",
      resourceInvocations: [{ source: "extension", name: "compact", arguments: "now" }, resourceInvocations[0]] }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(service.invoke(client, "session.prompt", { commandId: "multi-resource-0003", sessionId: slot.id, text: "again",
      resourceInvocations: [resourceInvocations[1], resourceInvocations[1]] })).rejects.toMatchObject({ code: "invalid_request" });

    const cold = await f.restart();
    const reopened = await cold.acquire(slot.id);
    const restored = projected(reopened.snapshot().transcript as never);
    expect(restored).toEqual(expected);

    await mkdir("test-results", { recursive: true });
    await writeFile(REPORT, JSON.stringify({ suite: "multi-resource-message", issue: 311,
      modelInput: requests[0], startReceipt: start, live, restored }, null, 2));
  }, 60_000);
});
