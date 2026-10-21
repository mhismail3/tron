import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import lockfile from "proper-lockfile";
import { SettingsManager } from "../kernel/pi/coding-agent.js";
import { KEYS, type Binding } from "./settings-schema.js";
import { GatewayError } from "../errors.js";

/** Validate declared repository values, not ignored/safety fields. Missing
 * fields inherit; malformed declared fields must not silently become Global. */
export async function validateProjectSettings(raw: Record<string, unknown>): Promise<void> {
  for (const key of KEYS) {
    const binding = key.projectSettable ? key.layers.project : undefined;
    if (!binding) continue;
    try {
      if (binding.store === "pi-model-ref") {
        if (Object.hasOwn(raw, "defaultProvider") || Object.hasOwn(raw, "defaultModel")) await key.type.validate({ provider: raw.defaultProvider, id: raw.defaultModel }, key.id);
      } else if (binding.store === "pi") {
        const check = async (source: Document, path: readonly string[]): Promise<void> => {
          const [field, ...rest] = path;
          if (!field) return;
          for (const name of field === "{model}" ? Object.keys(source) : [field]) {
            if (!Object.hasOwn(source, name)) continue;
            if (!rest.length) await key.type.validate(source[name], key.id);
            else {
              const nested = record(source[name]);
              if (!nested) throw new Error("Expected a settings object");
              await check(nested, rest);
            }
          }
        };
        for (const path of paths(binding)) await check(raw, path);
      }
    } catch {
      throw new GatewayError("conflict", `Project value for ${key.id} is invalid in .pi/settings.json`);
    }
  }
}

type Document = Record<string, unknown>;
const document = (text: string | undefined): Document => {
  const value: unknown = text?.trim() ? JSON.parse(text) : {};
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Settings must be an object");
  return value as Document;
};
const record = (value: unknown): Document | undefined => value && typeof value === "object" && !Array.isArray(value) ? value as Document : undefined;

/** Copy only declared paths, including each model-qualified instance. Unknown
 * repository values never enter the SDK, even when the repository is trusted. */
function copyPath(source: Document, destination: Document, path: readonly string[]): void {
  const [field, ...rest] = path;
  if (!field) return;
  const fields = field === "{model}" ? Object.keys(source) : [field];
  for (const name of fields) {
    if (!Object.hasOwn(source, name)) continue;
    if (!rest.length) { Object.defineProperty(destination, name, { value: structuredClone(source[name]), writable: true, enumerable: true, configurable: true }); continue; }
    const nested = record(source[name]);
    if (!nested) continue;
    const target = Object.hasOwn(destination, name) ? record(destination[name]) ?? Object.create(null) : Object.create(null);
    copyPath(nested, target, rest);
    if (Object.keys(target).length) Object.defineProperty(destination, name, { value: target, writable: true, enumerable: true, configurable: true });
  }
}
function paths(binding: Binding): readonly (readonly string[])[] {
  return binding.store === "pi-model-ref" ? [["defaultProvider"], ["defaultModel"]]
    : binding.store === "pi" ? [binding.path, ...(binding.qualified ? [binding.qualified] : [])] : [];
}
export function admittedProjectSettings(raw: Document): Document {
  const admitted: Document = Object.create(null);
  for (const key of KEYS) {
    const binding = key.projectSettable ? key.layers.project : undefined;
    if (binding) for (const path of paths(binding)) copyPath(raw, admitted, path);
  }
  return admitted;
}

/** Delete only admitted paths before replacing their projection. Ignored data
 * remains repository-owned and survives SDK package updates/flushes verbatim. */
function removePath(raw: Document, path: readonly string[]): void {
  const [field, ...rest] = path;
  if (!field) return;
  for (const name of field === "{model}" ? Object.keys(raw) : [field]) {
    if (!rest.length) delete raw[name];
    else {
      const nested = record(raw[name]);
      if (nested) { removePath(nested, rest); if (!Object.keys(nested).length) delete raw[name]; }
    }
  }
}
function replaceProjectProjection(raw: Document, next: Document): Document {
  for (const key of KEYS) {
    const binding = key.projectSettable ? key.layers.project : undefined;
    if (!binding) continue;
    for (const path of paths(binding)) { removePath(raw, path); copyPath(next, raw, path); }
  }
  return raw;
}

/** The SDK's public SettingsStorage seam, over the same canonical files and
 * proper-lockfile protocol. This is an admission projection, never another
 * settings store. Writes merge into the locked raw document, not the projection. */
export async function createSettingsManager(projectDir: string, agentDir: string, projectTrusted: boolean): Promise<SettingsManager> {
  const storage: Parameters<typeof SettingsManager.fromStorage>[0] = {
    withLock(scope, transform) {
      const path = scope === "global" ? join(agentDir, "settings.json") : join(projectDir, ".pi", "settings.json");
      let release: (() => void) | undefined;
      const acquire = () => {
        for (let attempt = 0; ; attempt += 1) {
          try { return lockfile.lockSync(path, { realpath: false }); }
          catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "ELOCKED" || attempt === 9) throw error;
            // Preserve the SDK storage's bounded 10 x 20ms lock wait, without
            // its busy-spin. No model request or mutation is retried here.
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
          }
        }
      };
      try {
        // Lock absent files too when their directory exists. If the directory
        // is absent a read stays side-effect-free; concurrent creation before a
        // later write is a conflict, never permission to overwrite unknown data.
        if (existsSync(dirname(path))) release = acquire();
        const current = existsSync(path) ? readFileSync(path, "utf8") : undefined;
        const raw = scope === "project" ? document(current) : undefined;
        const next = transform(raw ? JSON.stringify(admittedProjectSettings(raw)) : current);
        if (next !== undefined) {
          mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
          if (!release) {
            release = acquire();
            if (existsSync(path)) throw new Error("Settings file was created concurrently; refresh before writing");
          }
          writeFileSync(path, raw ? JSON.stringify(replaceProjectProjection(raw, document(next)), null, 2) + "\n" : next, { mode: 0o600 });
        }
      } catch (error) {
        throw new Error(`Settings file ${path}: ${error instanceof Error ? error.message : String(error)}`, { cause: error });
      } finally { release?.(); }
    },
  };
  const manager = SettingsManager.fromStorage(storage, { projectTrusted });
  if (projectTrusted) await validateProjectSettings(manager.getProjectSettings() as Record<string, unknown>);
  return manager;
}
