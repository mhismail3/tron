import type { ImageContent } from "../pi/ai.js";
import type { QueuedMessageState, ResourceInvocation } from "../../protocol/types.js";

export type QueueBehavior = QueuedMessageState["behavior"];

export type QueueAdmissionDisposition = "queued" | "foreground" | "handled" | "failed";

export type PendingQueueAdmission = Omit<RuntimeQueuedMessage, "runtimeText" | "ordinal"> & {
  redelivery?: boolean;
  resolveDisposition: (disposition: QueueAdmissionDisposition) => void;
};

export type RuntimeQueuedMessage = QueuedMessageState & {
  runtimeText: string;
  attachmentEnvelope: string;
  images: ImageContent[];
  inputSource: "interactive" | "rpc" | "extension";
  commandId?: string;
  ordinal: number;
};

export type HeldPrompt = RuntimeQueuedMessage & { admitting: boolean };

export type PromptQueueDisplay = {
  text: string;
  resourceInvocations?: ResourceInvocation[];
  attachmentEnvelope: string;
  attachmentCount: number;
  photoCount?: number;
  fileAttachmentCount?: number;
  attachments?: QueuedMessageState["attachments"];
  inputSource?: "interactive" | "rpc" | "extension";
  commandId?: string;
};
