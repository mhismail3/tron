export interface HookProjectionExtension {
  name: string;
  path: string;
  resolvedPath: string;
  scope: string;
  source: string;
  origin: string;
  tools: Iterable<string>;
  commands: Iterable<string>;
  handlers: ReadonlyMap<string, readonly unknown[]>;
}

export interface HookProjectionLoadError {
  path: string;
  error: string;
}

export const MAX_HOOK_HANDLER_EVENTS_PER_EXTENSION = 512;
export const MAX_HOOK_STRING_CHARACTERS = 16 * 1_024;
export const MAX_HOOK_PROJECTION_BYTES = 256 * 1_024;
// This matches the generic resource projection bound. It also prevents a lazy
// extension iterator from becoming an unbounded admission scan.
export const GENERIC_RESOURCE_ARRAY_LIMIT = 1_000;

export interface HookRegistrationProjection {
  extensions: Array<Record<string, unknown>>;
  extensionLoadErrors: Array<{ path: string; error: string }>;
  hookInventory: {
    extensions: { total: number; retained: number; omitted: number };
    handlerEvents: { total: number; retained: number; omitted: number };
    loadErrors: { total: number; retained: number; omitted: number };
    textFieldsOmitted: number;
    encodedBytes: number;
    encodedBytesLimit: number;
  };
}

const EXTENSION_PREFIX = '{"extensions":[';
const ERROR_SEPARATOR = '],"extensionLoadErrors":[';
const PROJECTION_SUFFIX = ']}';

function boundedText(value: string, onOmitted: () => void): string {
  if (value.length <= MAX_HOOK_STRING_CHARACTERS) return value;
  onOmitted();
  return `${value.slice(0, MAX_HOOK_STRING_CHARACTERS)}…`;
}

/** Projects registrations under one aggregate envelope. Identity rows are
 * admitted first; handlers, tools, and commands are optional additions and can
 * never make an already-admitted identity disappear. */
