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
  TextContent,
  Tool,
  Usage,
} from "@earendil-works/pi-ai";
