import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect } from "vitest";
import { withoutSharedToolSchemas } from "./scenario-lock.js";

/**
 * A behavior lock's inline expectation (#2279). The lock builds the same trace the
 * harness normalizes (`scenario-lock.ts`: per-run identities, times and token
 * counts become `<id>`, `<timestamp>`, `<value>`) and compares it exactly with its
 * expectation, so a changed response, transcript row, canonical entry, receipt,
 * provider conversation or observed state fails it. Two parts have one owner each
 * and are checked here by reference: client event schemas (`client-event-schemas`)
 * leave the trace, and each provider request's tools, prompt sections and prompt
 * hash, and each system entry's prompt sections and tools, must equal a session
 * shape in `session-shapes`, named in the expectation as `{ sessionShape }`.
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
const withoutCwd = (sections: Record<string, unknown>) => Object.fromEntries(Object.entries(sections).filter(([key]) => key !== "cwd"));

/** The session shape a provider request matches, by tools, prompt sections and prompt hash. */
function requestShape(request: { tools?: unknown; promptSections?: unknown; promptHash?: unknown }): string | undefined {
  return Object.entries(SHAPES).find(([, shape]) => !Array.isArray(shape) && shape.promptHash === request.promptHash
    && same(shape.tools, request.tools) && same(shape.promptSections, request.promptSections))?.[0];
}

/** The session shape (and entry index) a canonical system entry matches, by its sections other than `cwd` and its tools. */
function systemShape(message: { sections: Record<string, unknown>; toolsAdded?: unknown }): string | undefined {
  for (const [name, shape] of Object.entries(SHAPES)) {
    const entries = Array.isArray(shape) ? shape : shape.system ?? [];
    const index = entries.findIndex((entry) => same(withoutCwd(entry.sections), withoutCwd(message.sections)) && same(entry.toolsAdded, message.toolsAdded ?? null));
    if (index >= 0) return `${name}#${index}`;
  }
  return undefined;
}

/** The trace with its model-visible parts replaced by the session shape each one equals (unmatched parts stay, and fail). */
export function shapeReferenced(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(shapeReferenced);
  if (value === null || typeof value !== "object") return value;
  const record = value as Record<string, unknown>;
  if (typeof record.promptHash === "string" && Array.isArray(record.tools) && Array.isArray(record.promptSections)) {
    const name = requestShape(record);
    if (name !== undefined) {
      const { tools: _tools, promptSections: _sections, promptHash: _hash, ...rest } = record;
      return { sessionShape: name, ...(shapeReferenced(rest) as Record<string, unknown>) };
    }
  }
  if (record.role === "system" && record.sections !== null && typeof record.sections === "object") {
    const name = systemShape(record as { sections: Record<string, unknown>; toolsAdded?: unknown });
    if (name !== undefined) {
      const { sections, toolsAdded: _tools, ...rest } = record as { sections: Record<string, unknown> } & Record<string, unknown>;
      return { ...(shapeReferenced(rest) as Record<string, unknown>), sections: { cwd: sections.cwd, sessionShape: name } };
    }
  }
  return Object.fromEntries(Object.entries(record).map(([key, child]) => [key, shapeReferenced(child)]));
}

/**
 * Assert a lock's normalized trace exactly against its expectation, without its
 * event schemas and with its model-visible parts checked against `session-shapes`.
 */
export function expectScenario(trace: Record<string, unknown>, expected: unknown): void {
  const { events: _events, ...rest } = trace;
  expect(shapeReferenced(withoutSharedToolSchemas(JSON.parse(JSON.stringify(rest)))), `${String(trace.lock)}: the scenario's trace`).toEqual(expected);
}
