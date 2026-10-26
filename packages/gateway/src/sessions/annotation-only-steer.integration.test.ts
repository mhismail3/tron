import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import { startLockGateway } from "../../test-support/gateway-lock-harness.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

// Annotation-only means no typed body, not empty wire text: the composer sends
// the quote/comment envelope unchanged through both prompt admission routes.
const annotation = "<annotation>\n> Tron project (6 notes): rule — keep one owner.\n\nApply this rule.\n</annotation>";

describe("annotation-only queued steering over the Gateway socket", () => {
  for (const home of [false, true]) {
    it(`${home ? "Home" : "session"}: edits, removes and delivers an annotation-only steer to the provider`, async () => {
      const gateway = await startLockGateway(`annotation-steer-${home ? "home" : "session"}`, home
        ? { home: { memorySummarizer: () => async () => fauxAssistantMessage("Memory summary.") } } : {});
      let release = (): void => {};
      const held = new Promise<void>((resolve) => { release = resolve; });
      let reached = (): void => {};
      const started = new Promise<void>((resolve) => { reached = resolve; });
      try {
        const phone = await gateway.connect("phone");
        let sessionId: string;
        if (home) {
          const settings = JSON.parse(await readFile(join(gateway.agentDir, "settings.json"), "utf8"));
          const designated = await phone.request("home.designate", { commandId: gateway.commandId(),
            model: { provider: settings.defaultProvider, id: settings.defaultModel } });
          expect(designated.ok, JSON.stringify(designated)).toBe(true);
          const configured = await phone.request("settings.change", { commandId: gateway.commandId(), target: { kind: "home" },
            changes: [{ key: "model.queue[role=background]", layer: "session", op: "set",
              value: [`${settings.defaultProvider}/${settings.defaultModel}`] }] });
          expect(configured.ok, JSON.stringify(configured)).toBe(true);
          const opened = await phone.request("home.open", {});
          expect(opened.ok, JSON.stringify(opened)).toBe(true);
          sessionId = opened.result.sessionId;
        } else {
          const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
          expect(created.ok, JSON.stringify(created)).toBe(true);
          sessionId = created.result.sessionId;
        }
        const opened = await phone.request("session.open", { sessionId });
        expect(opened.ok, JSON.stringify(opened)).toBe(true);
        expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
        const slot = await gateway.registry.acquire(sessionId);
        const prompt = (text: string, behavior?: string) => phone.request(home ? "home.prompt" : "session.prompt", {
          commandId: gateway.commandId(), ...(home ? {} : { sessionId }), text, ...(behavior ? { behavior } : {}),
        });
        gateway.script([
          async () => { reached(); await held; return fauxAssistantMessage("Current turn finished."); },
          () => fauxAssistantMessage("Annotation received."),
        ]);
        expect((await prompt("Hold the current turn")).ok).toBe(true);
        await awaitsWithin(started, "the held provider request");
        expect((await prompt(annotation, "steer")).ok).toBe(true);
        expect((await prompt(annotation + "\n\nRemove this copy", "steer")).ok).toBe(true);
        await waitFor(() => slot.snapshot().queuedItems.length === 2, "both annotation steers");
        const before = slot.snapshot();
        expect(before.queuedItems[0]?.text).toBe(annotation);
        const edited = annotation.replace("Apply this rule.", "Keep the annotation inside the card.");
        const replaced = await phone.request("session.queue.replace", {
          commandId: gateway.commandId(), sessionId, expectedRevision: before.queueRevision,
          items: [{ id: before.queuedItems[0]!.id, behavior: "steer", text: edited }],
        });
        expect(replaced.ok, JSON.stringify(replaced)).toBe(true);
        expect(slot.snapshot().queuedItems.map(({ text }) => text)).toEqual([edited]);
        expect(gateway.record().providerRequests).toHaveLength(1);
        release();
        await gateway.settled(sessionId);
        expect(slot.snapshot().queuedItems).toEqual([]);
        const requests = gateway.record().providerRequests;
        expect(requests).toHaveLength(2);
        expect(requests[1]!.messages).toContainEqual({ role: "user", text: edited });
        const canonical = await gateway.canonical(sessionId);
        const users = canonical.flatMap((entry) => {
          const message = (entry as { message?: { role?: string; content?: unknown } }).message;
          return message?.role === "user" ? [JSON.stringify(message.content)] : [];
        });
        expect(users).toHaveLength(2);
        expect(users[1]).toContain(JSON.stringify(edited).slice(1, -1));
      } finally {
        release();
        await gateway.dispose();
      }
    });
  }
});
