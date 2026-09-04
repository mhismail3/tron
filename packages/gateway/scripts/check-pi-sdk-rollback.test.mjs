import assert from "node:assert/strict";
import test from "node:test";
import { rollbackAuditCommand, rollbackInstallCommand } from "./check-pi-sdk-rollback.mjs";

test("plans exact isolated rollback install and audit commands", () => {
  assert.deepEqual(rollbackInstallCommand("0.84.1"), ["install", "--save-exact", "--ignore-scripts", "--engine-strict", "--omit=optional", "--no-audit", "--no-fund", "--registry=https://registry.npmjs.org/", "--offline=false", "@earendil-works/pi-coding-agent@0.84.1"]);
  assert.deepEqual(rollbackAuditCommand(), ["audit", "signatures", "--registry=https://registry.npmjs.org/", "--offline=false", "--prefer-online"]);
  assert.throws(() => rollbackInstallCommand("^0.84.1", "/tmp/rollback"), /exact semver/);
});
