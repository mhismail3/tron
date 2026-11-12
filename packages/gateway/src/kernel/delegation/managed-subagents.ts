import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, opendirSync, readlinkSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { Worker } from "node:worker_threads";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { gunzipSync } from "node:zlib";
import { DefaultPackageManager, SettingsManager, type Extension, type ExtensionFactory, type InlineExtension, type DefaultResourceLoader, type PackageSource, type ResolvedPaths, type SourceInfo } from "../pi/coding-agent.js";
import { piExtensionAliases } from "../pi/packages.js";
import type { ModuleLog } from "../host/module-host.js";
import { GatewayError } from "../../errors.js";
import { delegatedArtifactRoot, DELEGATED_PROVIDER_ROOT_ENV } from "./delegated-provider.js";
import { managedProducerAPI, type ManagedInternalWake } from "./managed-producer.js";
import { loadSubagentCatalog } from "./subagent-catalog.js";
import { producerIdentity } from "../host/extension-registration.js";
import { withExtensionOwner } from "../host/extension-execution-context.js";
import { tronHomePath } from "../../foundation/tron-home-layout.js";

const gatewayRoot = fileURLToPath(new URL("../../..", import.meta.url));
const pin = JSON.parse(readFileSync(join(gatewayRoot, "pi-subagents-pin.json"), "utf8")) as {
  version: string; fork: { commit: string }; closure: { path: string; sha512: string };
};
export const MANAGED_SUBAGENTS_VERSION = pin.version;
export const MANAGED_SUBAGENTS_SOURCE = `tron:pi-subagents@${pin.version}#${pin.closure.sha512}`;
type Settings = ReturnType<SettingsManager["getSettings"]>;
type ManagedLoaderOptions = Required<Pick<ConstructorParameters<typeof DefaultResourceLoader>[0],
  "settingsManager" | "additionalSkillPaths" | "additionalPromptTemplatePaths" | "skillsOverride" | "promptsOverride">> & {
  extensionFactories: Exclude<InlineExtension, ExtensionFactory>[];
};

export const IGNORED_SUBAGENTS_MESSAGE = "Tron manages pi-subagents; this user declaration is ignored. Remove it with `pi remove npm:pi-subagents`.";
export function isUserSubagentsPackage(pkg: PackageSource): boolean {
  return /^npm:pi-subagents(?:@|$)/u.test(typeof pkg === "string" ? pkg : pkg.source);
}

