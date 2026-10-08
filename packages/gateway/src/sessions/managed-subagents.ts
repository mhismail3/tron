import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, opendirSync, readlinkSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import type { Extension, SettingsManager, PackageSource } from "@earendil-works/pi-coding-agent";
import type { GatewayLogger } from "../transport/logger.js";
import { GatewayError } from "../errors.js";
import { delegatedArtifactRoot, DELEGATED_PROVIDER_ROOT_ENV } from "./delegated-provider.js";

const gatewayRoot = fileURLToPath(new URL("../../", import.meta.url));
const pin = JSON.parse(readFileSync(join(gatewayRoot, "pi-subagents-pin.json"), "utf8")) as {
  version: string; fork: { commit: string }; closure: { path: string; sha512: string };
};
export const MANAGED_SUBAGENTS_VERSION = pin.version;
export const MANAGED_SUBAGENTS_SOURCE = `tron:pi-subagents@${pin.version}#${pin.closure.sha512}`;
type Settings = ReturnType<SettingsManager["getSettings"]>;

export const IGNORED_SUBAGENTS_MESSAGE = "Tron manages pi-subagents; this user declaration is ignored. Remove it with `pi remove npm:pi-subagents`.";
export function isUserSubagentsPackage(pkg: PackageSource): boolean {
  return /^npm:pi-subagents(?:@|$)/u.test(typeof pkg === "string" ? pkg : pkg.source);
}

/** Pi's pinned DefaultResourceLoader has no pre-load filter; extensionsOverride
 * runs after execution. Its package resolver reads these scoped settings in both
 * the pre-trust and final passes. Keep that loader's view read-only for packages,
 * while reload/trust and all other settings remain owned by the canonical manager. */
