import type { Extension, ExtensionUIContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { QuestionnaireRequest } from "../sessions/extension-adapter-contract.js";
import { TRON_QUESTIONNAIRE_REQUEST } from "../sessions/extension-adapter-contract.js";

type AskOption = { label: string; description?: string; preview?: string };
type AskParams = {
  question: string;
  context?: string;
  options: AskOption[];
  allowMultiple?: boolean;
  allowFreeform?: boolean;
  timeout?: boolean;
};
type NormalizedAsk = {
  question: string;
  context?: string;
  options: AskOption[];
  allowMultiple: boolean;
  allowFreeform: boolean;
};
type AskUI = ExtensionUIContext & { [TRON_QUESTIONNAIRE_REQUEST]?: QuestionnaireRequest };
type DialogOptions = { signal?: AbortSignal };

interface ExtensionToolAdapter {
  matches(extension: Extension, name: string, definition: ToolDefinition): boolean;
  adapt(extension: Extension, name: string, definition: ToolDefinition): ToolDefinition;
}

/** Explicit adapter registry. New package contracts must add a separate entry. */
const EXTENSION_TOOL_ADAPTERS: readonly ExtensionToolAdapter[] = [
  {
    matches: isPi9Ask,
    adapt: adaptPi9Ask,
  },
];

export function adaptedToolDefinition(extension: Extension, name: string, definition: ToolDefinition): ToolDefinition {
  const adapter = EXTENSION_TOOL_ADAPTERS.find((candidate) => candidate.matches(extension, name, definition));
  return adapter ? adapter.adapt(extension, name, definition) : definition;
}

function adaptPi9Ask(_extension: Extension, _name: string, definition: ToolDefinition): ToolDefinition {
  const original = definition.execute;
  return {
    ...definition,
    execute: async (...args: Parameters<ToolDefinition["execute"]>) => {
      const ctx = args[4] as { ui?: AskUI } | undefined;
      const params = normalizeAsk(args[1]);
      const request = ctx?.ui?.[TRON_QUESTIONNAIRE_REQUEST];
      if (!request || !params) return original(...args);
      const ui = new AskUIProxy(ctx.ui!, params, args[2] as AbortSignal | undefined, request);
      const adaptedContext = { ...ctx, ui: ui.proxy } as unknown as Parameters<ToolDefinition["execute"]>[4];
      const adaptedArgs = [...args] as Parameters<ToolDefinition["execute"]>;
      adaptedArgs[4] = adaptedContext;
      return original(...adaptedArgs);
    },
  };
}

function isPi9Ask(extension: Extension, name: string, definition: ToolDefinition): boolean {
  const source = extension.sourceInfo;
  const sourcePath = `${source.path ?? ""}\n${extension.path}\n${extension.resolvedPath}`.replaceAll("\\", "/");
  const inPackage = sourcePath.split("\n").some((value) => value.includes("/node_modules/@pi9/ask/") || value.endsWith("/node_modules/@pi9/ask"));
  const parameters = definition.parameters as { type?: unknown; properties?: Record<string, unknown>; required?: unknown[]; additionalProperties?: unknown } | undefined;
  const properties = parameters?.properties;
  const required = Array.isArray(parameters?.required) ? parameters.required : [];
  return name === "ask"
    && source.origin === "package"
    && (source.scope === "user" || source.scope === "project")
    && /^npm:@pi9\/ask(?:@[^\s]+)?$/.test(source.source)
    && inPackage
    && definition.name === "ask"
    && typeof definition.execute === "function"
    && parameters?.type === "object"
    && properties?.question !== undefined
    && properties?.options !== undefined
    && required.includes("question")
    && required.includes("options")
    && (parameters.additionalProperties === undefined || parameters.additionalProperties === false);
}

function normalizeAsk(value: unknown): NormalizedAsk | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const input = value as Record<string, unknown>;
  const allowed = new Set(["question", "context", "options", "allowMultiple", "allowFreeform", "timeout"]);
  if (Object.keys(input).some((key) => !allowed.has(key)) || typeof input.question !== "string" || !input.question.trim() || !Array.isArray(input.options) || input.options.length === 0) return undefined;
  if (input.context !== undefined && typeof input.context !== "string") return undefined;
  if (input.allowMultiple !== undefined && typeof input.allowMultiple !== "boolean") return undefined;
  if (input.allowFreeform !== undefined && typeof input.allowFreeform !== "boolean") return undefined;
  if (input.timeout !== undefined && typeof input.timeout !== "boolean") return undefined;
  const labels = new Set<string>();
  const options: AskOption[] = [];
  for (const raw of input.options) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
    const option = raw as Record<string, unknown>;
    if (Object.keys(option).some((key) => !["label", "description", "preview"].includes(key)) || typeof option.label !== "string") return undefined;
    const label = option.label.trim();
    if (!label || labels.has(label)) return undefined;
    labels.add(label);
    if (option.description !== undefined && typeof option.description !== "string") return undefined;
    if (option.preview !== undefined && typeof option.preview !== "string") return undefined;
    const description = typeof option.description === "string" ? option.description.trim() || undefined : undefined;
    const preview = typeof option.preview === "string" && option.preview.trim() ? option.preview : undefined;
    options.push({ label, ...(description === undefined ? {} : { description }), ...(preview === undefined ? {} : { preview }) });
  }
  const context = typeof input.context === "string" ? input.context.trim() || undefined : undefined;
  return {
    question: input.question.trim(),
    ...(context === undefined ? {} : { context }),
    options,
    allowMultiple: input.allowMultiple === true,
    allowFreeform: input.allowFreeform !== false,
  };
}

