import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Extension, ExtensionContext, ExtensionUIContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { ExtensionFormAnswer, ExtensionFormDescriptor } from "../protocol/types.js";
import { EXTENSION_FORM_MAX_INTERACTION_BYTES } from "./semantic-form.js";
import type { FormRequest } from "../sessions/extension-adapter-contract.js";
import { TRON_FORM_REQUEST } from "../sessions/extension-adapter-contract.js";

const ASK_USER_MARKER = "\0XYZ_ASK_USER";
export const AUDITED_ASK_USER_PACKAGE = Object.freeze({
  name: "@zhushanwen/pi-ask-user",
  version: "7.0.15",
  source: "npm:@zhushanwen/pi-ask-user@7.0.15",
  integrity: "sha512-FqsIq4cOXVVX12Jotdj4o9BkZBa5DC/8Hg9w5yhxl+AmsA8UGX3a5kpThCzmFdf0lxaVaWN5/plAsJBSdWjZ3g==",
  protocolPackage: "@xyz-agent/extension-protocol",
  protocolVersion: "0.7.0",
  protocolIntegrity: "sha512-08cGiK4NEwdqBRJRemyphlLLWKxG+8uaM+Fk3r95qi9eNVmP7l5hRfWGcJIYYkaseSv3S+GGfFAeBXth8x6rAw==",
});

type DialogOptions = { signal?: AbortSignal };
type AskUserUI = ExtensionUIContext & { [TRON_FORM_REQUEST]?: FormRequest };
type ProtoOption = { label: string; description?: string };
type ProtoQuestion = {
  header?: string;
  question: string;
  context?: string;
  options: ProtoOption[];
  multiSelect?: boolean;
  allowOther?: boolean;
};
type ProtoPayload = { questions: ProtoQuestion[]; allowCancel: boolean };

export interface ExtensionAdapterHooks {
  /** Exact ask_user admission seam. Failures are deliberately detached from the form. */
  askPresented?: (input: { toolCallId: string }) => void | Promise<void>;
}

interface ExtensionToolAdapter {
  matches(extension: Extension, name: string, definition: ToolDefinition): boolean;
  adapt(extension: Extension, name: string, definition: ToolDefinition, hooks: ExtensionAdapterHooks): ToolDefinition;
}

const EXTENSION_TOOL_ADAPTERS: readonly ExtensionToolAdapter[] = [
  { matches: isZhushanwenAskUser, adapt: adaptZhushanwenAskUser },
];

export function adaptedToolDefinition(
  extension: Extension,
  name: string,
  definition: ToolDefinition,
  hooks: ExtensionAdapterHooks = {},
): ToolDefinition {
  const adapter = EXTENSION_TOOL_ADAPTERS.find((candidate) => candidate.matches(extension, name, definition));
  return adapter ? adapter.adapt(extension, name, definition, hooks) : definition;
}

/**
 * Event contexts are adapted at the trusted load boundary as well as tool
 * execution. The package captures its session_start context in a channel
 * handler, so adapting only execute() would leave subagent-forwarded forms on
 * the opaque marker select path.
 */
export function adaptedExtensionEventHandler<T extends (...args: any[]) => any>(extension: Extension, handler: T): T {
  if (!isZhushanwenExtension(extension)) return handler;
  return ((...args: Parameters<T>) => handler(...args.map((arg) => adaptContextValue(arg)))) as T;
}

function adaptZhushanwenAskUser(
  _extension: Extension,
  _name: string,
  definition: ToolDefinition,
  hooks: ExtensionAdapterHooks,
): ToolDefinition {
  const original = definition.execute;
  return {
    ...definition,
    executionMode: "sequential",
    execute: async (...args: Parameters<ToolDefinition["execute"]>) => {
      const ctx = args[4] as ExtensionContext | undefined;
      if (!ctx?.ui) return original(...args);
      let didPresent = false;
      const presented = typeof args[0] === "string" && hooks.askPresented
        ? () => {
            if (didPresent) return;
            didPresent = true;
            return hooks.askPresented!({ toolCallId: args[0] as string });
          }
        : undefined;
      const adaptedArgs = [...args] as Parameters<ToolDefinition["execute"]>;
      adaptedArgs[4] = adaptContext(ctx, args[2] as AbortSignal | undefined, presented) as Parameters<ToolDefinition["execute"]>[4];
      return original(...adaptedArgs);
    },
  };
}

