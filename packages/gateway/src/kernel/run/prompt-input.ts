import { randomUUID } from "node:crypto";
import { GatewayError } from "../../errors.js";
import { admitResourceInvocations, composeResourcePrompt, parsePiLiteralCommand } from "../../sessions/resource-invocation.js";
import { invocationResources } from "./queue-commands.js";
import type { AgentSession, SettingsManager } from "../pi/coding-agent.js";
import type { ImageContent } from "../pi/ai.js";
import type { AgentMessage } from "../pi/agent-core.js";
import type { ChatOrigin, JsonValue, PendingPromptState, ResourceInvocation, SessionOperationState, SessionPhase } from "../../protocol/types.js";
import type { TrustService } from "../../admin/trust-service.js";
import type { ExtensionLifecycleCoordinator } from "../../sessions/extension-lifecycle-coordinator.js";
import type { ResourceExpansionCatalog } from "../../sessions/resource-invocation.js";
import type { ModuleHost, AgentTerminalOutcome, ContextPolicyLifecycle } from "../host/module-host.js";
import type { RequestPolicy } from "../host/request-policy.js";
import type { InputTrigger } from "../host/input-admission.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import type { CompactionOperationPolicy } from "./compaction-policy.js";
import type { RunAbortOwner } from "./run-abort-owner.js";
import type { RunQueueOwner } from "./run-queue-owner.js";
import type { RunWorkOwner } from "./run-work-owner.js";
import type { HeldPromptQueue } from "./held-prompt-queue.js";
import type { PromptAttempt, PromptAttemptInput } from "./prompt-attempt.js";
import { makeInvocationReceipt, type InvocationProjection, type OwnedOperationTerminal } from "./invocation-receipts.js";
import { MAXIMUM_PROMPT_ATTACHMENTS, type PromptQueueDisplay, type QueueBehavior, type RuntimeQueuedMessage } from "./queue-input.js";

/** Live bindings to the frame and existing owners; no copied admission state. */
export interface PromptAdmissionContext<TaskFence, Completion> {
  runtime: { session: AgentSession };
  dependencies: { trust: Pick<TrustService, "requireResolved">; modules: ModuleHost; beforeRunAdmission(id: string): Promise<void> };
  id: string;
  cwd: string;
  revision: number;
  phase: SessionPhase;
  operation: SessionOperationState | undefined;
  activeOperationId: string | undefined;
  pendingPrompt: PendingPromptState | undefined;
  pendingPromptMessage: AgentMessage | undefined;
  pendingExtensionCommand: SessionOperationState | undefined;
  operationWasHomeWake: boolean;
  readonly pendingAssistantCompletion: Completion | undefined;
  readonly attentionBarrier: Promise<void> | undefined;
  readonly completionOwnershipQueue: { readonly length: number };
  readonly isAgentAdmissionSettling: boolean;
  readonly hasActiveAgentRun: boolean;
  readonly queuedManualCompactionInFlight: boolean;
  readonly shuttingDown: boolean;
  readonly taskWorker: { identity: { taskId: string; operationId: string }; acceptsSteering: boolean } | undefined;
  readonly taskWait: { wakeOperationId?: string } | undefined;
  readonly homeRequestPolicy: RequestPolicy | undefined;
  readonly sessionFile: string | undefined;
  readonly canonicalEntryCount: number;
  readonly lifecycle: ExtensionLifecycleCoordinator;
  readonly runAbort: RunAbortOwner;
  readonly runQueue: RunQueueOwner;
  readonly runWork: RunWorkOwner;
  readonly heldQueue: HeldPromptQueue;
  readonly invocations: Map<string, InvocationProjection>;
  readonly ownedTerminalObservers: Map<string, (terminal: OwnedOperationTerminal) => Promise<void> | void>;
  readonly compactionPolicies: WeakMap<AgentSession, CompactionOperationPolicy>;
  readonly contextPolicies: WeakMap<AgentSession, Pick<ContextPolicyLifecycle, "apply">>;
  readonly lane: { run<T>(work: () => Promise<T>): Promise<T> };
  readonly hooks: { settled(id: string): void };
  readonly inboxAttributedMessages: Set<string>;
  assertUsable(): void;
  assertHomePromptAdmission(): void;
  assertHomeWakeAdmissible(session: AgentSession): Promise<void>;
  attentionPendingError(): Error;
  liveTaskOperationId(): string | undefined;
  sharedTaskSteering(ownership: PromptOwnership<TaskFence> | undefined): boolean;
  persistTaskMarker(operationId: string): Promise<void>;
  noteAcceptedSteering(operationId: string): void;
  waitForStateChange(): Promise<void>;
  applyLiveRunSettings(session: AgentSession): Promise<ReturnType<SettingsManager["getSettings"]> | undefined>;
  assertInvocableResources(resources: readonly ResourceInvocation[]): void;
  resourceExpansionCatalog(): ResourceExpansionCatalog;
  invocationForOperation(operationId: string): InvocationProjection | undefined;
  extensionCommandOrigin(name: string): ChatOrigin;
  promptDisplay(operationId: string, text: string, images: ImageContent[], display?: PromptQueueDisplay): PendingPromptState;
  persistInvocationReceipt(receipt: ReturnType<typeof makeInvocationReceipt>, owner?: GatewayWorkHandle): Promise<void>;
  persistCanonicalCustomEntry(type: string, data: JsonValue, identity: string): Promise<void>;
  enqueueMarkerOwnership(operationId: string): Promise<void>;
  clearMarkerOwnership(operationId: string): Promise<void>;
  notifyOwnedTerminal(terminal: OwnedOperationTerminal): Promise<void>;
  notifyAgentTerminal(id: string, outcome: AgentTerminalOutcome): Promise<void>;
  completionObserved(id: string): void;
  terminalizeInvocation(operationId: string, lifecycle: "failed", errorCode?: string, owner?: GatewayWorkHandle): Promise<void>;
  startHomeWake(session: AgentSession, operationId: string, trigger: InputTrigger | undefined, accepted: (value: boolean) => void): Promise<void>;
  createAttempt(sdkRun: Promise<void>, input: PromptAttemptInput, queuesIntoActiveRun: () => boolean): PromptAttempt<Completion>;
  publishSnapshot(): void;
  emit(topic: string, data: JsonValue): void;
}

