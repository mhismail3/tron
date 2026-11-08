// The pi-ai half of the Pi seam (K-0 §4): every name the Gateway uses from
// `@earendil-works/pi-ai`. No patched API.
import { Type, type TUnsafe } from "typebox";

export {
  clampThinkingLevel,
  getCurrentSystemMessage,
  getCurrentTools,
  getSupportedThinkingLevels,
  isRetryableAssistantError,
  lazyStream,
  normalizeContext,
} from "@earendil-works/pi-ai";
// pi-ai 1.5 no longer re-exports TypeBox, and its StringEnum returns a pi-schema schema.
// Tool schemas stay TypeBox (JSON Schema, which Pi validates), from the exact TypeBox the
// pinned pi-coding-agent depends on; StringEnum is the TypeBox form Pi gives extensions
// (its pi-ai extension view), with the same `{ type: "string", enum }` JSON.
export { Type };
export type { Static, TSchema } from "typebox";
export function StringEnum<T extends readonly string[]>(values: T, options?: { description?: string; default?: T[number] }): TUnsafe<T[number]> {
  return Type.Unsafe<T[number]>({
    type: "string",
    enum: values,
    ...(options?.description && { description: options.description }),
    ...(options?.default && { default: options.default }),
  });
}
export type {
  AnyModel,
  Api,
  AssistantMessage,
  AssistantMessageEvent,
  AssistantMessageEventStream,
  AuthEvent,
  AuthInteraction,
  AuthPrompt,
  AuthType,
  ClassifierContext,
  Context,
  Credential,
  FetchFunction,
  ImageContent,
  Message,
  Model,
  ModelThinkingLevel,
  Provider,
  SimpleStreamOptions,
  ThinkingLevel,
  Usage,
} from "@earendil-works/pi-ai";
