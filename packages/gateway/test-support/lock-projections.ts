import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect } from "vitest";
import { withoutSharedToolSchemas } from "./scenario-lock.js";

/**
 * Session-shape references for behavior locks (#2279). Each provider request's
 * tools, prompt sections and prompt hash, and each system entry's prompt sections
 * and tools, must equal a session shape in `session-shapes`; a lock asserts the
 * ordered shape names instead of repeating those model-visible parts.
 */

interface SessionShape {
  readonly tools: readonly string[];
  readonly promptSections: readonly string[];
  readonly promptHash: string;
  readonly system?: ReadonlyArray<{ sections: Record<string, unknown>; toolsAdded: unknown }>;
}

const SHAPES = (JSON.parse(readFileSync(resolve(import.meta.dirname, "..", "test-fixtures", "pi-sdk", "session-shapes.golden.json"), "utf8")) as {
  shapes: Record<string, SessionShape | SessionShape["system"]>;
}).shapes;

const same = (left: unknown, right: unknown) => JSON.stringify(left) === JSON.stringify(right);
const isShape = (entry: SessionShape | SessionShape["system"]): entry is SessionShape => entry !== undefined && !Array.isArray(entry);
const withoutCwd = (sections: Record<string, unknown>) => Object.fromEntries(Object.entries(sections).filter(([key]) => key !== "cwd"));

/** The session shape a provider request matches, by tools, prompt sections and prompt hash. */
function requestShape(request: { tools?: unknown; promptSections?: unknown; promptHash?: unknown }): string | undefined {
  return Object.entries(SHAPES).find(([, shape]) => isShape(shape) && shape.promptHash === request.promptHash
    && same(shape.tools, request.tools) && same(shape.promptSections, request.promptSections))?.[0];
}

/** The session shape (and entry index) a canonical system entry matches, by its sections other than `cwd` and its tools. */
function systemShape(message: { sections: Record<string, unknown>; toolsAdded?: unknown }): string | undefined {
  for (const [name, shape] of Object.entries(SHAPES)) {
    const entries = isShape(shape) ? shape.system ?? [] : shape ?? [];
    const index = entries.findIndex((entry) => same(withoutCwd(entry.sections), withoutCwd(message.sections)) && same(entry.toolsAdded, message.toolsAdded ?? null));
    if (index >= 0) return `${name}#${index}`;
  }
  return undefined;
}

/**
 * Assert the session shape of each provider request, in order: its tools, prompt
 * sections and prompt hash equal that `session-shapes` shape (undefined when none does).
 */
export function expectRequestShapes(requests: readonly unknown[], shapes: readonly string[]): void {
  expect(requests.map((request) => requestShape(request as { tools?: unknown; promptSections?: unknown; promptHash?: unknown })),
    "each provider request's session shape").toEqual(shapes);
}

/** Assert the session shape (and entry index) of each system entry in a normalized canonical JSONL file, in order. */
export function expectSystemShapes(canonicalJsonl: readonly unknown[], shapes: readonly string[]): void {
  const found: Array<string | undefined> = [];
  const visit = (value: unknown): void => {
    if (Array.isArray(value)) { value.forEach(visit); return; }
    if (value === null || typeof value !== "object") return;
    const record = value as Record<string, unknown>;
    if (record.role === "system" && record.sections !== null && typeof record.sections === "object") {
      found.push(systemShape(record as { sections: Record<string, unknown>; toolsAdded?: unknown }));
      return;
    }
    Object.values(record).forEach(visit);
  };
  visit(withoutSharedToolSchemas(JSON.parse(JSON.stringify(canonicalJsonl))));
  expect(found, "each system entry's session shape").toEqual(shapes);
}