function isZhushanwenAskUser(extension: Extension, name: string, definition: ToolDefinition): boolean {
  return isZhushanwenExtension(extension)
    && name === "ask_user"
    && definition.name === "ask_user"
    && typeof definition.execute === "function"
    && isAuditedAskUserSchema(definition.parameters);
}

function isAuditedAskUserSchema(value: unknown): boolean {
  const parameters = record(value);
  const rootProperties = record(parameters?.properties);
  const questions = record(rootProperties?.questions);
  const question = record(questions?.items);
  const questionProperties = record(question?.properties);
  const options = record(questionProperties?.options);
  const optionUnion = record(options?.items);
  const optionVariants = Array.isArray(optionUnion?.anyOf) ? optionUnion.anyOf.map(record) : [];
  const optionObject = optionVariants.find((variant) => variant?.type === "object");
  const optionString = optionVariants.find((variant) => variant?.type === "string");
  const optionProperties = record(optionObject?.properties);
  return parameters?.type === "object"
    && exactPropertyKeys(rootProperties, ["questions"])
    && exactRequired(parameters?.required, ["questions"])
    && parameters.additionalProperties === undefined
    && questions?.type === "array"
    && questions.minItems === 1
    && questions.maxItems === 4
    && question?.type === "object"
    && exactPropertyKeys(questionProperties, ["question", "header", "context", "options", "multiSelect"])
    && exactRequired(question.required, ["question", "options"])
    && question.additionalProperties === undefined
    && record(questionProperties?.question)?.type === "string"
    && record(questionProperties?.header)?.type === "string"
    && record(questionProperties?.context)?.type === "string"
    && record(questionProperties?.multiSelect)?.type === "boolean"
    && options?.type === "array"
    && options.minItems === 2
    && options.maxItems === 4
    && optionVariants.length === 2
    && optionString?.type === "string"
    && optionObject?.type === "object"
    && exactPropertyKeys(optionProperties, ["label", "description"])
    && exactRequired(optionObject?.required, ["label"])
    && optionObject?.additionalProperties === undefined
    && record(optionProperties?.label)?.type === "string"
    && record(optionProperties?.description)?.type === "string";
}

function record(value: unknown): Record<string, any> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : undefined;
}

function exactPropertyKeys(value: Record<string, unknown> | undefined, expected: string[]): boolean {
  return value !== undefined && Object.keys(value).sort().join("\0") === [...expected].sort().join("\0");
}

function exactRequired(value: unknown, expected: string[]): boolean {
  return Array.isArray(value)
    && value.every((item) => typeof item === "string")
    && [...value].sort().join("\0") === [...expected].sort().join("\0");
}

function isZhushanwenExtension(extension: Extension): boolean {
  const source = extension.sourceInfo;
  const paths = [source.baseDir, source.path, extension.path, extension.resolvedPath];
  const sourcePath = paths.map((value) => value ?? "").join("\n").replaceAll("\\", "/");
  // Pi invokes extensionsOverride immediately before applying canonical package
  // SourceInfo. Admit that exact loader-owned provisional shape only when the
  // installed manifest, lock integrities, and owning settings pin all agree.
  const canonicalSource = source.origin === "package"
    && (source.scope === "user" || source.scope === "project")
    && source.source === AUDITED_ASK_USER_PACKAGE.source;
  const provisionalLoaderSource = source.origin === "top-level"
    && source.scope === "temporary"
    && source.source === "local";
  return (canonicalSource || provisionalLoaderSource)
    && sourcePath.split("\n").some((value) => value.includes("/node_modules/@zhushanwen/pi-ask-user/")
      || value.endsWith("/node_modules/@zhushanwen/pi-ask-user"))
    && auditedPackageInstallation(paths);
}

