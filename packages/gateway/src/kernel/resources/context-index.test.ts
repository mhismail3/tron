import { expect, it } from "vitest";
import { renderIndex } from "./context-index.js";

it("keeps whole sorted rows within the budget and points to the rest only when a listing locator exists", () => {
  const items = ["c", "a", "b"].map(id => ({ id, description: `Item ${id} <x>`, locator: `open ${id}` }));
  const index = { name: "fixture", open: "read", kind: "data" as const, items, budget: 140 };
  const listed = renderIndex(index, "list all");
  expect(listed.text).toBe('<index name="fixture" open="read" kind="data">\n- a: Item a &lt;x&gt; | open a\n- more: List the remaining items. | list all\n</index>');
  expect(Buffer.byteLength(listed.text)).toBeLessThanOrEqual(140);
  const full = renderIndex(index);
  expect(full.text.split("\n").slice(1, -1)).toEqual(["- a: Item a &lt;x&gt; | open a", "- b: Item b &lt;x&gt; | open b", "- c: Item c &lt;x&gt; | open c"]);
  expect(full.diagnostics).toEqual(["fixture: index exceeds 140 bytes"]);
});
