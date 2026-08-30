import { describe, expect, it } from "vitest";
import { admitResourceInvocation, canonicalResourceName, parsePiLiteralCommand } from "./resource-invocation.js";

describe("resource invocation contract", () => {
  it("normalizes skill transport names without changing arguments", () => {
    expect(admitResourceInvocation({ source: "skill", name: "skill:review", arguments: "one\ntwo" }))
      .toEqual({ source: "skill", name: "review", arguments: "one\ntwo" });
    expect(canonicalResourceName("skill", "review")).toBe("skill:review");
  });

  it("accepts empty arguments and intended prompt whitespace", () => {
    expect(admitResourceInvocation({ source: "extension", name: "goal", arguments: "" }).arguments).toBe("");
    expect(admitResourceInvocation({ source: "prompt", name: "template", arguments: "a\tb\r\nc" }).arguments).toBe("a\tb\r\nc");
  });

  it("rejects controls, unknown fields, and oversized UTF-8 identity", () => {
    expect(() => admitResourceInvocation({ source: "prompt", name: "x", arguments: "bad\u0000" })).toThrow(/control/);
    expect(() => admitResourceInvocation({ source: "prompt", name: "two words", arguments: "x" })).toThrow(/whitespace/);
    expect(() => admitResourceInvocation({ source: "extension", name: "bad\nname", arguments: "x" })).toThrow(/whitespace/);
    expect(() => admitResourceInvocation({ source: "prompt", name: "x", arguments: "x", extra: true })).toThrow(/unknown/);
    expect(() => admitResourceInvocation({ source: "prompt", name: "x", arguments: "x".repeat(5_001) })).toThrow(/UTF-8/);
    expect(() => admitResourceInvocation({ source: "prompt", name: "🙂".repeat(200), arguments: "x" })).toThrow(/UTF-8/);
  });

  it("matches Pi's literal ASCII-space command delimiter", () => {
    expect(parsePiLiteralCommand("/goal value")).toEqual({ name: "goal", arguments: "value" });
    expect(parsePiLiteralCommand("/goal\tvalue")).toEqual({ name: "goal\tvalue", arguments: "" });
    expect(parsePiLiteralCommand("/goal\nvalue")).toEqual({ name: "goal\nvalue", arguments: "" });
    expect(parsePiLiteralCommand(" embedded /goal value")).toBeUndefined();
  });
});