interface AutomationPromptOwnership<TaskFence> {
  kind?: never;
  operationId: string;
  taskFence?: TaskFence;
  /** Exact scheduler admission cancellation, fenced again at SDK preflight. */
  signal?: AbortSignal;
  origin: ChatOrigin;
  onAdmitted?: (invocationId: string) => void;
  onTerminal: (terminal: OwnedOperationTerminal) => Promise<void> | void;
}

/** A Home wake: Gateway-authored, with no user input. The inbox's trigger result starts the run. */
interface HomeWakeOwnership {
  kind: "homeWake";
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


export function preparePromptInput<TaskFence, Completion>(
  context: PromptAdmissionContext<TaskFence, Completion>, session: AgentSession,
  text: string, images: ImageContent[], queueDisplay: PromptQueueDisplay | undefined,
  ownership: PromptOwnership<TaskFence> | undefined,
) {
  if (queueDisplay?.attachments !== undefined
    && (queueDisplay.attachments.length > MAXIMUM_PROMPT_ATTACHMENTS
      || queueDisplay.attachments.length !== queueDisplay.attachmentCount)) {
    throw new GatewayError("invalid_request", "Prompt attachment descriptors do not match the bounded attachment count");
  }
  const resources = queueDisplay?.resourceInvocations;
  // Skills and prompts the runtime expands itself; an extension command is Pi's literal command text.
  const composedResources = resources?.[0]?.source === "extension" ? undefined : resources;
  if (resources !== undefined) {
    admitResourceInvocations(resources, queueDisplay!.text);
    if (composedResources === undefined && (images.length > 0 || (queueDisplay!.attachments?.length ?? 0) > 0)) {
      throw new GatewayError("invalid_request", "Extension commands cannot include attachments");
    }
    context.assertInvocableResources(resources);
  }
  // Every caller passes the visible prompt; the expansions are composed
  // here, in the lane, against the catalog just validated.
  if (composedResources !== undefined) {
    text = composeResourcePrompt(composedResources, text, context.resourceExpansionCatalog());
  }
  // Pi uses the first literal ASCII space as its command
  // delimiter. Keep admission byte-for-byte identical: tabs/newlines are
  // part of the command name and therefore remain ordinary prompt text.
  // A composed message is never a command, whatever its text begins with.
  const parsedCommand = ownership?.kind === "subagentWake" || ownership?.kind === "homeWake" || composedResources !== undefined
    ? undefined : parsePiLiteralCommand(text);
  const extensionCommandName = parsedCommand?.name;
  const isExactExtensionCommand = extensionCommandName !== undefined
    && session.extensionRunner.getCommand(extensionCommandName) !== undefined;
  // Scheduled plain text can resolve to a command even without a typed
  // resource. Gate the actual capability in the serialized runtime owner,
  // before effects, markers or automation completion observers are admitted.
  if (ownership && isExactExtensionCommand) {
    throw new GatewayError("invalid_request", "Extension commands cannot be scheduled");
  }
  return { text, resources, composedResources, extensionCommandName, isExactExtensionCommand };
}

export function preparePromptIntent<TaskFence, Completion>(
  context: PromptAdmissionContext<TaskFence, Completion>, session: AgentSession,
  text: string, images: ImageContent[], behavior: QueueBehavior | undefined,
  queueDisplay: PromptQueueDisplay | undefined, ownership: PromptOwnership<TaskFence> | undefined,
  operationId: string, redelivery: RuntimeQueuedMessage | undefined,
  prepared: ReturnType<typeof preparePromptInput<TaskFence, Completion>>,
) {
  const { resources, composedResources, extensionCommandName, isExactExtensionCommand } = prepared;
  const existingInvocation = redelivery ? context.invocationForOperation(operationId) : undefined;
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
  // A composed message's canonical text is its expansions followed by this text.
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
      ? context.extensionCommandOrigin(invocationName)
      : { kind: "user", confidence: "boundary" }),
    sequence: context.revision + 1,
    updatedAt: new Date().toISOString(),
  };
  if (session.isStreaming && !behavior && !isExactExtensionCommand) {
    if (!redelivery) context.invocations.delete(invocationId);
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

export function promptStartReceipt<TaskFence, Completion>(
  context: PromptAdmissionContext<TaskFence, Completion>, operationId: string,
  intent: ReturnType<typeof preparePromptIntent<TaskFence, Completion>>,
): ReturnType<typeof makeInvocationReceipt> {
  const { invocationId, invocationSource, invocationName, extensionArguments, invokedResources, submittedText, invocation } = intent;
  return makeInvocationReceipt({
    version: 1,
    receiptId: `start:${invocationId}`,
    receiptKind: "start",
    invocationId,
    operationId,
    sessionId: context.id,
    source: invocationSource,
    ...(invocationName ? { name: invocationName } : {}),
    ...(extensionArguments ? { arguments: extensionArguments } : {}),
    ...(invokedResources === undefined ? {} : { resources: invokedResources }),
    ...(submittedText === undefined ? {} : { submittedText }),
    lifecycle: "staged",
    origin: invocation.origin,
    sequence: context.revision + 1,
    createdAt: new Date().toISOString(),
  });
}
