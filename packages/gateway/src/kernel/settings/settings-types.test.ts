import { describe, expect, it } from "vitest";
import { toolSelectionType } from "./settings-types.js";

/**
 * What a tool selection's compose and encode return. Proof block settings/tool-selection decides them over
 * tokens; these cases pin the names around it: entries read as plain names or +name/-name modifiers, the result
 * written back as the same names in the block's order, and stored values that are not lists of strings failing
 * or passing exactly where they did.
 */
const type = toolSelectionType();
const compose = (below: unknown, entries: unknown) => type.compose!(below, entries);
const encode = (chosen: unknown, below: unknown, current: unknown) => type.encode!(chosen, below, current);
const below = ["read", "bash", "edit"];

describe("tool selection", () => {
  it("composes modifiers over the selection below, and over pi's defaults when nothing lies below", () => {
    expect(compose(below, ["+web", "-bash", "+ls"])).toEqual(["read", "edit", "web", "ls"]);
    expect(compose(undefined, ["-read"])).toEqual(["bash", "edit", "write"]);
    expect(compose("not a list", ["+web"])).toEqual(["read", "bash", "edit", "write", "web"]);
    // A tool already listed is not added again, a missing one is not removed, and an empty name adds nothing.
    expect(compose(below, ["+bash", "-web", "+"])).toEqual(["read", "bash", "edit"]);
    // Modifiers apply in order: the last one named wins.
    expect(compose(below, ["-bash", "+bash"])).toEqual(["read", "edit", "bash"]);
    expect(compose(below, ["+web", "-web"])).toEqual(["read", "bash", "edit"]);
    // Only the first of a repeated tool is removed.
    expect(compose(["read", "bash", "read"], ["-read"])).toEqual(["bash", "read"]);
  });

  it("lets plain names replace what lies below, with the layer's own modifiers applied to them", () => {
    expect(compose(below, ["grep", "find"])).toEqual(["grep", "find"]);
    expect(compose(below, ["grep", "+read", "-grep", "find"])).toEqual(["find", "read"]);
    expect(compose(below, ["read", "read"])).toEqual(["read", "read"]);
    expect(compose(below, [])).toEqual([]);
    expect(compose(undefined, [])).toEqual([]);
  });

  it("returns a new list and leaves its inputs as they were", () => {
    const base = ["read", "bash"];
    const entries = ["+web"];
    const composed = compose(base, entries);
    expect(composed).toEqual(["read", "bash", "web"]);
    expect([base, entries]).toEqual([["read", "bash"], ["+web"]]);
    expect(compose(base, ["-web"])).not.toBe(base);
  });

  it("stores a choice relative to what lies below when the layer is relative and modifiers reproduce it", () => {
    expect(encode(["read", "edit", "web"], below, ["+ls"])).toEqual(["+web", "-bash"]);
    expect(encode(["read", "edit", "web"], below, undefined)).toEqual(["+web", "-bash"]);
    expect(encode(["bash", "edit", "write", "web"], undefined, [])).toEqual(["+web", "-read"]);
    // The same selection as below: nothing is stored.
    expect(encode(["read", "bash", "edit"], below, ["+web"])).toBeUndefined();
    expect(encode(["read", "bash", "edit", "write"], undefined, undefined)).toBeUndefined();
  });

  it("stores a choice as it is when it holds a modifier, when the layer holds a plain name, or when its order cannot be reproduced", () => {
    expect(encode(["+web"], below, [])).toEqual(["+web"]);
    expect(encode(["read", "-bash"], below, ["grep"])).toEqual(["read", "-bash"]);
    expect(encode(["read", "bash"], below, ["grep"])).toEqual(["read", "bash"]);
    expect(encode(["read", "bash"], below, ["+web", "grep"])).toEqual(["read", "bash"]);
    expect(encode(["edit", "read", "web"], below, ["+ls"])).toEqual(["edit", "read", "web"]);
    expect(encode([], below, [])).toEqual(["-read", "-bash", "-edit"]);
    expect(encode([], [], [])).toBeUndefined();
  });

  it("treats a stored value that is not a list of strings as it always has", () => {
    // What lies below passes through by identity, whatever it holds.
    expect(compose(["read", 5], ["+web"])).toEqual(["read", 5, "web"]);
    // Entries must be strings.
    for (const entries of ["read", 5, null, undefined, {}, [5], ["read", 5], ["+web", 5]]) expect(() => compose(below, entries)).toThrow(TypeError);
    // What the layer holds now is read only for a choice of plain names, and only up to its first plain name.
    expect(encode(["+web"], below, [7])).toEqual(["+web"]);
    expect(encode(["read"], below, ["bash", 7])).toEqual(["read"]);
    expect(encode(["read"], below, "not a list")).toEqual(["-bash", "-edit"]);
    expect(() => encode(["read"], below, ["+web", 7])).toThrow(TypeError);
    expect(() => encode(["read"], below, [7])).toThrow(TypeError);
  });
});