export function managedProviderSettingsView(settings: SettingsManager): SettingsManager {
  const filter = (value: Settings): Settings => ({ ...value,
    ...(value.packages ? { packages: value.packages.filter(pkg => !isUserSubagentsPackage(pkg)) } : {}),
  });
  const refuse = (): never => { throw new GatewayError("conflict", "Managed provider settings view is read-only for packages"); };
  return new Proxy(settings, {
    get(target, key) {
      if (key === "getPackages") return () => target.getPackages().filter(pkg => !isUserSubagentsPackage(pkg));
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

interface Entry { name: string; type: string; bytes: Buffer; target: string; mode: number; }

/** The pinned builder emits ustar only. No arbitrary archive metadata or
 * install scripts are executable at activation; unsupported entries fail closed. */
function closureEntries(): Entry[] {
  const archivePath = join(gatewayRoot, pin.closure.path);
  const metadata = lstatSync(archivePath);
  if (!metadata.isFile() || metadata.size > 64 * 1024 * 1024) throw new GatewayError("conflict", "invalid managed pi-subagents closure file");
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
  // Refuse symlinked ancestors before creating or inspecting the reserved root.
  for (let parent = resolve(path);; parent = dirname(parent)) {
    if (existsSync(parent) && lstatSync(parent).isSymbolicLink()) throw new GatewayError("conflict", "managed pi-subagents root contains a symlink");
    if (dirname(parent) === parent) break;
  }
  mkdirSync(path, { recursive: true, mode: 0o700 });
}

function validateSdkPeers(entries: Entry[]): void {
  const manifest = JSON.parse(entries.find((entry) => entry.name === "package.json")!.bytes.toString()) as { peerDependencies: Record<string, string> };
  for (const [name, range] of Object.entries(manifest.peerDependencies)) {
    // The selected payload's npm tree is the only peer authority. Never search
    // the provider's home, NODE_PATH, a user npm tree, or a global install.
    // Pi's loader supplies these modules through host aliases, not disk links.
    const root = realpathSync(join(gatewayRoot, "node_modules", name));
    const peer = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { name: string; version: string };
    const minimum = /^>=(\d+)\.(\d+)\.(\d+)$/u.exec(range);
    const parts = peer.version.split(".").map(Number);
    const minimumParts = minimum?.slice(1).map(Number);
    const comparison = minimumParts ? parts[0]! - minimumParts[0]! || parts[1]! - minimumParts[1]! || parts[2]! - minimumParts[2]! : 0;
    if (peer.name !== name || range !== "*" && (!minimum || comparison < 0)) throw new GatewayError("conflict", `managed pi-subagents SDK peer ${name} is incompatible`);
  }
}

/** One payload/home selection. Activation uses only the selected offline closure,
 * never a user package declaration, network fallback or in-place replacement. */
export class ManagedSubagents {
  readonly root: string;
  constructor(private readonly tronHome: string, private readonly logger?: Pick<GatewayLogger, "log">) {
    this.tronHome = resolve(tronHome);
    let ancestor = this.tronHome;
    const missing: string[] = [];
    while (!existsSync(ancestor)) {
      missing.unshift(relative(dirname(ancestor), ancestor));
      ancestor = dirname(ancestor);
    }
    this.root = join(realpathSync(ancestor), ...missing, "internal", "pi-subagents", pin.version);
  }

  /** Startup returns a selection only after its immutable build is usable.
   * The same boundary owns fresh activation and restart verification. */
  static activateForStartup(tronHome: string, logger?: Pick<GatewayLogger, "log">): ManagedSubagents {
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
        // A concurrent installer may have published the same immutable build.
        if (!existsSync(this.root)) throw error;
      }
      return this.verify();
    } finally { rmSync(staging, { recursive: true, force: true }); }
  }

  verify(): string {
    if (!existsSync(this.root)) throw new GatewayError("conflict", "managed pi-subagents unavailable: install the selected Tron closure before activation");
    this.verifyRoot(this.root, closureEntries());
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

  /** Called by the load owner after startup/reload, once per operation rather
   * than on each scoped read or in the pre-trust pass. No paths or user specs. */
  reportIgnoredPackages(settings: SettingsManager): void {
    const count = [...(settings.getGlobalSettings().packages ?? []), ...(settings.getProjectSettings().packages ?? [])]
      .filter(isUserSubagentsPackage).length;
    if (count) this.logger?.log("warning", IGNORED_SUBAGENTS_MESSAGE, {
      event: "pi-subagents.user-package-ignored", source: "managed-subagents", counts: { declarations: count },
    });
  }

  private extensionPaths(): string[] {
    const root = this.verify();
    const manifestPath = join(root, "package.json");
    if (lstatSync(manifestPath).size > 64 * 1024) throw new GatewayError("conflict", "managed pi-subagents extension manifest is too large");
    let manifest: { pi?: { extensions?: unknown } } | null;
    try { manifest = JSON.parse(readFileSync(manifestPath, "utf8")); }
    catch { throw new GatewayError("conflict", "managed pi-subagents extension manifest is unreadable or invalid"); }
    const entries = manifest?.pi?.extensions;
    if (!Array.isArray(entries) || entries.length === 0 || entries.length > 32) {
      throw new GatewayError("conflict", "managed pi-subagents extension entries are absent or invalid");
    }
    // Entry identity belongs to the verified build, not a candidate-specific
    // filename. Resolve loader and admission from this single authority.
    return entries.map((entry: unknown) => {
      if (typeof entry !== "string" || entry.length === 0 || entry.length > 1024 || isAbsolute(entry)
        || entry.split(/[\\/]/u).includes("..")) {
        throw new GatewayError("conflict", "managed pi-subagents extension entry escapes the verified root");
      }
      const path = resolve(root, entry);
      const inside = relative(root, path);
      if (!inside || inside.startsWith(`..${sep}`) || isAbsolute(inside) || !existsSync(path)
        || !lstatSync(path).isFile() || realpathSync(path) !== path) {
        throw new GatewayError("conflict", "managed pi-subagents extension entry is missing or not a regular file inside the verified root");
      }
      return path;
    });
  }

  /** The registry supplies its own home; the selection cannot be transferred
   * to another home merely by keeping this process's existing binding. */
  requireBoundArtifactRoot(tronHome: string): void {
    const boundRoot = process.env[DELEGATED_PROVIDER_ROOT_ENV];
    if (resolve(tronHome) !== resolve(this.tronHome)
      || !boundRoot?.trim() || resolve(boundRoot) !== delegatedArtifactRoot(tronHome)) {
      throw new GatewayError("conflict", "managed pi-subagents requires PI_SUBAGENTS_TEMP_ROOT bound to this Tron home's delegated artifact root before loading");
    }
  }

  loaderOptions(settings: SettingsManager): { settingsManager: SettingsManager; additionalExtensionPaths: string[] } {
    // Check before executing extension code; admission repeats it for reloads
    // and to refuse a process binding changed while the loader was awaiting I/O.
    this.requireBoundArtifactRoot(this.tronHome);
    return { settingsManager: managedProviderSettingsView(settings), additionalExtensionPaths: existsSync(this.root) ? this.extensionPaths() : [] };
  }

  admit(extensions: readonly Extension[]): void {
    this.requireBoundArtifactRoot(this.tronHome);
    const paths = existsSync(this.root) ? this.extensionPaths() : [];
    for (const extension of extensions) {
      if (paths.includes(extension.resolvedPath)) managedExtensions.add(extension);
      else if (extension.tools.has("subagent")) throw new GatewayError("conflict", "The subagent tool is reserved by the Tron-managed provider");
    }
  }
}
