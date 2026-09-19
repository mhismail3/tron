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

function arrayBytes(items: readonly number[]): number {
  return 2 + items.reduce((total, bytes, index) => total + bytes + (index > 0 ? 1 : 0), 0);
}

/**
 * Projects loader registrations under one aggregate envelope. A row is admitted
 * only when its complete identity and selected additions fit the envelope; this
 * keeps the reported encoded byte count equal to the actual bounded projection
 * rather than budgeting handlers separately from the rows that contain them.
 */
export function projectHookRegistrations(
  extensions: readonly HookProjectionExtension[],
  loadErrors: readonly HookProjectionLoadError[],
): HookRegistrationProjection {
  let textFieldsOmitted = 0;
  let retainedHandlerEvents = 0;
  let retainedLoadErrors = 0;
  let retainedExtensions = 0;
  const projectedExtensions: Array<Record<string, unknown>> = [];
  const projectedLoadErrors: Array<{ path: string; error: string }> = [];
  const prefixBytes = Buffer.byteLength(EXTENSION_PREFIX);
  const separatorBytes = Buffer.byteLength(ERROR_SEPARATOR);
  const suffixBytes = Buffer.byteLength(PROJECTION_SUFFIX);
  let encodedBytes = prefixBytes;

  const baseRow = (extension: HookProjectionExtension, handlers: Array<{ event: string; count: number }>): Record<string, unknown> => ({
    name: boundedText(extension.name, () => { textFieldsOmitted += 1; }),
    path: boundedText(extension.path, () => { textFieldsOmitted += 1; }),
    resolvedPath: boundedText(extension.resolvedPath, () => { textFieldsOmitted += 1; }),
    scope: boundedText(extension.scope, () => { textFieldsOmitted += 1; }),
    source: boundedText(extension.source, () => { textFieldsOmitted += 1; }),
    origin: boundedText(extension.origin, () => { textFieldsOmitted += 1; }),
    tools: [],
    commands: [],
    handlers,
  });

  for (let extensionIndex = 0; extensionIndex < extensions.length && extensionIndex < GENERIC_RESOURCE_ARRAY_LIMIT; extensionIndex += 1) {
    const extension = extensions[extensionIndex]!;
    const totalHandlers = extension.handlers.size;
    const handlers: Array<{ event: string; count: number }> = [];
    let handlerBytes = 2;
    let handlerIndex = 0;
    for (const [event, registeredHandlers] of extension.handlers) {
      if (handlerIndex >= MAX_HOOK_HANDLER_EVENTS_PER_EXTENSION) break;
      handlerIndex += 1;
      if (event.length > MAX_HOOK_STRING_CHARACTERS) {
        textFieldsOmitted += 1;
        continue;
      }
      const projected = { event, count: registeredHandlers.length };
      const itemBytes = Buffer.byteLength(JSON.stringify(projected));
      handlers.push(projected);
      handlerBytes += itemBytes + (handlers.length > 1 ? 1 : 0);
    }

    const row = baseRow(extension, handlers);
    const rowBaseBytes = Buffer.byteLength(JSON.stringify(row));
    const fixedRowBytes = rowBaseBytes - 4; // replace the two empty arrays below
    const toolValues: string[] = [];
    const commandValues: string[] = [];
    const toolBytes: number[] = [];
    const commandBytes: number[] = [];
    const rowBytes = (): number => fixedRowBytes + arrayBytes(toolBytes) + arrayBytes(commandBytes) - handlerBytes + handlerBytes;
    // The handler array is already represented in rowBaseBytes; the final two
    // terms make the accounting explicit and keep this expression symmetric.
    let candidateBytes = rowBytes();
    const canFit = (nextBytes: number): boolean => encodedBytes
      + (projectedExtensions.length > 0 ? 1 : 0)
      + nextBytes + separatorBytes + suffixBytes <= MAX_HOOK_PROJECTION_BYTES;

    const admitValues = (values: Iterable<string>, target: string[], targetBytes: number[]): void => {
      let seen = 0;
      for (const value of values) {
        if (seen >= GENERIC_RESOURCE_ARRAY_LIMIT) {
          textFieldsOmitted += 1;
          break;
        }
        seen += 1;
        const bounded = boundedText(value, () => { textFieldsOmitted += 1; });
        const valueBytes = Buffer.byteLength(JSON.stringify(bounded));
        const nextBytes = candidateBytes
          - arrayBytes(targetBytes) + arrayBytes([...targetBytes, valueBytes]);
        if (!canFit(nextBytes)) {
          textFieldsOmitted += 1;
          break;
        }
        target.push(bounded);
        targetBytes.push(valueBytes);
        candidateBytes = nextBytes;
      }
    };
    admitValues(extension.tools, toolValues, toolBytes);
    admitValues(extension.commands, commandValues, commandBytes);
    row.tools = toolValues;
    row.commands = commandValues;
    candidateBytes = rowBytes();

    if (!canFit(candidateBytes)) {
      // The identity row itself is too large for the remaining envelope. Do
      // not publish a partial identity; the omission is reflected below.
      continue;
    }
    projectedExtensions.push(row);
    retainedExtensions += 1;
    retainedHandlerEvents += handlers.length;
    encodedBytes += (projectedExtensions.length > 1 ? 1 : 0) + candidateBytes;
  }

  // Rows after the explicit scan bound are omitted without walking a lazy source
  // again; the inventory remains exact because the input is an array.
  const omittedExtensionCount = Math.max(0, extensions.length - projectedExtensions.length);
  if (extensions.length > GENERIC_RESOURCE_ARRAY_LIMIT) textFieldsOmitted += 1;

  encodedBytes += separatorBytes;
  for (let index = 0; index < loadErrors.length && index < GENERIC_RESOURCE_ARRAY_LIMIT; index += 1) {
    const loadError = loadErrors[index]!;
    const projected = {
      path: boundedText(loadError.path, () => { textFieldsOmitted += 1; }),
      error: boundedText(loadError.error, () => { textFieldsOmitted += 1; }),
    };
    const bytes = Buffer.byteLength(JSON.stringify(projected));
    if (encodedBytes + (projectedLoadErrors.length > 0 ? 1 : 0) + bytes + suffixBytes > MAX_HOOK_PROJECTION_BYTES) {
      textFieldsOmitted += 1;
      continue;
    }
    projectedLoadErrors.push(projected);
    retainedLoadErrors += 1;
    encodedBytes += (projectedLoadErrors.length > 1 ? 1 : 0) + bytes;
  }
  if (loadErrors.length > GENERIC_RESOURCE_ARRAY_LIMIT) textFieldsOmitted += 1;
  encodedBytes += suffixBytes;

  const totalHookHandlerEvents = extensions.reduce((total, extension) => total + extension.handlers.size, 0);
  return {
    extensions: projectedExtensions,
    extensionLoadErrors: projectedLoadErrors,
    hookInventory: {
      extensions: {
        total: extensions.length,
        retained: retainedExtensions,
        omitted: omittedExtensionCount,
      },
      handlerEvents: {
        total: totalHookHandlerEvents,
        retained: retainedHandlerEvents,
        omitted: totalHookHandlerEvents - retainedHandlerEvents,
      },
      loadErrors: {
        total: loadErrors.length,
        retained: retainedLoadErrors,
        omitted: loadErrors.length - retainedLoadErrors,
      },
      textFieldsOmitted,
      encodedBytes,
      encodedBytesLimit: MAX_HOOK_PROJECTION_BYTES,
    },
  };
}
