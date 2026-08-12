import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { GATEWAY_VERSION, PI_VERSION } from "./version.js";

describe("version mirrors", () => {
  it("matches the package and exact backing runtime dependency", async () => {
    const packageDocument = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8")) as {
      version: string;
      dependencies: Record<string, string>;
    };
    expect(GATEWAY_VERSION).toBe(packageDocument.version);
    expect(PI_VERSION).toBe(packageDocument.dependencies["@earendil-works/pi-coding-agent"]);
    expect(PI_VERSION).not.toMatch(/[~^*]/);
  });
});
