import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { DISPOSABLE_READ_METHODS } from "./server.js";

const IOS_POLICY = new URL("../../../ios-app/Core/Gateway/GatewayProtocol.swift", import.meta.url);

describe("disposable-read cancel contract", () => {
  it("the phone cancels exactly the reads the Gateway can cancel", async () => {
    const source = await readFile(IOS_POLICY, "utf8");
    const literal = /static let disposableReadMethods: Set<String> = \[([^\]]*)\]/u.exec(source);
    expect(literal, "GatewayDisposableReadPolicy.disposableReadMethods literal").not.toBeNull();
    const phone = [...literal![1]!.matchAll(/"([^"]+)"/gu)].map(match => match[1]!).sort();
    expect(phone).toEqual([...DISPOSABLE_READ_METHODS].sort());
  });
});
