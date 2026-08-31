import {
  recordIosDeviceInstallHelperFailure,
  runIosDeviceInstallHelper,
} from "./ios-device-install-service.js";

function option(name: string): string {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

let input: { tronHome: string; deviceId: string; commandId: string } | undefined;
try {
  input = {
    tronHome: option("--tron-home"),
    deviceId: option("--device-id"),
    commandId: option("--command-id"),
  };
  await runIosDeviceInstallHelper(input);
} catch (error) {
  if (input) {
    await recordIosDeviceInstallHelperFailure(
      input.tronHome,
      input.deviceId,
      input.commandId,
      error,
    ).catch(() => {});
  }
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
