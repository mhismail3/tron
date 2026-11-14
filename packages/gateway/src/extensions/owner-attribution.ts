import { basename, extname } from "node:path";
import type { Extension, LoadExtensionsResult } from "../kernel/pi/coding-agent.js";
import { AUDITED_ASK_USER_PACKAGE } from "../kernel/host/extension-adapters.js";
import { installExtensionRegistration, producerIdentity, type ManagedExtensionAdmission } from "../kernel/host/extension-registration.js";
import type { ExtensionOwner } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import type { BrowserResultObservation } from "../kernel/projection/tool-result.js";
import { isManagedSubagentExtension, MANAGED_SUBAGENTS_SOURCE } from "../kernel/delegation/managed-subagents.js";
import { TRON_ASK_USER_INLINE_PATH, TRON_ASK_USER_SOURCE } from "./tron-ask-user-contract.js";

const RESERVED_FIRST_PARTY_TOOLS: ReadonlyArray<readonly [string, string]> = [
  ["notify", "tron-notify"],
  ["push_retry", "tron-notify"],
  ["display", "tron-display"],
  ["native_capture", "tron-native-capture"],
  ["computer", "tron-computer"],
  ["web_search", "tron-web-research"],
];
const GENERIC_EXTENSION_NAMES: ReadonlySet<string> = new Set([
  "index", "main", "mod", "entry", "extension", "extensions", "bundle",
  ".pi", "pi", "dist", "src", "lib", "libs", "build", "out", "node_modules",
]);

function titleFromName(value: string): string | undefined {
  const words = value.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (words.length === 0) return undefined;
  return words.map((word) => word[0]!.toUpperCase() + word.slice(1)).join(" ");
}

function baseNameWithoutExtension(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const name = basename(value);
  const extension = extname(name);
  return extension ? name.slice(0, -extension.length) : name;
}

function humanizedDisplayName(extension: Extension): string {
  const inline = [extension.path, extension.resolvedPath, extension.sourceInfo.path]
    .find((value) => typeof value === "string" && value.startsWith("<") && value.endsWith(">"));
  if (inline) {
    const inner = inline.slice(1, -1);
    return titleFromName(inner.slice(inner.indexOf(":") + 1) || inner) ?? "Extension";
  }
  for (const name of [baseNameWithoutExtension(extension.resolvedPath), baseNameWithoutExtension(extension.sourceInfo.baseDir)]) {
    if (name && !GENERIC_EXTENSION_NAMES.has(name.toLowerCase())) {
      const title = titleFromName(name);
      if (title) return title;
    }
  }
  const npmPackage = /^npm:(?:@[^/]+\/)?(.+)$/u.exec(extension.sourceInfo.source ?? "")?.[1];
  return (npmPackage ? titleFromName(npmPackage) : undefined) ?? "Extension";
}

function extensionOwnerFor(extension: Extension): ExtensionOwner {
  const source = isManagedSubagentExtension(extension) ? MANAGED_SUBAGENTS_SOURCE : extension.path === TRON_ASK_USER_INLINE_PATH
    ? TRON_ASK_USER_SOURCE
    : extension.sourceInfo.source;
  return producerIdentity(source, extension.resolvedPath, isManagedSubagentExtension(extension) ? "Subagents" : humanizedDisplayName(extension), source === MANAGED_SUBAGENTS_SOURCE ? "subagent" : "extension");
}

function assertAdmissibleToolName(extension: Extension, name: string, requireTronAskUser: boolean, requireManagedSubagents: boolean): void {
  if (name === "subagent" && requireManagedSubagents && !isManagedSubagentExtension(extension)) {
    throw new GatewayError("conflict", "The subagent tool is reserved by the Tron-managed provider");
  }
  if (name === "bash") throw new GatewayError("conflict", "The bash tool name is reserved by Tron");
  for (const [tool, owner] of RESERVED_FIRST_PARTY_TOOLS) {
    if (name !== tool) continue;
    if (extension.path !== `<inline:${owner}>`) {
      throw new GatewayError("conflict", `The ${tool} tool name is reserved by Tron`);
    }
    return;
  }
  if (name !== "ask_user" || !requireTronAskUser || extension.path === TRON_ASK_USER_INLINE_PATH) return;
  if (extension.sourceInfo.source === AUDITED_ASK_USER_PACKAGE.source) {
    throw new GatewayError("conflict", `The configured ${AUDITED_ASK_USER_PACKAGE.source} extension conflicts with Tron's ask_user capability; disable only that extension in the destination Pi settings and retry`);
  }
  throw new GatewayError("conflict", "The ask_user tool name is reserved by Tron");
}

function validateReservedCapabilities(base: LoadExtensionsResult, options?: { requireTronAskUser?: boolean }): void {
  if (base.extensions.some((extension) => extension.tools.has("bash"))) {
    throw new GatewayError("conflict", "The bash tool name is reserved by Tron");
  }
  for (const [tool, owner] of RESERVED_FIRST_PARTY_TOOLS) {
    const owners = base.extensions.filter((extension) => extension.tools.has(tool));
    if (owners.some((extension) => extension.path !== `<inline:${owner}>`)) {
      throw new GatewayError("conflict", `The ${tool} tool name is reserved by Tron`);
    }
    if (owners.length > 1) throw new GatewayError("conflict", `The first-party ${tool} tool was registered more than once`);
  }
  if (!options?.requireTronAskUser) return;
  const firstParty = base.extensions.filter((extension) => extension.path === TRON_ASK_USER_INLINE_PATH);
  if (firstParty.length !== 1 || !firstParty[0]!.tools.has("ask_user")) {
    throw new GatewayError("conflict", "The first-party ask_user capability failed to load");
  }
  const owners = base.extensions.filter((extension) => extension.tools.has("ask_user"));
  const superseded = owners.find((extension) => extension.sourceInfo.source === AUDITED_ASK_USER_PACKAGE.source);
  if (superseded) {
    throw new GatewayError("conflict", `The configured ${AUDITED_ASK_USER_PACKAGE.source} extension conflicts with Tron's ask_user capability; disable only that extension in the destination Pi settings and retry`);
  }
  if (owners.some((extension) => extension.path !== TRON_ASK_USER_INLINE_PATH)) {
    throw new GatewayError("conflict", "The ask_user tool name is reserved by Tron");
  }
  if (owners.length > 1) throw new GatewayError("conflict", "The first-party ask_user tool was registered more than once");
}

export function attributeExtensions(base: LoadExtensionsResult, browserLiveView?: BrowserResultObservation,
  options?: { requireTronAskUser?: boolean; managedSubagents?: ManagedExtensionAdmission }): LoadExtensionsResult {
  options?.managedSubagents?.admit(base.extensions);
  validateReservedCapabilities(base, options);
  const requireTronAskUser = options?.requireTronAskUser === true;
  const requireManagedSubagents = options?.managedSubagents !== undefined;
  for (const extension of base.extensions) installExtensionRegistration(extension,
    () => extensionOwnerFor(extension),
    name => assertAdmissibleToolName(extension, name, requireTronAskUser, requireManagedSubagents),
    browserLiveView);
  return base;
}
