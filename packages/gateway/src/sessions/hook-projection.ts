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

interface HookProjectionLoadError {
  path: string;
  error: string;
}

const MAX_HOOK_HANDLER_EVENTS_PER_EXTENSION = 512;
const MAX_HOOK_STRING_CHARACTERS = 16 * 1_024;
export const MAX_HOOK_PROJECTION_BYTES = 256 * 1_024;
const GENERIC_RESOURCE_ARRAY_LIMIT = 1_000;

interface HookRegistrationProjection {
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

/** Reserve identities before optional inventories. Byte accounting only adds
 * the serialized new item and its comma: never re-encode the growing envelope
 * for each handler/tool. Input rows retain their original source association
 * even when an oversized identity is skipped. */
export function projectHookRegistrations(
  extensions: readonly HookProjectionExtension[],
  loadErrors: readonly HookProjectionLoadError[],
): HookRegistrationProjection {
  type Row = { name: string; path: string; resolvedPath: string; scope: string; source: string; origin: string;
    tools: string[]; commands: string[]; handlers: Array<{ event: string; count: number }> };
  const admitted: Array<{ source: HookProjectionExtension; row: Row }> = [];
  const extensionLoadErrors: Array<{ path: string; error: string }> = [];
  const bytes = (value: unknown): number => Buffer.byteLength(JSON.stringify(value));
  let encodedBytes = bytes({ extensions: [], extensionLoadErrors: [] });
  let textFieldsOmitted = 0;
  let retainedHandlerEvents = 0;
  const boundedText = (value: string): string => {
    if (value.length <= MAX_HOOK_STRING_CHARACTERS) return value;
    textFieldsOmitted += 1;
    return `${value.slice(0, MAX_HOOK_STRING_CHARACTERS)}…`;
  };
  const admit = <T>(target: T[], item: T): boolean => {
    const additional = bytes(item) + (target.length > 0 ? 1 : 0);
    if (encodedBytes + additional > MAX_HOOK_PROJECTION_BYTES) return false;
    target.push(item);
    encodedBytes += additional;
    return true;
  };
  const rows: Row[] = [];
  for (let index = 0; index < Math.min(extensions.length, GENERIC_RESOURCE_ARRAY_LIMIT); index += 1) {
    const source = extensions[index]!;
    const row: Row = {
      name: boundedText(source.name), path: boundedText(source.path), resolvedPath: boundedText(source.resolvedPath),
      scope: boundedText(source.scope), source: boundedText(source.source), origin: boundedText(source.origin),
      tools: [], commands: [], handlers: [],
    };
    // An impossible identity has no claim on the remaining budget. Continue so
    // it cannot hide an unrelated, small extension later in loader order.
    if (admit(rows, row)) admitted.push({ source, row });
  }
  for (const { source, row } of admitted) {
    let seen = 0;
    for (const [event, handlers] of source.handlers) {
      if (seen++ >= MAX_HOOK_HANDLER_EVENTS_PER_EXTENSION) break;
      if (event.length > MAX_HOOK_STRING_CHARACTERS) { textFieldsOmitted += 1; continue; }
      if (admit(row.handlers, { event, count: handlers.length })) retainedHandlerEvents += 1;
      else textFieldsOmitted += 1;
    }
    for (const field of ["tools", "commands"] as const) {
      let seenValues = 0;
      for (const value of source[field]) {
        if (seenValues++ >= GENERIC_RESOURCE_ARRAY_LIMIT) { textFieldsOmitted += 1; break; }
        if (!admit(row[field], boundedText(value))) { textFieldsOmitted += 1; break; }
      }
    }
  }
  for (let index = 0; index < Math.min(loadErrors.length, GENERIC_RESOURCE_ARRAY_LIMIT); index += 1) {
    const error = loadErrors[index]!;
    if (!admit(extensionLoadErrors, { path: boundedText(error.path), error: boundedText(error.error) })) textFieldsOmitted += 1;
  }
  if (extensions.length > GENERIC_RESOURCE_ARRAY_LIMIT || loadErrors.length > GENERIC_RESOURCE_ARRAY_LIMIT) textFieldsOmitted += 1;
  const totalHandlers = extensions.reduce((sum, extension) => sum + extension.handlers.size, 0);
  return {
    extensions: rows,
    extensionLoadErrors,
    hookInventory: {
      extensions: { total: extensions.length, retained: rows.length, omitted: extensions.length - rows.length },
      handlerEvents: { total: totalHandlers, retained: retainedHandlerEvents, omitted: totalHandlers - retainedHandlerEvents },
      loadErrors: { total: loadErrors.length, retained: extensionLoadErrors.length, omitted: loadErrors.length - extensionLoadErrors.length },
      textFieldsOmitted,
      encodedBytes,
      encodedBytesLimit: MAX_HOOK_PROJECTION_BYTES,
    },
  };
}
