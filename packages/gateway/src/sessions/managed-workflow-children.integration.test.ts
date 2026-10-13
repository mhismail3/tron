import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, expect, it } from "vitest";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";
import { DETACHED_WORKFLOW_SCRIPT, startScriptedChild, type ChildModelServer } from "../../test-support/home-task-subagent-child.js";
import { waitFor } from "../../test-support/wait-for.js";

// Real managed-provider children, as in the Home task subagent cases: this file runs in the nested serial pass.
const bound = { boundMs: 20_000 };
const servers: ChildModelServer[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) await server.close();
  await disposeFixtures();
});

it("keeps an ordinary session showing a workflow child that outlives its completed workflow, until the child ends", async () => {
  const f = await fixture(false, false, undefined, true);
  const server = await startScriptedChild(f);
  servers.push(server);
  await writeFile(join(f.cwd, "detached-workflow.js"), DETACHED_WORKFLOW_SCRIPT);
  f.faux.setResponses([
    fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./detached-workflow.js", async: true }, { id: "workflow-launch" })], { stopReason: "toolUse" }),
    fauxAssistantMessage("Launched the detached workflow."),
  ]);
  const slot = await f.registry.create(f.cwd);
  await slot.prompt("launch the detached workflow");
  await waitFor(() => server.heldRequests() === 1, "workflow child live after the turn", bound);
  // The turn has settled, but the child it launched is still running, so the session is still active.
  expect(slot.catalogHasActiveSubagents).toBe(true);
  server.releaseHeld();
  await waitFor(() => !slot.catalogHasActiveSubagents, "workflow child ends and the session settles", bound);
}, 60_000);
