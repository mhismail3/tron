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
// session.resources is admitted by the existing generic safeJson array bound.
// Keep this local so hook omission accounting matches the wire without
// changing that shared projection contract.
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

/**
 * Projects the public loader registration map without serializing callbacks.
 * Existing extension rows are never cardinality-truncated or identity-trimmed;
 * only the additive handlers/errors are admitted to the bounded hook budget.
 */
export function projectHookRegistrations(
  extensions: readonly HookProjectionExtension[],
  loadErrors: readonly HookProjectionLoadError[],
): HookRegistrationProjection {
  const retainedHandlersByExtension: number[] = [];
  let omittedHookTextFields = 0;
  let hookProjectionBytes = 0;
  const totalHookHandlerEvents = extensions.reduce((total, extension) => total + extension.handlers.size, 0);
  const hookBytes = (value: unknown): number => Buffer.byteLength(JSON.stringify(value));

  const projectedExtensions = extensions.map((extension) => {
    const handlers: Array<{ event: string; count: number }> = [];
    for (const [event, registeredHandlers] of extension.handlers) {
      if (handlers.length >= MAX_HOOK_HANDLER_EVENTS_PER_EXTENSION || event.length > MAX_HOOK_STRING_CHARACTERS) {
        if (event.length > MAX_HOOK_STRING_CHARACTERS) omittedHookTextFields += 1;
        continue;
      }
      const projected = { event, count: registeredHandlers.length };
      const bytes = hookBytes(projected);
      if (hookProjectionBytes + bytes > MAX_HOOK_PROJECTION_BYTES) {
        continue;
      }
      hookProjectionBytes += bytes;
      handlers.push(projected);
    }
    retainedHandlersByExtension.push(handlers.length);
    return {
      name: extension.name,
      path: extension.path,
      resolvedPath: extension.resolvedPath,
      scope: extension.scope,
      source: extension.source,
      origin: extension.origin,
      tools: Array.from(extension.tools),
      commands: Array.from(extension.commands),
      handlers,
    };
  });

  const projectedLoadErrors: Array<{ path: string; error: string }> = [];
  for (const loadError of loadErrors) {
    const message = loadError.error.length > MAX_HOOK_STRING_CHARACTERS
      ? `${loadError.error.slice(0, MAX_HOOK_STRING_CHARACTERS)}…`
      : loadError.error;
    if (message !== loadError.error) omittedHookTextFields += 1;
    const projected = { path: loadError.path, error: message };
    const bytes = hookBytes(projected);
    if (hookProjectionBytes + bytes > MAX_HOOK_PROJECTION_BYTES) {
      continue;
    }
    hookProjectionBytes += bytes;
    projectedLoadErrors.push(projected);
  }

  return {
    extensions: projectedExtensions,
    extensionLoadErrors: projectedLoadErrors,
    hookInventory: {
      extensions: {
        total: extensions.length,
        retained: Math.min(extensions.length, GENERIC_RESOURCE_ARRAY_LIMIT),
        omitted: Math.max(0, extensions.length - GENERIC_RESOURCE_ARRAY_LIMIT),
      },
      handlerEvents: {
        total: totalHookHandlerEvents,
        retained: retainedHandlersByExtension
          .slice(0, GENERIC_RESOURCE_ARRAY_LIMIT)
          .reduce((total, count) => total + count, 0),
        omitted: totalHookHandlerEvents - retainedHandlersByExtension
          .slice(0, GENERIC_RESOURCE_ARRAY_LIMIT)
          .reduce((total, count) => total + count, 0),
      },
      loadErrors: {
        total: loadErrors.length,
        retained: Math.min(projectedLoadErrors.length, GENERIC_RESOURCE_ARRAY_LIMIT),
        omitted: loadErrors.length - Math.min(projectedLoadErrors.length, GENERIC_RESOURCE_ARRAY_LIMIT),
      },
      textFieldsOmitted: omittedHookTextFields,
      encodedBytes: hookProjectionBytes,
      encodedBytesLimit: MAX_HOOK_PROJECTION_BYTES,
    },
  };
}
