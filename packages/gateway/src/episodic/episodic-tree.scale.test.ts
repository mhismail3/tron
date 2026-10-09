import { runInNewContext } from "node:vm";
import { setFlagsFromString } from "node:v8";
import { expect, it } from "vitest";
import { EPISODIC_DEFAULTS } from "./episodic-contract.js";
import { capText } from "./episodic-tree.js";

/*
 * Retention of capped text, run by `npm run test:scale`. The production projection
 * path is measured in `home-source.scale.test.ts`; this test targets `capText`
 * itself, because that path's redaction pass flattens the capped string and would
 * hide a slice of the source.
 */

it("keeps the capped text of a message from retaining its source", () => {
  setFlagsFromString("--expose_gc");
  const collect = runInNewContext("gc") as () => void;
  const messages = 20;
  const sourceChars = 2 * 1024 * 1024;
  const cap = EPISODIC_DEFAULTS.recordCapChars;
  const kept: string[] = [];
  collect(); collect();
  const baseline = process.memoryUsage().heapUsed;
  for (let index = 0; index < messages; index += 1) {
    // A parsed canonical line yields a string that nothing else references.
    const source = JSON.parse(JSON.stringify({ text: `message ${index} ` + "x".repeat(sourceChars) })).text as string;
    kept.push(capText(source, cap, EPISODIC_DEFAULTS.capTailChars).text);
  }
  collect(); collect();
  const retainedPerMessage = (process.memoryUsage().heapUsed - baseline) / messages;
  expect(kept[0]).toContain("[truncated");
  // The kept text is about `cap` characters. Its marker is not ASCII, so the string
  // is two bytes per character: about 256 KB. A retained source would be 2 MB.
  expect(retainedPerMessage).toBeLessThan(2 * cap * 2 + 256 * 1024);
  console.log(`episodic capText retained bytes per ${sourceChars}-character message: ${Math.round(retainedPerMessage)}`);
});