function auditedPackageInstallation(paths: Array<string | undefined>): boolean {
  for (const candidate of paths) {
    if (!candidate) continue;
    const normalized = candidate.replaceAll("\\", "/");
    const marker = `/node_modules/${AUDITED_ASK_USER_PACKAGE.name}`;
    const packageIndex = normalized.indexOf(marker);
    if (packageIndex < 0) continue;
    const packageRoot = normalized.slice(0, packageIndex + marker.length);
    const npmRoot = dirname(packageRoot.slice(0, packageIndex + "/node_modules".length));
    try {
      const manifest = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8")) as Record<string, any>;
      const lock = JSON.parse(readFileSync(join(npmRoot, "package-lock.json"), "utf8")) as { packages?: Record<string, Record<string, any>> };
      const settings = JSON.parse(readFileSync(join(dirname(npmRoot), "settings.json"), "utf8")) as { packages?: Array<string | { source?: unknown }> };
      const pinnedInSettings = settings.packages?.some((entry) => (typeof entry === "string" ? entry : entry?.source) === AUDITED_ASK_USER_PACKAGE.source) === true;
      const locked = lock.packages?.[`node_modules/${AUDITED_ASK_USER_PACKAGE.name}`];
      const lockedProtocol = [
        lock.packages?.[`node_modules/${AUDITED_ASK_USER_PACKAGE.protocolPackage}`],
        lock.packages?.[`node_modules/${AUDITED_ASK_USER_PACKAGE.name}/node_modules/${AUDITED_ASK_USER_PACKAGE.protocolPackage}`],
      ].find((entry) => entry?.version === AUDITED_ASK_USER_PACKAGE.protocolVersion
        && entry.integrity === AUDITED_ASK_USER_PACKAGE.protocolIntegrity);
      if (pinnedInSettings
        && manifest.name === AUDITED_ASK_USER_PACKAGE.name
        && manifest.version === AUDITED_ASK_USER_PACKAGE.version
        && manifest.dependencies?.[AUDITED_ASK_USER_PACKAGE.protocolPackage] === AUDITED_ASK_USER_PACKAGE.protocolVersion
        && locked?.version === AUDITED_ASK_USER_PACKAGE.version
        && locked.integrity === AUDITED_ASK_USER_PACKAGE.integrity
        && lockedProtocol !== undefined) return true;
    } catch { /* An unverifiable install is deliberately not adapted. */ }
  }
  return false;
}

function adaptContextValue(value: unknown): unknown {
  if (!value || typeof value !== "object" || !("ui" in value)) return value;
  const context = value as ExtensionContext;
  return context.ui ? adaptContext(context) : value;
}

function adaptContext(
  context: ExtensionContext,
  outerSignal?: AbortSignal,
  presented?: () => void | Promise<void>,
): ExtensionContext {
  const ui = adaptUI(context.ui as AskUserUI, outerSignal, presented);
  return new Proxy(context, {
    get(target, property, receiver) {
      if (property === "ui") return ui;
      return Reflect.get(target, property, receiver);
    },
  });
}

function adaptUI(
  base: AskUserUI,
  outerSignal?: AbortSignal,
  presented?: () => void | Promise<void>,
): AskUserUI {
  return new Proxy(base, {
    get(target, property, receiver) {
      if (property !== "select") return Reflect.get(target, property, receiver);
      return async (title: string, options: string[], dialogOptions?: DialogOptions): Promise<string | undefined> => {
        if (title !== ASK_USER_MARKER) return base.select(title, options, dialogOptions);
        const request = base[TRON_FORM_REQUEST];
        if (!request) throw new Error("Tron semantic form host is unavailable");
        const payload = parseProtoPayload(options);
        const signal = dialogOptions?.signal ?? outerSignal;
        if (signal?.aborted) return undefined;
        const form = protoPayloadToForm(payload);
        const answer = await request({
          form,
          ...(signal === undefined ? {} : { signal }),
          ...(presented === undefined ? {} : { presented }),
        });
        if (signal?.aborted || answer === undefined) return undefined;
        return JSON.stringify(formAnswerToProto(payload.questions, form, answer));
      };
    },
  }) as AskUserUI;
}

