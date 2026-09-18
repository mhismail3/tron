import type { ImageContent } from "@earendil-works/pi-ai";
import { resizeImage } from "@earendil-works/pi-coding-agent";

/**
 * Bound prompt attachments to the same image limits Pi already applies to
 * `read`, `@file`, and tool-result images (2000x2000, 4.5MB encoded).
 *
 * Pi normalizes those three ingress points but passes images supplied through
 * the prompt API straight into history, and Tron is the owner of prompt
 * attachments. Without this bound a full-resolution phone screenshot entered
 * canonical history unchanged, and because every later provider request
 * re-serializes the whole conversation, a handful of them pushed the request
 * past the provider's body limit: the provider then rejects the entire
 * conversation (HTTP 413) instead of one turn, and the session cannot continue
 * until it is compacted.
 *
 * The original attachment stays in the upload store for previews and durable
 * ownership; only the copy admitted to model context is bounded. A null result
 * means the pinned image backend could not decode or bound the image, so keep
 * the original there, matching Pi's tool-result normalization rather than
 * silently dropping the user's attachment.
 */
export async function boundPromptImages(images: ImageContent[]): Promise<ImageContent[]> {
  const bounded: ImageContent[] = [];
  for (const image of images) {
    const resized = await resizeImage(Buffer.from(image.data, "base64"), image.mimeType);
    bounded.push(resized === null ? image : { type: "image", data: resized.data, mimeType: resized.mimeType });
  }
  return bounded;
}
