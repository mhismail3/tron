#!/usr/bin/env node

import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { authenticatedRequest, readLocalCredential, resolveDeploymentHost } from "./gateway-payload-deploy.mjs";

const USAGE = `Usage:
  scripts/tron-ios-device-bind.mjs --list [options]
  scripts/tron-ios-device-bind.mjs --device-id PAIRED_ID --target-identifier COREDEVICE_ID [options]
Options: --channel stable|dev --tron-home ABSOLUTE_PATH --host tailscale|127.0.0.1 --port PORT

Configure the iOS source checkout in Settings first. This command binds a target;
it does not build, install, restart, or update the Gateway. --list lists authorized
Tron device IDs (not physical targets). Discover physical targets with xcrun devicectl list devices.`;

export function parseArguments(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const key = args[index];
    if (Object.hasOwn(options, key)) throw new Error("Duplicate option");
    if (key === "--list" || key === "--help") options[key] = true;
    else if (["--device-id", "--target-identifier", "--channel", "--tron-home", "--host", "--port"].includes(key)) {
      const value = args[++index];
      if (!value || value.startsWith("--")) throw new Error(`Missing value for ${key}`);
      options[key] = value;
    } else throw new Error("Unknown option");
  }
  if (options["--help"]) return { help: true };
  const channel = options["--channel"] ?? "stable";
  const host = options["--host"] ?? (channel === "dev" ? "127.0.0.1" : "tailscale");
  const port = Number(options["--port"] ?? (channel === "dev" ? 9848 : 9847));
  const tronHome = options["--tron-home"] ?? join(homedir(), channel === "dev" ? ".tron-dev" : ".tron");
  if (!["stable", "dev"].includes(channel) || !["tailscale", "127.0.0.1"].includes(host)
    || !isAbsolute(tronHome) || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid connection option");
  const deviceId = options["--device-id"];
  const targetIdentifier = options["--target-identifier"];
  const list = options["--list"] === true;
  if (list ? deviceId !== undefined || targetIdentifier !== undefined
    : typeof deviceId !== "string" || !/^[A-Za-z0-9._:-]{1,100}$/u.test(deviceId)
      || typeof targetIdentifier !== "string" || !/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/u.test(targetIdentifier)) {
    throw new Error("Choose --list or provide both exact device identifiers");
  }
  return { channel, host, port, tronHome, deviceId, targetIdentifier, list };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) { console.log(USAGE); return; }
  // Never send the local-wrapper credential to an arbitrary remote hostname.
  const host = resolveDeploymentHost(options.host);
  const token = await readLocalCredential(join(options.tronHome, "gateway", "local-auth.json"));
  const result = await authenticatedRequest({
    host, port: options.port, token, timeoutMs: 30_000,
    method: options.list ? "device.list" : "device.install.target.bind",
    params: options.list ? {} : {
      commandId: `ios-bind-${randomUUID()}`,
      deviceId: options.deviceId,
      targetIdentifier: options.targetIdentifier,
    },
  });
  if (options.list) {
    if (!Array.isArray(result?.devices)) throw new Error("Invalid authorized-device response");
    for (const device of result.devices) {
      console.log(JSON.stringify({ deviceId: device.id, name: device.name, createdAt: device.createdAt }));
    }
  } else {
    if (result?.deviceId !== options.deviceId || !result?.target) throw new Error("Invalid binding acknowledgement");
    console.log("Bound the selected physical device. Settings Rebuild and Install will use this exact target.");
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => { console.error(`iOS device binding failed: ${error.message}`); process.exitCode = 1; });
}
