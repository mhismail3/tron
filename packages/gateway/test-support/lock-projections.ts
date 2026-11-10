import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect } from "vitest";
import { withoutSharedToolSchemas } from "./scenario-lock.js";

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

function requestShape(request: { tools?: unknown; promptSections?: unknown; promptHash?: unknown }): string | undefined {
  return Object.entries(SHAPES).find(([, shape]) => isShape(shape) && shape.promptHash === request.promptHash
    && same(shape.tools, request.tools) && same(shape.promptSections, request.promptSections))?.[0];
}

function systemShape(message: { sections: Record<string, unknown>; toolsAdded?: unknown }): string | undefined {
  for (const [name, shape] of Object.entries(SHAPES)) {
    const entries = isShape(shape) ? shape.system ?? [] : shape ?? [];
    const index = entries.findIndex((entry) => same(withoutCwd(entry.sections), withoutCwd(message.sections)) && same(entry.toolsAdded, message.toolsAdded ?? null));
    if (index >= 0) return `${name}#${index}`;
  }
  return undefined;
}

export function expectRequestShapes(requests: readonly unknown[], shapes: readonly string[]): void {
  expect(requests.map((request) => requestShape(request as { tools?: unknown; promptSections?: unknown; promptHash?: unknown })),
    "each provider request's session shape").toEqual(shapes);
}

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