function parseProtoPayload(options: unknown): ProtoPayload {
  if (!Array.isArray(options) || options.length !== 1 || typeof options[0] !== "string"
    || Buffer.byteLength(options[0], "utf8") > EXTENSION_FORM_MAX_INTERACTION_BYTES) throw malformedMarker();
  let value: unknown;
  try { value = JSON.parse(options[0]); } catch { throw malformedMarker(); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw malformedMarker();
  const payload = value as Record<string, unknown>;
  if (Object.keys(payload).some((key) => key !== "questions" && key !== "allowCancel")
    || !Array.isArray(payload.questions)
    || payload.questions.length < 1
    || payload.questions.length > 4
    || typeof payload.allowCancel !== "boolean") throw malformedMarker();
  const questions = payload.questions.map(parseProtoQuestion);
  assertDistinctProtoAnswerKeys(questions);
  return { questions, allowCancel: payload.allowCancel };
}

function parseProtoQuestion(value: unknown): ProtoQuestion {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw malformedMarker();
  const question = value as Record<string, unknown>;
  if (Object.keys(question).some((key) => !["header", "question", "context", "options", "multiSelect", "allowOther"].includes(key))
    || typeof question.question !== "string"
    || (question.header !== undefined && typeof question.header !== "string")
    || (question.context !== undefined && typeof question.context !== "string")
    || !Array.isArray(question.options)
    || question.options.length < 2
    || question.options.length > 4
    || (question.multiSelect !== undefined && typeof question.multiSelect !== "boolean")
    || (question.allowOther !== undefined && typeof question.allowOther !== "boolean")) throw malformedMarker();
  const options = question.options.map((raw): ProtoOption => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw malformedMarker();
    const option = raw as Record<string, unknown>;
    if (Object.keys(option).some((key) => key !== "label" && key !== "description")
      || typeof option.label !== "string"
      || (option.description !== undefined && typeof option.description !== "string")) throw malformedMarker();
    return { label: option.label, ...(option.description === undefined ? {} : { description: option.description }) };
  });
  return {
    ...(question.header === undefined ? {} : { header: question.header }),
    question: question.question,
    ...(question.context === undefined ? {} : { context: question.context }),
    options,
    ...(question.multiSelect === undefined ? {} : { multiSelect: question.multiSelect }),
    ...(question.allowOther === undefined ? {} : { allowOther: question.allowOther }),
  };
}

function protoPayloadToForm(payload: ProtoPayload): ExtensionFormDescriptor {
  return {
    version: 1,
    title: payload.questions.length === 1 ? (payload.questions[0]!.header ?? "Question") : "Questions",
    allowCancel: payload.allowCancel,
    questions: payload.questions.map((question, questionIndex) => ({
      id: `question-${questionIndex}`,
      ...(question.header === undefined ? {} : { header: question.header }),
      question: question.question,
      ...(question.context === undefined ? {} : { context: question.context }),
      options: question.options.map((option, optionIndex) => ({
        id: `question-${questionIndex}-option-${optionIndex}`,
        label: option.label,
        ...(option.description === undefined ? {} : { description: option.description }),
      })),
      multiSelect: question.multiSelect === true,
      allowOther: question.allowOther !== false,
    })),
  };
}

function formAnswerToProto(
  protoQuestions: ProtoQuestion[],
  form: ExtensionFormDescriptor,
  answer: ExtensionFormAnswer,
): Record<string, string> {
  const byQuestion = new Map(answer.answers.map((item) => [item.questionId, item]));
  const result = Object.create(null) as Record<string, string>;
  form.questions.forEach((question, index) => {
    const source = protoQuestions[index]!;
    const value = byQuestion.get(question.id);
    if (!value) throw new Error("Tron semantic form answer is incomplete");
    const labels = value.optionIds.map((id) => {
      const optionIndex = question.options.findIndex((option) => option.id === id);
      if (optionIndex < 0) throw new Error("Tron semantic form answer references an unknown option");
      return source.options[optionIndex]!.label;
    });
    const key = source.header ?? source.question;
    if (labels.length > 0) result[key] = source.multiSelect === true ? JSON.stringify(labels) : labels[0]!;
    if (value.other !== undefined) result[`${key}__other`] = value.other;
  });
  return result;
}

function assertDistinctProtoAnswerKeys(questions: ProtoQuestion[]): void {
  const keys = new Set<string>();
  for (const question of questions) {
    if (question.question === "__proto__") throw malformedMarker();
    const key = question.header ?? question.question;
    const candidates = question.allowOther === false ? [key] : [key, `${key}__other`];
    if (candidates.some((candidate) => keys.has(candidate))) throw malformedMarker();
    candidates.forEach((candidate) => keys.add(candidate));
  }
}

function malformedMarker(): Error {
  return new Error("Unsupported @zhushanwen/pi-ask-user RPC form contract");
}