export function projectHookRegistrations(
  extensions: readonly HookProjectionExtension[],
  loadErrors: readonly HookProjectionLoadError[],
): HookRegistrationProjection {
  let textFieldsOmitted = 0;
  let retainedHandlerEvents = 0;
  const projectedExtensions: Array<Record<string, unknown>> = [];
  const prefixBytes = Buffer.byteLength(EXTENSION_PREFIX);
  const separatorBytes = Buffer.byteLength(ERROR_SEPARATOR);
  const suffixBytes = Buffer.byteLength(PROJECTION_SUFFIX);
  const rowBytes = (row: Record<string, unknown>): number => Buffer.byteLength(JSON.stringify(row));
  const rowsBytes = (): number => prefixBytes
    + projectedExtensions.reduce((total, row) => total + rowBytes(row), 0)
    + Math.max(0, projectedExtensions.length - 1);
  const canAdmitIdentity = (candidateBytes: number): boolean =>
    rowsBytes() + (projectedExtensions.length > 0 ? 1 : 0) + candidateBytes
      + separatorBytes + suffixBytes <= MAX_HOOK_PROJECTION_BYTES;

  // Reserve every identity before optional inventories are admitted. A large
  // handler map can therefore never evict a later extension's identity.
  for (let index = 0; index < extensions.length && index < GENERIC_RESOURCE_ARRAY_LIMIT; index += 1) {
    const extension = extensions[index]!;
    const row: Record<string, unknown> = {
      name: boundedText(extension.name, () => { textFieldsOmitted += 1; }),
      path: boundedText(extension.path, () => { textFieldsOmitted += 1; }),
      resolvedPath: boundedText(extension.resolvedPath, () => { textFieldsOmitted += 1; }),
      scope: boundedText(extension.scope, () => { textFieldsOmitted += 1; }),
      source: boundedText(extension.source, () => { textFieldsOmitted += 1; }),
      origin: boundedText(extension.origin, () => { textFieldsOmitted += 1; }),
      tools: [], commands: [], handlers: [],
    };
    if (!canAdmitIdentity(rowBytes(row))) break;
    projectedExtensions.push(row);
  }
  const retainedExtensions = projectedExtensions.length;

  const admitValues = (extension: HookProjectionExtension, index: number, field: "tools" | "commands"): void => {
    const target = projectedExtensions[index]![field] as string[];
    let seen = 0;
    for (const value of extension[field]) {
      if (seen >= GENERIC_RESOURCE_ARRAY_LIMIT) { textFieldsOmitted += 1; break; }
      seen += 1;
      const bounded = boundedText(value, () => { textFieldsOmitted += 1; });
      target.push(bounded);
      if (rowsBytes() + separatorBytes + suffixBytes > MAX_HOOK_PROJECTION_BYTES) {
        target.pop();
        textFieldsOmitted += 1;
        break;
      }
    }
  };

  for (let index = 0; index < retainedExtensions; index += 1) {
    const extension = extensions[index]!;
    const row = projectedExtensions[index]!;
    const handlerItems: Array<{ event: string; count: number }> = [];
    let seenHandlers = 0;
    for (const [event, registeredHandlers] of extension.handlers) {
      if (seenHandlers >= MAX_HOOK_HANDLER_EVENTS_PER_EXTENSION) break;
      seenHandlers += 1;
      if (event.length > MAX_HOOK_STRING_CHARACTERS) { textFieldsOmitted += 1; continue; }
      const item = { event, count: registeredHandlers.length };
      // Mutate the bounded accumulator only while measuring this candidate;
      // cloning a growing handler list here would make admission quadratic.
      const previousHandlers = row.handlers;
      handlerItems.push(item);
      row.handlers = handlerItems;
      const fits = rowsBytes() + separatorBytes + suffixBytes <= MAX_HOOK_PROJECTION_BYTES;
      if (!fits) {
        handlerItems.pop();
        row.handlers = previousHandlers;
        textFieldsOmitted += 1;
      }
    }
    retainedHandlerEvents += handlerItems.length;
    admitValues(extension, index, "tools");
    admitValues(extension, index, "commands");
  }

  const projectedLoadErrors: Array<{ path: string; error: string }> = [];
  let encodedBytes = rowsBytes() + separatorBytes;
  for (let index = 0; index < loadErrors.length && index < GENERIC_RESOURCE_ARRAY_LIMIT; index += 1) {
    const loadError = loadErrors[index]!;
    const projected = {
      path: boundedText(loadError.path, () => { textFieldsOmitted += 1; }),
      error: boundedText(loadError.error, () => { textFieldsOmitted += 1; }),
    };
    const bytes = Buffer.byteLength(JSON.stringify(projected));
    const comma = projectedLoadErrors.length > 0 ? 1 : 0;
    if (encodedBytes + comma + bytes + suffixBytes > MAX_HOOK_PROJECTION_BYTES) { textFieldsOmitted += 1; continue; }
    projectedLoadErrors.push(projected);
    encodedBytes += comma + bytes;
  }
  if (extensions.length > GENERIC_RESOURCE_ARRAY_LIMIT || loadErrors.length > GENERIC_RESOURCE_ARRAY_LIMIT) textFieldsOmitted += 1;
  encodedBytes += suffixBytes;
  const totalHookHandlerEvents = extensions.reduce((total, extension) => total + extension.handlers.size, 0);
  return {
    extensions: projectedExtensions,
    extensionLoadErrors: projectedLoadErrors,
    hookInventory: {
      extensions: { total: extensions.length, retained: retainedExtensions, omitted: extensions.length - retainedExtensions },
      handlerEvents: { total: totalHookHandlerEvents, retained: retainedHandlerEvents, omitted: totalHookHandlerEvents - retainedHandlerEvents },
      loadErrors: { total: loadErrors.length, retained: projectedLoadErrors.length, omitted: loadErrors.length - projectedLoadErrors.length },
      textFieldsOmitted,
      encodedBytes,
      encodedBytesLimit: MAX_HOOK_PROJECTION_BYTES,
    },
  };
}
