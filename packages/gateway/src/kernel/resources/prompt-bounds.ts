import { DEFAULT_MAX_UPLOAD_BYTES } from "../../config.js";

/** The UTF-8 bytes one prompt's text may carry. Home's source bound is derived from it. */
export const PROMPT_TEXT_MAX_BYTES = 192 * 1_024;

/** Attachments one prompt may carry. Every prompt route admits at most this many. */
export const MAXIMUM_PROMPT_ATTACHMENTS = 10;
// Pi's inline image limit (pi-coding-agent `image-resize-core`, `DEFAULT_MAX_BYTES`):
// with auto-resize on, an image whose base64 reaches it is re-encoded below it, and
// one already within limits passes through only while it is below it.
export const INLINE_IMAGE_BASE64_LIMIT_BYTES = 4.5 * 1_048_576;
// An attachment's envelope entry carries its name (at most 160 characters, 4 bytes
// each), MIME type (at most 200) and owned path (at most 1 KiB), each escaped at up
// to six bytes per byte, plus the element's framing.
const ENVELOPE_BYTES_PER_ATTACHMENT = 6 * (160 * 4 + 200 + 1_024) + 128;

/**
 * The largest canonical line one prompt can write, which Home's source must read.
 * The line holds the prompt's inline images as base64: either auto-resize keeps each
 * under the inline limit, or it is off and the 4/3 expansion of the whole upload
 * total applies. Its text is at most `maximumTextBytes`, escaped at six bytes per
 * byte, and its envelope lists the attachments. Callers pass the configured limits,
 * so the bound follows them rather than a second copy of the numbers.
 */
export function maximumPromptLineBytes(maximumUploadBytes: number, maximumTextBytes: number): number {
  const inlineImages = Math.max(
    4 * Math.ceil(maximumUploadBytes / 3) + 4 * MAXIMUM_PROMPT_ATTACHMENTS,
    MAXIMUM_PROMPT_ATTACHMENTS * INLINE_IMAGE_BASE64_LIMIT_BYTES,
  );
  return inlineImages + 6 * maximumTextBytes + MAXIMUM_PROMPT_ATTACHMENTS * ENVELOPE_BYTES_PER_ATTACHMENT;
}

/** Default canonical source budget, derived once from the actual prompt producer limits. */
export const CANONICAL_SOURCE_MAX_LINE_BYTES = maximumPromptLineBytes(DEFAULT_MAX_UPLOAD_BYTES, PROMPT_TEXT_MAX_BYTES);
