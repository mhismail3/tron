import type { RunOperations } from "./run-operations.js";
import type { RequestPolicy } from "../host/request-policy.js";
import { randomUUID } from "node:crypto";
import { GatewayError } from "../../errors.js";
import { admitResourceInvocations, parsePiLiteralCommand } from "../resources/resource-invocation.js";
import { composeResourcePrompt } from "../resources/resource-expansion.js";
import { invocationResources } from "./queue-commands.js";
import type { AgentSession} from "../pi/coding-agent.js";
import type { ImageContent } from "../pi/ai.js";
import type { ChatOrigin} from "../../protocol/types.js";
import { makeInvocationReceipt, type InvocationProjection } from "../receipts/invocation-receipts.js";
import type { OwnedOperationTerminal } from "../delegation/owned-operation-terminal.js";
import { MAXIMUM_PROMPT_ATTACHMENTS } from "../resources/prompt-bounds.js";
import type { PromptQueueDisplay, QueueBehavior, RuntimeQueuedMessage } from "./queue-input.js";


interface AutomationPromptOwnership<TaskFence> {
  kind?: never;
  operationId: string;
  originalText?: string;
  taskFence?: TaskFence;
  signal?: AbortSignal;
  origin: ChatOrigin;
  onAdmitted?: (invocationId: string) => void;
  onTerminal: (terminal: OwnedOperationTerminal) => Promise<void> | void;
}

interface HomeWakeOwnership {
  kind: "homeWake";
  inputCancellation: RequestPolicy["inputCancellation"];
  cancellationEpoch: number;
  operationId: string;
  origin: ChatOrigin;
  onDelivered: (delivered: boolean) => void;
  taskFence?: never;
  expandPromptTemplates?: never;
  signal?: never;
  onAdmitted?: never;
  onTerminal?: never;
}

export type PromptOwnership<TaskFence> = AutomationPromptOwnership<TaskFence> | HomeWakeOwnership | {
  kind: "subagentWake";
  taskFence?: never;
  expandPromptTemplates: boolean;
  operationId: string;
  origin: ChatOrigin;
  signal?: never;
  onAdmitted?: never;
  onTerminal?: never;
};


export function preparePromptInput<TaskFence>(
  operations: RunOperations<unknown>, session: AgentSession,
  text: string, images: ImageContent[], queueDisplay: PromptQueueDisplay | undefined,
  ownership: PromptOwnership<TaskFence> | undefined,
) {
  if (queueDisplay?.attachments !== undefined
    && (queueDisplay.attachments.length > MAXIMUM_PROMPT_ATTACHMENTS
      || queueDisplay.attachments.length !== queueDisplay.attachmentCount)) {
    throw new GatewayError("invalid_request", "Prompt attachment descriptors do not match the bounded attachment count");
  }
  const resources = queueDisplay?.resourceInvocations;
  const composedResources = resources?.[0]?.source === "extension" ? undefined : resources;
  if (resources !== undefined) {
    admitResourceInvocations(resources, queueDisplay!.text);
    if (composedResources === undefined && (images.length > 0 || (queueDisplay!.attachments?.length ?? 0) > 0)) {
      throw new GatewayError("invalid_request", "Extension commands cannot include attachments");
    }
    operations.assertInvocableResources(resources);
  }
  if (composedResources !== undefined) {
    text = composeResourcePrompt(composedResources, text, operations.resourceExpansionCatalog());
  }
  const parsedCommand = ownership?.kind === "subagentWake" || ownership?.kind === "homeWake" || composedResources !== undefined
    ? undefined : parsePiLiteralCommand(ownership?.originalText ?? text);
  const extensionCommandName = parsedCommand?.name;
  const isExactExtensionCommand = extensionCommandName !== undefined
    && session.extensionRunner.getCommand(extensionCommandName) !== undefined;
  if (ownership && isExactExtensionCommand) {
    throw new GatewayError("invalid_request", "Extension commands cannot be scheduled");
  }
  return { text, resources, composedResources, extensionCommandName, isExactExtensionCommand };
}

