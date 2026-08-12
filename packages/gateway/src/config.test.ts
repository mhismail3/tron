import { describe, expect, it } from "vitest";
import { isTailscaleAddress, resolveBindHost, resolveTronHome } from "./config.js";

describe("gateway configuration", () => {
  it("recognizes only Tailscale CGNAT and canonical IPv6 ranges", () => {
    expect(isTailscaleAddress("100.64.0.1")).toBe(true);
    expect(isTailscaleAddress("100.127.255.254")).toBe(true);
    expect(isTailscaleAddress("100.128.0.1")).toBe(false);
    expect(isTailscaleAddress("192.168.1.2")).toBe(false);
    expect(isTailscaleAddress("fd7a:115c:a1e0::1")).toBe(true);
  });

  it("keeps explicit loopback binding and validates Tron home overrides", () => {
    expect(resolveBindHost("127.0.0.1")).toBe("127.0.0.1");
    expect(resolveTronHome({ TRON_DATA_DIR: "/tmp/tron-home" })).toBe("/tmp/tron-home");
    expect(() => resolveTronHome({ TRON_DATA_DIR: "relative" })).toThrow(/absolute/);
  });
});
