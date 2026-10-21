import type { ImageContent } from "../pi/ai.js";
import type { QueuedMessageState, ResourceInvocation } from "../../protocol/types.js";

export const MAXIMUM_PROMPT_ATTACHMENTS = 10;

export type QueueBehavior = QueuedMessageState["behavior"];

export type RuntimeQueuedMessage = QueuedMessageState & {
  runtimeText: string;
  attachmentEnvelope: string;
  images: ImageContent[];
  inputSource: "interactive" | "rpc" | "extension";
  commandId?: string;
  ordinal: number;
};

/** A prompt accepted while compaction owns admission. Its RPC has already
 * returned; the Gateway owns its projection, edits and removal until it is
 * admitted through the ordinary prompt path after compaction. `admitting`
 * marks the head entry once that admission has captured its content. */
export type HeldPrompt = RuntimeQueuedMessage & { admitting: boolean };

/** Client-visible prompt content, separate from the Pi runtime text that may
 * carry a resource prefix and attachment envelope. */
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
