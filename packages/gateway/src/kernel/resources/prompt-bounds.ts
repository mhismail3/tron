import { DEFAULT_MAX_UPLOAD_BYTES } from "../../config.js";

export const PROMPT_TEXT_MAX_BYTES = 192 * 1_024;

export const MAXIMUM_PROMPT_ATTACHMENTS = 10;
export const INLINE_IMAGE_BASE64_LIMIT_BYTES = 4.5 * 1_048_576;
const ENVELOPE_BYTES_PER_ATTACHMENT = 6 * (160 * 4 + 200 + 1_024) + 128;

function maximumPromptLineBytes(maximumUploadBytes: number, maximumTextBytes: number): number {
  const inlineImages = Math.max(
    4 * Math.ceil(maximumUploadBytes / 3) + 4 * MAXIMUM_PROMPT_ATTACHMENTS,
    MAXIMUM_PROMPT_ATTACHMENTS * INLINE_IMAGE_BASE64_LIMIT_BYTES,
  );
  return inlineImages + 6 * maximumTextBytes + MAXIMUM_PROMPT_ATTACHMENTS * ENVELOPE_BYTES_PER_ATTACHMENT;
}

export const CANONICAL_SOURCE_MAX_LINE_BYTES = maximumPromptLineBytes(DEFAULT_MAX_UPLOAD_BYTES, PROMPT_TEXT_MAX_BYTES);
