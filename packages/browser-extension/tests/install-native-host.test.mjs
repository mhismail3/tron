import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const installer = resolve("scripts/install-native-host.sh");

test("installer atomically writes an owner-scoped wrapper and Chrome manifest", () => {
  const root = join(tmpdir(), `tron-browser-host-test-${process.pid}`);
  rmSync(root, { recursive: true, force: true });
  mkdirSync(join(root, "home"), { recursive: true });
  const binary = join(root, "tron");
  writeFileSync(binary, "#!/bin/sh\nexit 0\n");
  chmodSync(binary, 0o700);
  const tronHome = join(root, "tron home");
  try {
    execFileSync(
      installer,
      [
        "--extension-id",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--tron-binary",
        binary,
        "--tron-home",
        tronHome,
      ],
      { env: { ...process.env, HOME: join(root, "home") } },
    );
    const wrapper = readFileSync(
      join(tronHome, "internal/browser-operator/native-host"),
      "utf8",
    );
    assert.match(wrapper, /browser-native-host --socket/);
    assert.match(wrapper, /browser-operator\.sock/);
    const manifest = JSON.parse(
      readFileSync(
        join(
          root,
          "home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.tron.browser_operator.json",
        ),
        "utf8",
      ),
    );
    assert.equal(manifest.name, "com.tron.browser_operator");
    assert.deepEqual(manifest.allowed_origins, [
      "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/",
    ]);
    assert.equal(
      manifest.path,
      join(tronHome, "internal/browser-operator/native-host"),
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("installer rejects unknown extension identities", () => {
  assert.throws(() =>
    execFileSync(
      installer,
      ["--extension-id", "not-an-extension", "--tron-binary", "/bin/true"],
      { stdio: "ignore" },
    ),
  );
});