class AskUIProxy {
  private first = true;
  private firstMethod: "select" | "input" | undefined;
  private scripted: string[] = [];
  readonly proxy: AskUI;

  constructor(
    private readonly base: AskUI,
    private readonly params: NormalizedAsk,
    private readonly signal: AbortSignal | undefined,
    private readonly request: QuestionnaireRequest,
  ) {
    this.proxy = new Proxy(base, {
      get: (target, property, receiver) => {
        if (property === "select") return this.select.bind(this);
        if (property === "input") return this.input.bind(this);
        return Reflect.get(target, property, receiver);
      },
    }) as AskUI;
  }

  async select(title: string, options: string[], optionsArg?: DialogOptions): Promise<string | undefined> {
    if (!this.first) return this.consumeScriptOrSelect(title, options, optionsArg);
    this.first = false;
    this.firstMethod = "select";
    return this.beginStructured("select", title, options, undefined, optionsArg);
  }

  async input(title: string, placeholder?: string, optionsArg?: DialogOptions): Promise<string | undefined> {
    if (!this.first) return this.consumeScriptOrInput(title, placeholder, optionsArg);
    this.first = false;
    this.firstMethod = "input";
    return this.beginStructured("input", title, undefined, placeholder, optionsArg);
  }

  private async beginStructured(method: "select" | "input", title: string, options: string[] | undefined, placeholder: string | undefined, optionsArg?: DialogOptions): Promise<string | undefined> {
    const signal = optionsArg?.signal ?? this.signal;
    if (signal?.aborted) return undefined;
    const value = await this.request({
      title,
      method,
      ...(options === undefined ? {} : { primitiveOptions: options }),
      ...(placeholder === undefined ? {} : { placeholder }),
      question: this.params.question,
      ...(this.params.context === undefined ? {} : { context: this.params.context }),
      options: this.params.options,
      allowMultiple: this.params.allowMultiple,
      allowFreeform: this.params.allowFreeform,
      ...(signal === undefined ? {} : { signal }),
    });
    if (signal?.aborted) return undefined;
    if (typeof value === "string" || value === undefined) return value;
    return this.scriptStructured(value, options);
  }

  private consumeScriptOrSelect(title: string, options: string[], optionsArg?: DialogOptions): string | undefined | Promise<string | undefined> {
    if (this.signal?.aborted || optionsArg?.signal?.aborted) return undefined;
    const scripted = this.nextScripted();
    return scripted !== undefined ? scripted : this.base.select(title, options, optionsArg);
  }

  private consumeScriptOrInput(title: string, placeholder?: string, optionsArg?: DialogOptions): string | undefined | Promise<string | undefined> {
    if (this.signal?.aborted || optionsArg?.signal?.aborted) return undefined;
    const scripted = this.nextScripted();
    return scripted !== undefined ? scripted : this.base.input(title, placeholder, optionsArg);
  }

  private nextScripted(): string | undefined {
    return this.scripted.length > 0 ? this.scripted.shift() : undefined;
  }

  private scriptStructured(value: unknown, primitiveOptions: string[] | undefined): string | undefined {
    if (!value || typeof value !== "object" || Array.isArray(value) || !Array.isArray((value as { selections?: unknown }).selections)) return undefined;
    const answer = value as { selections: Array<{ option: number; comment?: string }>; freeform?: string };
    const selections = [...answer.selections].sort((left, right) => left.option - right.option);
    const clean = (text: string | undefined): string => text?.trim() ?? "";
    if (this.firstMethod === "select") {
      if (selections.length === 0) {
        if (!this.params.allowFreeform || answer.freeform === undefined || !primitiveOptions?.length) return undefined;
        this.scripted.push(clean(answer.freeform));
        return primitiveOptions[primitiveOptions.length - 1];
      }
      for (const selection of selections) this.scripted.push(clean(selection.comment));
      return primitiveOptions?.[selections[0]!.option];
    }
    const selected = selections.map((selection) => selection.option + 1).join(",");
    if (this.params.allowFreeform) this.scripted.push(clean(answer.freeform));
    for (const selection of selections) this.scripted.push(clean(selection.comment));
    return selected;
  }
}
