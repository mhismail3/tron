import { describe, expect, it, vi } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { historyEntry, historyPage, HISTORY_TEXT_CHARS, type HistoryCursor } from "./history.js";

describe("canonical Session History pages", () => {
  it("traverses beyond the recent tree cap in both directions without body projection or duplicates", () => {
    const manager = SessionManager.inMemory("/fixture");
    const ids = Array.from({ length: 1_105 }, (_, i) => manager.appendMessage({ role: "user", content: `message ${i}`, timestamp: 10 - i }));
    const tree = vi.spyOn(manager, "getTree");
    let cursor: HistoryCursor | undefined;
    let lastPage = historyPage(manager, "runtime");
    const seen: string[] = [];
    do {
      lastPage = historyPage(manager, "runtime", cursor);
      expect(lastPage.nodes.length).toBeLessThanOrEqual(100);
      seen.push(...lastPage.nodes.map(n => n.id));
      cursor = lastPage.older;
    } while (cursor);
    expect(seen).toEqual(ids.toReversed());
    expect(new Set(seen).size).toBe(1_105);
    expect(tree).not.toHaveBeenCalled();
    while (lastPage.newer) lastPage = historyPage(manager, "runtime", lastPage.newer);
    expect(lastPage.nodes[0]!.id).toBe(ids.at(-1));
    expect(() => historyPage(manager, "runtime", { ordinal: 10, entryId: ids[11]!, direction: "older" })).toThrow(/position changed/);
    expect(() => historyPage(manager, "runtime", { ordinal: -1, entryId: ids[0]!, direction: "older" })).toThrow(/position changed/);
  });

  it("shows genuine tool-only, thinking, log, bookmark and branch evidence", () => {
    const manager = SessionManager.inMemory("/fixture");
    const root = manager.appendMessage({ role: "user", content: "Root prompt", timestamp: 0 });
    const tool = manager.appendMessage({ ...fauxAssistantMessage(""), content: [{ type: "toolCall", id: "call", name: "read", arguments: { path: "file" } }] });
    const thinking = manager.appendMessage({ ...fauxAssistantMessage(""), content: [{ type: "thinking", thinking: "Consider boundaries" }] });
    const log = manager.appendCustomEntry("worker.progress", { message: "Preparing" });
    const bookmark = manager.appendLabelChange(root, "Checkpoint");
    const branch = manager.branchWithSummary(root, "Alternative approach");
    manager.appendThinkingLevelChange("high"); manager.appendModelChange("fixture", "model");
    manager.appendCompaction("Full compaction", root, 2_000); manager.appendSessionInfo("Renamed");
    manager.appendCustomMessageEntry("note", "Custom authored note", true);
    const shell = manager.appendMessage({ role: "bashExecution", command: "pwd", output: "/fixture", exitCode: 0, cancelled: false, truncated: false, timestamp: 0 });
    const result = manager.appendMessage({ role: "toolResult", toolCallId: "call", toolName: "read", content: [{ type: "text", text: "Full result" }], isError: false, timestamp: 0 });
    const image = manager.appendMessage({ role: "user", content: [{ type: "image", mimeType: "image/png", data: "fixture-image-data" }], timestamp: 0 });
    const page = historyPage(manager, "runtime");
    const byID = new Map(page.nodes.map(n => [n.id, n]));
    expect(byID.get(tool)?.preview).toBe("Tool call: read");
    expect(byID.get(thinking)?.preview).toBe("Thinking: Consider boundaries");
    expect(byID.get(log)?.preview).toBe("worker.progress");
    expect(byID.get(bookmark)).toMatchObject({ kind: "label", bookmarkTargetId: root, label: "Checkpoint" });
    expect(byID.get(branch)).toMatchObject({ kind: "branchSummary", preview: "Alternative approach" });
    expect(byID.get(root)!.childCount).toBeGreaterThan(1);
    expect(byID.get(tool)!.isCurrentPath).toBe(false);
    expect(byID.get(branch)!.isCurrentPath).toBe(true);
    expect(byID.get(shell)).toMatchObject({ kind: "bash", preview: "pwd" });
    expect(byID.get(image)?.preview).toBe("Image attachment");
    expect(historyEntry(manager, "runtime", result, 0)).toMatchObject({ text: "Full result", metadata: { tool: "read", toolCallId: "call" } });
    expect(historyEntry(manager, "runtime", shell, 0)).toMatchObject({ text: "pwd\n\n/fixture", metadata: { exitCode: 0 } });
    expect(page.nodes.map(n => n.kind)).toEqual(expect.arrayContaining(["message", "customEntry", "label", "branchSummary", "thinkingChange", "modelChange", "compaction", "sessionInfo", "customMessage"]));
  });

  it("preserves model-context edits as explicit history evidence", () => {
    const manager = SessionManager.inMemory("/fixture");
    const target = manager.appendMessage({ role: "user", content: "Original request", timestamp: 0 });
    const edit = manager.appendContextEdit(target, { content: "Sanitized request" });
    expect(manager.buildSessionProjection().messages[0]).toMatchObject({ role: "user", content: "Sanitized request" });
    const page = historyPage(manager, "runtime");
    expect(page.nodes.find(node => node.id === edit)).toMatchObject({ kind: "contextEdit", preview: `Model context edit: ${target}` });
    expect(historyEntry(manager, "runtime", edit, 0).text).toBe(`Target entry: ${target}\n\nReplacement: {"content":"Sanitized request"}`);
  });

  it("keeps full large authored text reachable with Unicode-safe bounded chunks and metadata separate", () => {
    const manager = SessionManager.inMemory("/fixture");
    const content = "x".repeat(HISTORY_TEXT_CHARS - 1) + "😀\n" + "Full message\n".repeat(25_000) + "last-authored-line";
    const id = manager.appendMessage({ role: "user", content, timestamp: 0 });
    let offset = 0;
    let restored = "";
    do {
      const page = historyEntry(manager, "runtime", id, offset);
      expect(page.text.length).toBeLessThanOrEqual(HISTORY_TEXT_CHARS);
      expect(page.text).not.toContain("�");
      expect(page.metadata).toMatchObject({ role: "user", entryId: id });
      expect(page.text).not.toContain('"entryId"');
      restored += page.text;
      if (page.previousOffset !== undefined) {
        expect(page.previousOffset).toBeLessThan(offset);
        expect(historyEntry(manager, "runtime", id, page.previousOffset).text).not.toContain("�");
      }
      if (page.nextOffset === undefined) break;
      offset = page.nextOffset;
    } while (true);
    expect(restored).toBe(content);
    expect(restored.endsWith("last-authored-line")).toBe(true);
    expect(() => historyEntry(manager, "runtime", id, HISTORY_TEXT_CHARS)).toThrow(/Invalid/);
    expect(() => historyEntry(manager, "runtime", id, content.length + 1)).toThrow(/Invalid/);
    expect(() => historyEntry(manager, "runtime", "missing", 0)).toThrow(/no longer exists/);
  });

  it("bounds the entire detail wire payload including hostile metadata", () => {
    const manager = SessionManager.inMemory("/fixture");
    const id = manager.appendMessage({ ...fauxAssistantMessage("\u0001".repeat(400_000)),
      model: "m".repeat(400_000), errorMessage: "e".repeat(400_000) });
    const page = historyEntry(manager, "runtime", id, 0);
    expect(Buffer.byteLength(JSON.stringify(page))).toBeLessThan(180_000);
    expect(page.metadata).toMatchObject({ modelTruncated: true, errorTruncated: true });
    expect(page.nextOffset).toBe(24_000);
  });

  it("keeps compact list reads independent of huge tool arguments and custom payloads", () => {
    const manager = SessionManager.inMemory("/fixture");
    const args = { secretFixture: "x".repeat(400_000) };
    const stringify = vi.spyOn(JSON, "stringify");
    manager.appendMessage({ ...fauxAssistantMessage(""), content: [{ type: "toolCall", id: "call", name: "write", arguments: args }] });
    manager.appendCustomEntry("fixture.log", args);
    stringify.mockClear();
    const page = historyPage(manager, "runtime");
    expect(page.nodes.map(n => n.preview)).toEqual(["fixture.log", "Tool call: write"]);
    expect(stringify).toHaveBeenCalledTimes(1);
    expect(stringify).toHaveBeenCalledWith(page.nodes);
    stringify.mockRestore();
    const detail = historyEntry(manager, "runtime", page.nodes[0]!.id, 0);
    expect(detail.nextOffset).toBeDefined();
    let restored = detail.text;
    let cursor = detail.nextOffset;
    while (cursor !== undefined) {
      const next = historyEntry(manager, "runtime", page.nodes[0]!.id, cursor);
      restored += next.text;
      cursor = next.nextOffset;
    }
    expect(JSON.parse(restored)).toEqual(args);
  });
});
