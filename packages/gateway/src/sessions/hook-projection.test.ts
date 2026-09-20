import { describe, expect, it } from "vitest";
import {
  MAX_HOOK_PROJECTION_BYTES,
  projectHookRegistrations,
  type HookProjectionExtension,
} from "./hook-projection.js";

function extension(index: number, handlers: ReadonlyMap<string, readonly unknown[]>): HookProjectionExtension {
  return {
    name: `hook-${index}.ts`,
    path: `/workspace/${"exact-".repeat(2_000)}${index}.ts`,
    resolvedPath: `/resolved/${index}.ts`,
    scope: "project",
    source: "top-level",
    origin: "top-level",
    tools: [],
    commands: [],
    handlers,
  };
}

describe("hook registration projection", () => {
  it("skips an impossible identity without hiding later identities or mixing their inventories", () => {
    const huge = "€".repeat(16_384);
    const first = { ...extension(1, new Map()), name: huge, path: huge, resolvedPath: huge, scope: huge, source: huge, origin: huge };
    const second = { ...extension(2, new Map([["session_start", [() => {}]]])), tools: ["second-tool"] };
    const result = projectHookRegistrations([first, second], []);
    expect(result.extensions).toHaveLength(1);
    expect(result.extensions[0]).toMatchObject({ name: second.name, tools: ["second-tool"], handlers: [{ event: "session_start", count: 1 }] });
    expect(result.hookInventory.extensions).toEqual({ total: 2, retained: 1, omitted: 1 });
    expect(result.hookInventory.encodedBytes).toBe(Buffer.byteLength(JSON.stringify({ extensions: result.extensions, extensionLoadErrors: result.extensionLoadErrors })));
  });
  it("retains every existing extension row and exact identity while bounding additions", () => {
    const registrations = projectHookRegistrations([
      extension(1, new Map([["session_start", [() => undefined]]])),
      extension(2, new Map()),
    ], []);

    expect(registrations.extensions).toHaveLength(2);
    expect(registrations.extensions[0]?.path).toContain("exact-exact-");
    expect(registrations.extensions[0]?.handlers).toEqual([{ event: "session_start", count: 1 }]);
    expect(registrations.hookInventory.extensions).toEqual({ total: 2, retained: 2, omitted: 0 });
  });

  it("applies one aggregate byte envelope across identity rows and load errors", () => {
    const registrations = projectHookRegistrations(
      Array.from({ length: 1_001 }, (_, index) => extension(index, new Map())),
      Array.from({ length: 1_001 }, (_, index) => ({ path: `/broken/${index}.ts`, error: "failed" })),
    );

    expect(registrations.extensions.length).toBeLessThan(1_001);
    expect(registrations.hookInventory.extensions).toEqual({
      total: 1_001,
      retained: registrations.extensions.length,
      omitted: 1_001 - registrations.extensions.length,
    });
    expect(registrations.hookInventory.handlerEvents).toEqual({ total: 0, retained: 0, omitted: 0 });
    expect(registrations.hookInventory.loadErrors.retained).toBe(registrations.extensionLoadErrors.length);
    expect(registrations.hookInventory.loadErrors.omitted).toBe(1_001 - registrations.extensionLoadErrors.length);
    expect(registrations.hookInventory.encodedBytes).toBe(
      Buffer.byteLength(JSON.stringify({
        extensions: registrations.extensions,
        extensionLoadErrors: registrations.extensionLoadErrors,
      })),
    );
    expect(registrations.hookInventory.encodedBytes).toBeLessThanOrEqual(MAX_HOOK_PROJECTION_BYTES);
  });

  it("reports handler and error omissions when the additive byte budget is full", () => {
    const handlers = new Map<string, readonly unknown[]>();
    for (let index = 0; index < 20_000; index += 1) {
      handlers.set(`event_${index}_${"x".repeat(20)}`, []);
    }
    const registrations = projectHookRegistrations(
      [extension(1, handlers)],
      Array.from({ length: 20_000 }, (_, index) => ({ path: `/broken/${index}.ts`, error: "failed" })),
    );

    expect(registrations.hookInventory.handlerEvents.omitted).toBeGreaterThan(0);
    expect(registrations.hookInventory.loadErrors.omitted).toBeGreaterThan(0);
    expect(registrations.hookInventory.encodedBytes).toBeLessThanOrEqual(MAX_HOOK_PROJECTION_BYTES);
    expect(registrations.extensions).toHaveLength(1);
    expect(registrations.extensions[0]).toMatchObject({
      name: "hook-1.ts",
      path: expect.stringContaining("exact-exact-"),
      tools: [],
      commands: [],
    });
  });

  it("omits oversized event names rather than truncating their identity", () => {
    const event = "e".repeat(16 * 1_024 + 1);
    const registrations = projectHookRegistrations(
      [extension(1, new Map([[event, []]]))],
      [],
    );

    expect(registrations.extensions[0]?.handlers).toEqual([]);
    expect(registrations.hookInventory.handlerEvents).toEqual({ total: 1, retained: 0, omitted: 1 });
    expect(registrations.hookInventory.textFieldsOmitted).toBe(1);
  });
});