export function managedProviderSettingsView(settings: SettingsManager): SettingsManager {
  const admitted = (pkg: PackageSource) => !isUserSubagentsPackage(pkg) && !/^npm:pi-web-access(?:@|$)/u.test(typeof pkg === "string" ? pkg : pkg.source);
  const filter = (value: Settings): Settings => ({ ...value,
    ...(value.packages ? { packages: value.packages.filter(admitted) } : {}),
  });
  const refuse = (): never => { throw new GatewayError("conflict", "Managed provider settings view is read-only for packages"); };
  return new Proxy(settings, {
    get(target, key) {
      if (key === "getPackages") return () => target.getPackages().filter(admitted);
      if (key === "getSettings" || key === "getGlobalSettings" || key === "getProjectSettings") return () => filter(target[key]());
      if (key === "setPackages" || key === "setProjectPackages") return refuse;
      if (key === "applyOverrides") return (value: Partial<Settings>) => {
        if (Object.hasOwn(value, "packages")) refuse();
        target.applyOverrides(value);
      };
      const value = Reflect.get(target, key, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

const receiptName = "tron-install-receipt.json";
const managedExtensions = new WeakSet<Extension>();
export function isManagedSubagentExtension(extension: Extension): boolean { return managedExtensions.has(extension); }

interface RequiredChildApi {
  registerRequiredChildExtensions?: (input: { sessionId: string; extensions: readonly { id: string; path: string }[] }) => { dispose(): void };
}
interface Entry { name: string; type: string; bytes: Buffer; target: string; mode: number; }
interface JitiOptions { moduleCache: boolean; alias: Record<string, string>; fsCache: string }
type JitiFactory = (base: string, options: JitiOptions) => { import: (path: string, options: { default?: true }) => Promise<unknown> };

const TRANSFORM_CACHE_WORKER = `
const { parentPort, workerData } = require("node:worker_threads");
const { existsSync, readdirSync, readFileSync, statSync } = require("node:fs");
const { dirname, join, relative, resolve, sep } = require("node:path");
const typescript = (path) => /\\.[cm]?tsx?$/.test(path) && !/\\.d\\.[cm]?tsx?$/.test(path);
const ownModule = (path) => {
  const inside = relative(workerData.root, path);
  return inside && !inside.startsWith("..") && !inside.split(sep).includes("node_modules");
};
const specifiers = (source) => [
  ...source.matchAll(/(?:^|[;}\\n])\\s*(?:import|export)\\s+(?!type\\s)(?:[^'";]*?\\sfrom\\s*)?["']([^"']+)["']/g),
  ...source.matchAll(/(?<!typeof\\s)\\bimport\\(\\s*["']([^"']+)["']\\s*\\)/g),
].map((match) => match[1]);
const resolveModule = (from, specifier) => {
  if (!specifier.startsWith(".")) return undefined;
  const base = resolve(dirname(from), specifier);
  for (const candidate of [base, base.replace(/\\.js$/, ".ts"), base + ".ts", join(base, "index.ts")]) {
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }
  return undefined;
};
(async () => {
  const { createJiti } = await import(workerData.jitiUrl);
  const jiti = createJiti(workerData.base, workerData.jiti);
  // jiti silently disables an unwritable cache; nothing would then be prepared.
  if (!jiti.options.fsCache) throw new Error("transform cache is not writable");
  const transform = (path, source) => jiti.transform({ filename: path, source, ts: true, async: true, jsx: jiti.options.jsx });
  if (!workerData.entries) {
    const visit = (directory) => {
      for (const item of readdirSync(directory, { withFileTypes: true })) {
        const path = join(directory, item.name);
        if (item.isDirectory() && item.name !== "node_modules") visit(path);
        else if (item.isFile() && typescript(item.name)) transform(path, readFileSync(path, "utf8"));
      }
    };
    visit(workerData.root);
    return;
  }
  const pending = workerData.entries.map((entry) => resolveModule(entry, "./" + entry.split(sep).pop())).filter(Boolean);
  const seen = new Set();
  while (pending.length) {
    const path = pending.pop();
    if (seen.has(path) || !ownModule(path) || !typescript(path)) continue;
    seen.add(path);
    const source = readFileSync(path, "utf8");
    transform(path, source);
    for (const specifier of specifiers(source)) {
      const dependency = resolveModule(path, specifier);
      if (dependency) pending.push(dependency);
    }
  }
})().then(() => parentPort.postMessage({}), (error) => parentPort.postMessage({ error: String(error && error.message || error) }));
`;

let decodedClosure: { key: string; entries: Entry[] } | undefined;

function closureEntries(): Entry[] {
  const archivePath = join(gatewayRoot, pin.closure.path);
  const metadata = lstatSync(archivePath, { bigint: true });
  if (!metadata.isFile() || metadata.size > 64n * 1024n * 1024n) throw new GatewayError("conflict", "invalid managed pi-subagents closure file");
  const key = [archivePath, pin.closure.sha512, metadata.dev, metadata.ino, metadata.size, metadata.mtimeNs, metadata.ctimeNs].join("\0");
  if (decodedClosure?.key !== key) decodedClosure = { key, entries: decodeClosure(archivePath) };
  return decodedClosure.entries;
}

function decodeClosure(archivePath: string): Entry[] {
  const archive = readFileSync(archivePath);
  if (createHash("sha512").update(archive).digest("hex") !== pin.closure.sha512) {
    throw new GatewayError("conflict", "managed pi-subagents closure SHA-512 mismatch");
  }
  const tar = gunzipSync(archive, { maxOutputLength: 64 * 1024 * 1024 });
  const entries: Entry[] = [];
  const names = new Set<string>();
  const text = (offset: number, length: number) => tar.subarray(offset, offset + length).toString().replace(/\0.*$/su, "");
  for (let offset = 0; offset + 512 <= tar.length;) {
    if (tar.subarray(offset, offset + 512).every((byte) => byte === 0)) break;
    const prefix = text(offset + 345, 155);
    const path = `${prefix ? `${prefix}/` : ""}${text(offset, 100)}`.replace(/\/$/u, "");
    const size = parseInt(text(offset + 124, 12).trim() || "0", 8);
    const type = text(offset + 156, 1) || "0";
    const name = path.slice("package/".length);
    if (path !== "package" && (!path.startsWith("package/") || !name || name.split("/").some((part) => part === ".." || part === "." || part === "")
      || names.has(name) || !["0", "2", "5"].includes(type))) throw new GatewayError("conflict", "unsafe managed pi-subagents closure entry");
    if (!Number.isSafeInteger(size) || size < 0 || offset + 512 + size > tar.length) throw new GatewayError("conflict", "invalid managed pi-subagents closure size");
    if (path !== "package") {
      names.add(name);
      const target = text(offset + 157, 100);
      if (type === "2" && (isAbsolute(target) || relative("/package", resolve("/package", dirname(name), target)).startsWith(".."))) {
        throw new GatewayError("conflict", "unsafe managed pi-subagents closure symlink");
      }
      entries.push({ name, type, bytes: tar.subarray(offset + 512, offset + 512 + size), target, mode: parseInt(text(offset + 100, 8).trim() || "0", 8) & 0o777 });
    }
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  return entries;
}

function privateDirectory(path: string): void {
  for (let parent = resolve(path);; parent = dirname(parent)) {
    if (existsSync(parent) && lstatSync(parent).isSymbolicLink()) throw new GatewayError("conflict", "managed pi-subagents root contains a symlink");
    if (dirname(parent) === parent) break;
  }
  mkdirSync(path, { recursive: true, mode: 0o700 });
}

function validateSdkPeers(entries: Entry[]): void {
  const manifest = JSON.parse(entries.find((entry) => entry.name === "package.json")!.bytes.toString()) as { peerDependencies: Record<string, string> };
  for (const [name, range] of Object.entries(manifest.peerDependencies)) {
    const root = realpathSync(join(gatewayRoot, "node_modules", name));
    const peer = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { name: string; version: string };
    const minimum = /^>=(\d+)\.(\d+)\.(\d+)$/u.exec(range);
    const parts = peer.version.split(".").map(Number);
    const minimumParts = minimum?.slice(1).map(Number);
    const comparison = minimumParts ? parts[0]! - minimumParts[0]! || parts[1]! - minimumParts[1]! || parts[2]! - minimumParts[2]! : 0;
    if (peer.name !== name || range !== "*" && (!minimum || comparison < 0)) throw new GatewayError("conflict", `managed pi-subagents SDK peer ${name} is incompatible`);
  }
}

function treeIdentity(root: string): string {
  const stamp = (path: string) => {
    const stat = lstatSync(path, { bigint: true });
    return `${path}\0${stat.dev}:${stat.ino}:${stat.mode}:${stat.size}:${stat.mtimeNs}:${stat.ctimeNs}`;
  };
  const rows: string[] = [];
  for (let parent = dirname(root); dirname(parent) !== parent; parent = dirname(parent)) {
    const stat = lstatSync(parent, { bigint: true });
    rows.push(`${parent}\0${stat.dev}:${stat.ino}:${stat.mode}`);
  }
  const walk = (directory: string): void => {
    rows.push(stamp(directory));
    const handle = opendirSync(directory);
    try {
      for (let item = handle.readSync(); item !== null; item = handle.readSync()) {
        const path = join(directory, item.name);
        if (item.isDirectory()) walk(path);
        else rows.push(stamp(path));
      }
    } finally { handle.closeSync(); }
  };
  walk(root);
  return rows.sort().join("\n");
}

export class ManagedSubagents {
  readonly root: string;
  private verifiedTree: string | undefined;
  private readonly canonicalHome: string;
  constructor(private readonly tronHome: string, private readonly logger?: ModuleLog) {
    this.tronHome = resolve(tronHome);
    let ancestor = this.tronHome;
    const missing: string[] = [];
    while (!existsSync(ancestor)) {
      missing.unshift(relative(dirname(ancestor), ancestor));
      ancestor = dirname(ancestor);
    }
    this.canonicalHome = join(realpathSync(ancestor), ...missing);
    this.root = tronHomePath(this.canonicalHome, "cache/pi-subagents", pin.version);
  }

  static activateForStartup(tronHome: string, logger?: ModuleLog): ManagedSubagents {
    const provider = new ManagedSubagents(tronHome, logger);
    provider.install();
    return provider;
  }

  install(): string {
    if (existsSync(this.root)) return this.verify();
    privateDirectory(dirname(this.root));
    const staging = mkdtempSync(join(dirname(this.root), ".install-"));
    try {
      const entries = closureEntries();
      for (const entry of entries) {
        const path = join(staging, entry.name);
        mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
        if (entry.type === "5") mkdirSync(path, { recursive: true, mode: 0o700 });
        else if (entry.type === "2") symlinkSync(entry.target, path);
        else writeFileSync(path, entry.bytes, { mode: entry.mode & 0o111 ? 0o700 : 0o600 });
      }
      writeFileSync(join(staging, receiptName), JSON.stringify({ version: pin.version, forkCommit: pin.fork.commit, sha512: pin.closure.sha512 }), { mode: 0o600 });
      this.verifyRoot(staging, entries);
      try { renameSync(staging, this.root); }
      catch (error) {
        if (!existsSync(this.root)) throw error;
      }
      return this.verify();
    } finally { rmSync(staging, { recursive: true, force: true }); }
  }

  verify(): string {
    if (!existsSync(this.root)) throw new GatewayError("conflict", "managed pi-subagents unavailable: install the selected Tron closure before activation");
    const identity = treeIdentity(this.root);
    if (identity !== this.verifiedTree) {
      this.verifiedTree = undefined;
      this.verifyRoot(this.root, closureEntries());
      this.verifiedTree = identity;
    }
    return this.root;
  }

  private verifyRoot(root: string, entries: Entry[]): void {
    for (let parent = root;; parent = dirname(parent)) {
      if (lstatSync(parent).isSymbolicLink()) throw new GatewayError("conflict", "managed pi-subagents root contains a symlink");
      if (dirname(parent) === parent) break;
    }
    const receiptPath = join(root, receiptName);
    if (!existsSync(receiptPath) || (!lstatSync(receiptPath).isFile() || lstatSync(receiptPath).size > 1024)) throw new GatewayError("conflict", "managed pi-subagents install receipt mismatch");
    const receipt = JSON.parse(readFileSync(receiptPath, "utf8"));
    if (receipt.version !== pin.version || receipt.forkCommit !== pin.fork.commit || receipt.sha512 !== pin.closure.sha512) throw new GatewayError("conflict", "managed pi-subagents install receipt mismatch");
    const expected = new Map(entries.map((entry) => [entry.name, entry]));
    validateSdkPeers(entries);
    const check = (directory: string): void => {
      const handle = opendirSync(directory);
      try {
        for (let item = handle.readSync(); item !== null; item = handle.readSync()) {
          const path = join(directory, item.name);
          const key = relative(root, path).split(sep).join("/");
          const stat = lstatSync(path);
          if (key === receiptName) continue;
          const entry = expected.get(key);
          if (!entry || entry.type === "5" && !stat.isDirectory()
            || entry.type === "2" && (!stat.isSymbolicLink() || readlinkSync(path) !== entry.target)
            || entry.type === "0" && (!stat.isFile() || stat.size !== entry.bytes.length || !readFileSync(path).equals(entry.bytes))) {
            throw new GatewayError("conflict", `managed pi-subagents installed closure mismatch: ${key}`);
          }
          expected.delete(key);
          if (stat.isDirectory()) check(path);
        }
      } finally { handle.closeSync(); }
    };
    check(root);
    if (expected.size) throw new GatewayError("conflict", "managed pi-subagents installed closure mismatch: missing entries");
  }

  async completeLoad(settings: SettingsManager, cwd: string, agentDir: string, extensions: readonly Extension[]): Promise<void> {
    const resources = await this.resources();
    const metadata = new Map(resources.extensions.map(resource => [resource.path, resource.metadata]));
    for (const extension of extensions) {
      const source = metadata.get(extension.resolvedPath);
      if (!isManagedSubagentExtension(extension) || !source) continue;
      extension.sourceInfo = { path: extension.resolvedPath, ...source };
      for (const tool of extension.tools.values()) tool.sourceInfo = extension.sourceInfo;
      for (const command of extension.commands.values()) command.sourceInfo = extension.sourceInfo;
    }
    const count = [...(settings.getGlobalSettings().packages ?? []), ...(settings.getProjectSettings().packages ?? [])]
      .filter(isUserSubagentsPackage).length;
    if (count) this.logger?.log("warning", IGNORED_SUBAGENTS_MESSAGE, {
      event: "pi-subagents.user-package-ignored", source: "managed-subagents", counts: { declarations: count },
    });

    const catalog = await loadSubagentCatalog({ agentDir, cwd, settingsManager: settings, managedSubagents: this });
    if (catalog.invalidDefinitionCount) this.logger?.log("warning", "Invalid subagent definitions; inspect session resource diagnostics", {
      event: "pi-subagents.agent-definition-invalid", source: "managed-subagents", counts: { definitions: catalog.invalidDefinitionCount },
    });
  }

  private resourcePaths(kind: "extensions" | "skills" | "prompts"): string[] {
    const root = this.verify();
    const manifestPath = join(root, "package.json");
    if (lstatSync(manifestPath).size > 64 * 1024) throw new GatewayError("conflict", "managed pi-subagents resource manifest is too large");
    let manifest: { pi?: Partial<Record<typeof kind, unknown>> } | null;
    try { manifest = JSON.parse(readFileSync(manifestPath, "utf8")); }
    catch { throw new GatewayError("conflict", "managed pi-subagents resource manifest is unreadable or invalid"); }
    const entries = manifest?.pi?.[kind] ?? (kind === "extensions" ? undefined : []);
    if (!Array.isArray(entries) || (kind === "extensions" && entries.length === 0) || entries.length > 32) {
      throw new GatewayError("conflict", `managed pi-subagents ${kind} entries are absent or invalid`);
    }
    return entries.map((entry: unknown) => {
      if (typeof entry !== "string" || entry.length === 0 || entry.length > 1024 || isAbsolute(entry)
        || entry.split(/[\\/]/u).includes("..")) {
        throw new GatewayError("conflict", `managed pi-subagents ${kind} entry escapes the verified root`);
      }
      const path = resolve(root, entry);
      const inside = relative(root, path);
      if (!inside || inside.startsWith(`..${sep}`) || isAbsolute(inside) || !existsSync(path)
        || !(lstatSync(path).isFile() || kind !== "extensions" && lstatSync(path).isDirectory()) || realpathSync(path) !== path) {
        throw new GatewayError("conflict", `managed pi-subagents ${kind} entry is missing or not a regular resource inside the verified root`);
      }
      return path;
    });
  }

  requireBoundArtifactRoot(tronHome: string): void {
    const boundRoot = process.env[DELEGATED_PROVIDER_ROOT_ENV];
    if (resolve(tronHome) !== resolve(this.tronHome)
      || !boundRoot?.trim() || resolve(boundRoot) !== delegatedArtifactRoot(tronHome)) {
      throw new GatewayError("conflict", "managed pi-subagents requires PI_SUBAGENTS_TEMP_ROOT bound to this Tron home's delegated artifact root before loading");
    }
  }

  async resources(): Promise<ResolvedPaths> {
    const root = this.verify();
    for (const kind of ["extensions", "skills", "prompts"] as const) this.resourcePaths(kind);
    const resolved = await new DefaultPackageManager({ cwd: root, agentDir: root, settingsManager: SettingsManager.inMemory() })
      .resolveExtensionSources([root]);
    if (resolved.installFailures?.length) throw new GatewayError("conflict", "managed pi-subagents resources failed to resolve");
    const admitted = (kind: "extensions" | "skills" | "prompts") => resolved[kind].map(resource => {
      const inside = relative(root, resource.path);
      if (!inside || inside.startsWith(`..${sep}`) || isAbsolute(inside) || realpathSync(resource.path) !== resource.path) {
        throw new GatewayError("conflict", "managed pi-subagents resource escapes the verified root");
      }
      return { ...resource, metadata: { source: MANAGED_SUBAGENTS_SOURCE, scope: "user" as const, origin: "package" as const, baseDir: root, packageRoot: root } };
    });
    return { extensions: admitted("extensions"), skills: admitted("skills"), prompts: admitted("prompts"), themes: [] };
  }

  async loaderOptions(settings: SettingsManager, internalWake?: ManagedInternalWake): Promise<ManagedLoaderOptions> {
    this.requireBoundArtifactRoot(this.tronHome);
    const resources = existsSync(this.root) ? await this.resources() : { extensions: [], skills: [], prompts: [], themes: [] };
    const paths = resources.extensions.filter(resource => resource.enabled).map(resource => resource.path);
    const sourceInfo = new Map<string, SourceInfo>([...resources.skills, ...resources.prompts].filter(resource => resource.enabled)
      .map(resource => [resource.path, { path: resource.path, ...resource.metadata }]));
    const attribute = <T extends { filePath: string }>(resource: T): T => {
      const source = sourceInfo.get(resource.filePath);
      return source ? { ...resource, sourceInfo: source } : resource;
    };
    return { settingsManager: managedProviderSettingsView(settings),
      additionalSkillPaths: resources.skills.filter(resource => resource.enabled).map(resource => resource.path),
      additionalPromptTemplatePaths: resources.prompts.filter(resource => resource.enabled).map(resource => resource.path),
      skillsOverride: (base) => ({ ...base, skills: base.skills.map(attribute) }),
      promptsOverride: (base) => ({ ...base, prompts: base.prompts.map(attribute) }),
      extensionFactories: paths.map((path, index) => ({
        name: `tron-managed-subagents-${index + 1}`,
        factory: async (pi) => {
          this.requireBoundArtifactRoot(this.tronHome);
          this.verify();
          const owner = producerIdentity(MANAGED_SUBAGENTS_SOURCE, path, "Subagents", "subagent");
          await withExtensionOwner(owner, async () => {
            const factory = await this.loadFactory(path);
            await factory(managedProducerAPI(pi, owner, internalWake));
          });
        },
      })),
    };
  }

  async requireChildExtensions(sessionId: string, extensions: readonly { id: string; path: string }[]): Promise<{ dispose(): void }> {
    this.requireBoundArtifactRoot(this.tronHome);
    const root = this.verify();
    this.requiredChildApi ??= this.loadModule(join(root, "src", "api", "required-child-extensions.ts")) as Promise<RequiredChildApi>;
    const api = await this.requiredChildApi;
    if (typeof api.registerRequiredChildExtensions !== "function") throw new GatewayError("conflict", "managed pi-subagents has no required child extension API");
    let entry = this.childExtensions.get(sessionId);
    if (!entry) { entry = { groups: new Map() }; this.childExtensions.set(sessionId, entry); }
    const key = Symbol();
    const publish = () => {
      entry!.registration?.dispose();
      const all = [...entry!.groups.values()].flat();
      entry!.registration = all.length ? api.registerRequiredChildExtensions!({ sessionId, extensions: all }) : undefined;
      if (!all.length) this.childExtensions.delete(sessionId);
    };
    const ids = new Set([...entry.groups.values()].flat().map(item => item.id));
    if (extensions.some(item => ids.has(item.id))) throw new GatewayError("conflict", "Duplicate required child extension identity");
    entry.groups.set(key, [...extensions]);
    try { publish(); } catch (error) { entry.groups.delete(key); publish(); throw error; }
    return { dispose: () => { if (entry!.groups.delete(key)) publish(); } };
  }
  private requiredChildApi: Promise<RequiredChildApi> | undefined;
  private readonly childExtensions = new Map<string, { groups: Map<symbol, Array<{ id: string; path: string }>>; registration?: { dispose(): void } | undefined }>();

  private async loadFactory(path: string): Promise<ExtensionFactory> {
    const factory = await this.loadModule(path, { defaultExport: true });
    if (typeof factory !== "function") throw new GatewayError("conflict", "managed pi-subagents entry does not export a factory");
    return factory as ExtensionFactory;
  }

  loadDiscovery(): Promise<unknown> {
    return this.loadModule(this.discoveryEntry(), { moduleCache: true, prepare: "discovery" });
  }

  private discoveryEntry(): string {
    return join(this.root, "src", "agents", "agents.js");
  }

  private async loadModule(path: string, options: { defaultExport?: boolean; moduleCache?: boolean; prepare?: "build" | "discovery" } = {}): Promise<unknown> {
    const loader = this.jitiOptions();
    const scope = options.prepare ?? "build";
    let prepared = this.transformCaches.get(scope);
    if (!prepared) {
      prepared = this.prepareTransformCache(loader, scope === "discovery" ? [this.discoveryEntry()] : undefined);
      this.transformCaches.set(scope, prepared);
    }
    try {
      await prepared;
    } catch {
      if (this.transformCaches.get(scope) === prepared) this.transformCaches.delete(scope);
      throw new GatewayError("busy", "managed pi-subagents could not prepare its TypeScript transforms; retry the load", true);
    }
    const { createJiti } = await import(loader.jitiUrl) as { createJiti: JitiFactory };
    return await createJiti(import.meta.url, { ...loader.jiti, moduleCache: options.moduleCache ?? false })
      .import(path, options.defaultExport ? { default: true } : {});
  }

  private readonly transformCaches = new Map<"build" | "discovery", Promise<void>>();

  prepareSessionTransforms(): Promise<boolean> {
    if (!existsSync(this.root)) return Promise.resolve(false);
    let prepared = this.transformCaches.get("build");
    if (!prepared) {
      prepared = this.prepareTransformCache(this.jitiOptions());
      this.transformCaches.set("build", prepared);
    }
    const scheduled = prepared;
    return scheduled.then(() => true, () => {
      if (this.transformCaches.get("build") === scheduled) this.transformCaches.delete("build");
      return false;
    });
  }

  private jitiOptions(): { jitiUrl: string; jiti: JitiOptions } {
    const require = createRequire(join(this.root, "package.json"));
    const fsCache = tronHomePath(this.canonicalHome, "cache/pi-subagents-transform-cache", basename(this.root));
    privateDirectory(fsCache);
    return { jitiUrl: pathToFileURL(require.resolve("jiti")).href, jiti: { moduleCache: false, alias: piExtensionAliases(), fsCache } };
  }

  private async prepareTransformCache(options: { jitiUrl: string; jiti: JitiOptions }, entries?: string[]): Promise<void> {
    let worker: Worker | undefined;
    try {
      const started = new Worker(TRANSFORM_CACHE_WORKER, { eval: true, workerData: { ...options, base: import.meta.url, root: this.verify(), entries } });
      worker = started;
      await new Promise<void>((resolveWorker, rejectWorker) => {
        started.once("message", (message: { error?: string }) => message.error ? rejectWorker(new Error(message.error)) : resolveWorker());
        started.once("error", rejectWorker);
        started.once("exit", (code) => rejectWorker(new Error(`transform worker exited with code ${code}`)));
      });
    } catch (error) {
      this.logger?.log("warning", "Managed subagent transforms could not be prepared off the Gateway thread", {
        event: "pi-subagents.transform-cache-failed", source: "managed-subagents",
      });
      throw error;
    } finally {
      await worker?.terminate();
    }
  }

  admit(extensions: readonly Extension[]): void {
    this.requireBoundArtifactRoot(this.tronHome);
    const paths = existsSync(this.root) ? this.resourcePaths("extensions") : [];
    for (const extension of extensions) {
      if (managedExtensions.has(extension)) {
        if (!paths.includes(extension.resolvedPath)) throw new GatewayError("conflict", "Managed subagent extension belongs to a different verified root");
        continue;
      }
      const index = paths.findIndex((_, index) => extension.path === `<inline:tron-managed-subagents-${index + 1}>`);
      if (index >= 0) {
        extension.path = paths[index]!;
        extension.resolvedPath = paths[index]!;
        managedExtensions.add(extension);
      }
      else if (extension.tools.has("subagent")) throw new GatewayError("conflict", "The subagent tool is reserved by the Tron-managed provider");
    }
  }
}