export function preparePromptIntent<TaskFence>(
  operations: RunOperations<unknown>, session: AgentSession,
  text: string, images: ImageContent[], behavior: QueueBehavior | undefined,
  queueDisplay: PromptQueueDisplay | undefined, ownership: PromptOwnership<TaskFence> | undefined,
  operationId: string, redelivery: RuntimeQueuedMessage | undefined,
  prepared: ReturnType<typeof preparePromptInput<TaskFence>>,
) {
  const { resources, composedResources, extensionCommandName, isExactExtensionCommand } = prepared;
  const existingInvocation = redelivery ? operations.runInvocations.invocationForOperation(operationId) : undefined;
  if (redelivery && !existingInvocation) {
    throw new GatewayError("conflict", "Accepted queued invocation identity is no longer available", true);
  }
  const invocationId = existingInvocation?.invocationId ?? randomUUID();
  const invocationSource: InvocationProjection["source"] = existingInvocation?.source ?? (ownership?.kind === "subagentWake" ? "subagentWake" : ownership?.kind === "homeWake" ? "homeWake" : isExactExtensionCommand
    ? "extension"
    : resources?.[0]?.source ?? "plain");
  const invocationName = existingInvocation?.name ?? (isExactExtensionCommand
    ? extensionCommandName
    : resources?.[0]?.name);
  const invokedResources = invocationResources(composedResources);
  const extensionArguments = composedResources === undefined ? resources?.[0]?.arguments : undefined;
  const submittedText = images.length > 0 || composedResources !== undefined ? queueDisplay?.text ?? text : undefined;
  const invocation: InvocationProjection = existingInvocation ?? {
    version: 1,
    invocationId,
    operationId,
    source: invocationSource,
    ...(invocationName ? { name: invocationName } : {}),
    ...(extensionArguments === undefined ? {} : { arguments: extensionArguments }),
    ...(submittedText === undefined ? {} : { submittedText }),
    ...(resources === undefined ? {} : { resourceInvocations: resources }),
    lifecycle: "staged",
    origin: ownership?.origin ?? (invocationSource === "extension" && invocationName
      ? operations.extensionCommandOrigin(invocationName)
      : { kind: "user", confidence: "boundary" }),
    sequence: operations.revision + 1,
    updatedAt: new Date().toISOString(),
  };
  if (session.isStreaming && !behavior && !isExactExtensionCommand) {
    if (!redelivery) operations.runInvocations.invocations.delete(invocationId);
    throw new GatewayError("busy", "Session is running; choose steer or follow-up");
  }
  const queueAdmissionDisplay = queueDisplay ?? {
    text,
    attachmentEnvelope: "",
    attachmentCount: images.length,
    ...(images.length > 0 ? { photoCount: images.length } : {}),
    ...(images.length > 0 ? { fileAttachmentCount: 0 } : {}),
  };
  return { invocationId, invocationSource, invocationName, invokedResources, extensionArguments, submittedText, invocation, queueAdmissionDisplay };
}

export function promptStartReceipt<TaskFence>(
  operations: RunOperations<unknown>, operationId: string,
  intent: ReturnType<typeof preparePromptIntent<TaskFence>>,
): ReturnType<typeof makeInvocationReceipt> {
  const { invocationId, invocationSource, invocationName, extensionArguments, invokedResources, submittedText, invocation } = intent;
  return makeInvocationReceipt({
    version: 1,
    receiptId: `start:${invocationId}`,
    receiptKind: "start",
    invocationId,
    operationId,
    sessionId: operations.id,
    source: invocationSource,
    ...(invocationName ? { name: invocationName } : {}),
    ...(extensionArguments ? { arguments: extensionArguments } : {}),
    ...(invokedResources === undefined ? {} : { resources: invokedResources }),
    ...(submittedText === undefined ? {} : { submittedText }),
    lifecycle: "staged",
    origin: invocation.origin,
    sequence: operations.revision + 1,
    createdAt: new Date().toISOString(),
  });
}
