import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { DISPOSABLE_READ_METHODS } from "./server.js";

// The phone sends a `cancel` frame only for methods in its own policy set, and
// the Gateway honours a `cancel` frame only for methods in DISPOSABLE_READ_METHODS.
// A method in the Gateway set but missing on the phone is never cancelled: the
// Gateway finishes work nobody waits for (`projects.list` ran to completion
// 42 s after the phone gave up). The Swift set has no reader that can run here,
// so this contract check reads its literal.
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
