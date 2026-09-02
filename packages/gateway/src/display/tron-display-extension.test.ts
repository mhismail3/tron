import { describe, expect, it } from "vitest";
import { createTronDisplayExtension } from "./tron-display-extension.js";

function fixture() {
  let tool: any;
  const ingests: unknown[] = [];
  const revokes: unknown[] = [];
  const factory = createTronDisplayExtension({
    sessionId: () => "session-a",
    cwd: () => "/workspace",
    artifacts: {
      ingest: async (...args: unknown[]) => {
        ingests.push(args);
        return {
          id: "85bff6fb-7282-4c9b-9c0c-f6d06625235a",
          name: "preview.png",
          mimeType: "image/png",
          size: 128,
          kind: "image",
        };
      },
      revoke: async (...args: unknown[]) => { revokes.push(args); },
    } as any,
  });
  factory({ registerTool(value: unknown) { tool = value; } } as any);
  return { tool: () => tool, ingests, revokes };
}

describe("first-party Tron display extension", () => {
  it("registers a strict sequential tool and returns a canonical typed artifact descriptor", async () => {
    const value = fixture();
    const tool = value.tool();
    expect(tool.name).toBe("display");
    expect(tool.executionMode).toBe("sequential");
    expect(tool.parameters.additionalProperties).toBe(false);
    const result = await tool.execute("call", {
      title: "Preview",
      altText: "A preview image.",
      fallbackText: "Preview unavailable.",
      source: { kind: "path", path: "preview.png" },
      presentation: { surface: "floating", inlineTapAction: "sheet" },
    });
    expect(value.ingests).toEqual([["/workspace", "preview.png", "session-a"]]);
    expect(result.details.display).toMatchObject({
      schema: "tron.display.v1",
      revision: 1,
      kind: "image",
      presentation: { requestedSurface: "floating", inlineTapAction: "sheet" },
      eligibleSurfaces: ["sheet", "inline", "floating"],
      fallbackText: "Preview unavailable.",
      artifact: { id: "85bff6fb-7282-4c9b-9c0c-f6d06625235a" },
    });
  });

  it("accepts only public credential-free HTTPS URL descriptors", async () => {
    const value = fixture();
    const result = await value.tool().execute("call", {
      title: "Docs",
      altText: "Documentation webpage.",
      source: { kind: "public_url", url: "https://example.com/docs", media: "webpage" },
    });
    expect(result.details.display).toMatchObject({
      kind: "webpage",
      remoteURL: "https://example.com/docs",
      eligibleSurfaces: ["sheet"],
      presentation: { requestedSurface: "sheet" },
    });
    for (const url of [
      "https://user:secret@example.com",
      "https://[fc00::1]/page",
      "https://example.com/page?token=secret",
    ]) {
      await expect(value.tool().execute("call", {
        title: "Unsafe",
        altText: "Unsafe page.",
        source: { kind: "public_url", url, media: "webpage" },
      })).rejects.toMatchObject({ code: "invalid_request" });
    }
  });

  it("revokes a published artifact when cancellation wins before the result is returned", async () => {
    let tool: any;
    const controller = new AbortController();
    const revokes: unknown[] = [];
    const factory = createTronDisplayExtension({
      sessionId: () => "session-a",
      cwd: () => "/workspace",
      artifacts: {
        ingest: async () => {
          controller.abort();
          return {
            id: "85bff6fb-7282-4c9b-9c0c-f6d06625235a",
            name: "preview.png",
            mimeType: "image/png",
            size: 128,
            kind: "image",
          };
        },
        revoke: async (...args: unknown[]) => { revokes.push(args); },
      } as any,
    });
    factory({ registerTool(value: unknown) { tool = value; } } as any);
    await expect(tool.execute("call", {
      title: "Preview",
      altText: "A preview image.",
      source: { kind: "path", path: "preview.png" },
    }, controller.signal)).rejects.toThrow("Display operation aborted");
    expect(revokes).toEqual([["85bff6fb-7282-4c9b-9c0c-f6d06625235a", "session-a"]]);
  });

  it("rejects control characters and byte-oversized multibyte text before publication", async () => {
    const value = fixture();
    await expect(value.tool().execute("call", {
      title: "line\nbreak",
      altText: "Description",
      source: { kind: "path", path: "preview.png" },
    })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(value.tool().execute("call", {
      title: "é".repeat(200),
      altText: "Description",
      source: { kind: "path", path: "preview.png" },
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(value.ingests).toEqual([]);
  });
});
