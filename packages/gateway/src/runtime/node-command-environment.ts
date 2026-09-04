import { accessSync, constants, lstatSync, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

const MAX_PATH_BYTES = 64 * 1024;
const PACKAGE_JSON_MAX_BYTES = 64 * 1024;
const SUPPORTED_ARCHITECTURES = new Map<string, "arm64" | "x64">([
  ["arm64", "arm64"],
  ["x64", "x64"],
  ["x86_64", "x64"],
]);

export interface NodeCommandEnvironmentOptions {
  environment?: NodeJS.ProcessEnv;
  architecture?: string;
  execPath?: string;
  entryPoint?: string;
}

export interface NodeCommandEnvironmentResult {
  managed: boolean;
  runtimeAliasDirectory?: string;
  piCommandPath?: string;
  path?: string;
}

function fail(message: string): never {
  throw new Error(`Supervised Gateway Node runtime contract failed: ${message}`);
}

function sameFile(left: string, right: string): boolean {
  const leftInfo = statSync(left);
  const rightInfo = statSync(right);
  return leftInfo.dev === rightInfo.dev && leftInfo.ino === rightInfo.ino;
}

function executable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function pathNode(pathValue: string | undefined): string | undefined {
  for (const component of (pathValue ?? "").split(":")) {
    if (!component) continue;
    const candidate = join(component, "node");
    try {
      const info = statSync(candidate);
      if (info.isFile() && executable(candidate)) return candidate;
    } catch {
      // Continue through PATH exactly as command lookup would.
    }
  }
  return undefined;
}

function pathIdentity(component: string): string {
  try {
    return realpathSync(component);
  } catch {
    return resolve(component);
  }
}

function normalizedPath(pathValue: string | undefined, aliasDirectory: string, channel: "stable" | "dev"): string {
  if (Buffer.byteLength(pathValue ?? "") > MAX_PATH_BYTES) fail("PATH is oversized");
  const alias = realpathSync(aliasDirectory);
  const components = (pathValue ?? "")
    .split(":")
    .filter((component) => component.length > 0 && pathIdentity(component) !== alias);
  const developerNode = channel === "dev" ? pathNode(components.join(":")) : undefined;
  const ordered = channel === "stable" || !developerNode
    ? [alias, ...components]
    : [...components, alias];
  const value = ordered.join(":");
  if (!value || Buffer.byteLength(value) > MAX_PATH_BYTES) fail("normalized PATH is empty or oversized");
  return value;
}

/**
 * Establish the supervised payload's Node command before any extension package
 * is discovered. The launcher remains the payload identity authority; this
 * function validates and activates the architecture-specific immutable alias.
 */
function configureValidatedNodeCommandEnvironment(
  options: NodeCommandEnvironmentOptions,
): NodeCommandEnvironmentResult {
  const environment = options.environment ?? process.env;
  if (environment.TRON_GATEWAY_SUPERVISED !== "1") return { managed: false };

  const payloadInput = environment.TRON_GATEWAY_PAYLOAD_ROOT;
  if (!payloadInput || !isAbsolute(payloadInput)) fail("TRON_GATEWAY_PAYLOAD_ROOT is missing or relative");
  const payloadLinkInfo = lstatSync(payloadInput);
  if (!payloadLinkInfo.isDirectory() || payloadLinkInfo.isSymbolicLink()) fail("payload root is not a regular directory");
  const payloadRoot = realpathSync(payloadInput);
  const expectedEntryPointPath = join(payloadRoot, "app", "dist", "index.js");
  const expectedEntryPointInfo = lstatSync(expectedEntryPointPath);
  if (!expectedEntryPointInfo.isFile() || expectedEntryPointInfo.isSymbolicLink()) fail("payload entrypoint is not a regular file");
  const expectedEntryPoint = realpathSync(expectedEntryPointPath);
  if (!expectedEntryPoint.startsWith(`${payloadRoot}/`)) fail("payload entrypoint escapes the selected payload");
  const entryPoint = options.entryPoint ?? process.argv[1];
  // Supervision markers are inherited by ordinary child processes. Activate
  // this process-wide contract only for the selected payload's Gateway entry,
  // never for a source CLI/test process that inherited the parent environment.
  if (!entryPoint || realpathSync(entryPoint) !== expectedEntryPoint) return { managed: false };

  const architecture = SUPPORTED_ARCHITECTURES.get(options.architecture ?? process.arch);
  if (!architecture) fail(`unsupported architecture '${options.architecture ?? process.arch}'`);
  const channelValue = environment.TRON_GATEWAY_CHANNEL?.trim() || "stable";
  if (channelValue !== "stable" && channelValue !== "dev") fail(`unsupported channel '${channelValue}'`);

  const runtimePath = join(payloadRoot, "runtime", `node-${architecture}`);
  const aliasDirectory = join(payloadRoot, "runtime", `bin-${architecture}`);
  const aliasPath = join(aliasDirectory, "node");
  const expectedTarget = `../node-${architecture}`;
  const piNodeModulesRoot = join(payloadRoot, "app", "node_modules");
  const piCliPath = join(piNodeModulesRoot, ".bin", "pi");
  const piPackageRoot = join(piNodeModulesRoot, "@earendil-works", "pi-coding-agent");
  const piAliasPath = join(aliasDirectory, "pi");
  const expectedPiTarget = "../../app/node_modules/.bin/pi";

  const aliasDirectoryInfo = lstatSync(aliasDirectory);
  if (!aliasDirectoryInfo.isDirectory() || aliasDirectoryInfo.isSymbolicLink()) fail("runtime alias directory is not regular");
  const aliasInfo = lstatSync(aliasPath);
  if (!aliasInfo.isSymbolicLink()) fail("runtime node alias is not a symbolic link");
  if (readlinkSync(aliasPath) !== expectedTarget) fail("runtime node alias has the wrong target");

  const resolvedRuntime = realpathSync(runtimePath);
  const resolvedAlias = realpathSync(aliasPath);
  const resolvedExecPath = realpathSync(options.execPath ?? process.execPath);
  if (!resolvedRuntime.startsWith(`${payloadRoot}/`) || resolvedAlias !== resolvedRuntime) fail("runtime node alias does not resolve to the selected payload runtime");
  const runtimeInfo = lstatSync(runtimePath);
  if (!runtimeInfo.isFile() || runtimeInfo.isSymbolicLink() || !executable(runtimePath)) fail("selected payload runtime is not a regular executable");
  if (!sameFile(resolvedRuntime, resolvedExecPath)) fail("selected payload runtime does not match the running executable");

  const piNodeModulesInfo = lstatSync(piNodeModulesRoot);
  const piPackageInfo = lstatSync(piPackageRoot);
  const piCliInfo = lstatSync(piCliPath);
  const piAliasInfo = lstatSync(piAliasPath);
  if (!piNodeModulesInfo.isDirectory() || piNodeModulesInfo.isSymbolicLink()
    || !piPackageInfo.isDirectory() || piPackageInfo.isSymbolicLink()
    || !piCliInfo.isSymbolicLink() || !executable(piCliPath)) fail("selected payload npm Pi projection or package root is not regular");
  if (!piAliasInfo.isSymbolicLink() || readlinkSync(piAliasPath) !== expectedPiTarget) fail("runtime Pi alias has the wrong target");
  let declaredBin: unknown;
  try {
    const packageJsonPath = join(piPackageRoot, "package.json");
    const packageJsonInfo = lstatSync(packageJsonPath);
    if (!packageJsonInfo.isFile() || packageJsonInfo.isSymbolicLink() || packageJsonInfo.size > PACKAGE_JSON_MAX_BYTES) {
      fail("selected pi-coding-agent package metadata is missing, substituted, or oversized");
    }
    const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8")) as { bin?: unknown };
    declaredBin = typeof packageJson.bin === "object" && packageJson.bin !== null
      ? (packageJson.bin as { pi?: unknown }).pi : undefined;
  } catch { fail("selected pi-coding-agent package metadata is missing or invalid"); }
  if (typeof declaredBin !== "string" || !declaredBin || isAbsolute(declaredBin) || declaredBin.split(/[\\/]/u).includes("..")) {
    fail("selected pi-coding-agent bin.pi is unsafe or missing");
  }
  const resolvedApp = realpathSync(join(payloadRoot, "app"));
  const resolvedNodeModules = realpathSync(piNodeModulesRoot);
  const resolvedPackageRoot = realpathSync(piPackageRoot);
  const resolvedDeclaredBin = realpathSync(join(piPackageRoot, declaredBin));
  const resolvedPiCli = realpathSync(piCliPath);
  const resolvedPiAlias = realpathSync(piAliasPath);
  const declaredInfo = lstatSync(join(piPackageRoot, declaredBin));
  if (!resolvedNodeModules.startsWith(`${resolvedApp}/`) || !resolvedPackageRoot.startsWith(`${resolvedNodeModules}/`)
    || !resolvedPiCli.startsWith(`${resolvedPackageRoot}/`) || readlinkSync(piCliPath) !== relative(dirname(piCliPath), join(piPackageRoot, declaredBin))
    || resolvedDeclaredBin !== resolvedPiCli || !declaredInfo.isFile() || declaredInfo.isSymbolicLink()
    || resolvedPiAlias !== resolvedPiCli || !sameFile(resolvedPiAlias, resolvedPiCli)) {
    fail("runtime Pi alias does not resolve to the declared npm Pi projection");
  }

  const path = normalizedPath(environment.PATH, aliasDirectory, channelValue);
  environment.PATH = path;
  return { managed: true, runtimeAliasDirectory: aliasDirectory, piCommandPath: piAliasPath, path };
}

export function configureSupervisedNodeCommandEnvironment(
  options: NodeCommandEnvironmentOptions = {},
): NodeCommandEnvironmentResult {
  try {
    return configureValidatedNodeCommandEnvironment(options);
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("Supervised Gateway Node runtime contract failed:")) throw error;
    const detail = error instanceof Error ? error.message.slice(0, 512) : String(error).slice(0, 512);
    fail(`runtime alias validation could not complete: ${detail}`);
  }
}
