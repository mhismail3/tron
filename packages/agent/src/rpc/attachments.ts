/**
 * @fileoverview Attachment Processing Utilities
 *
 * Converts file attachments from iOS/web clients to content blocks
 * that can be sent to Claude and OpenAI APIs.
 */

/**
 * File attachment from client (iOS app or web)
 */
export interface FileAttachment {
  /** Base64 encoded file data */
  data: string;
  /** MIME type (e.g., "image/jpeg", "application/pdf") */
  mimeType: string;
  /** Optional original filename */
  fileName?: string;
}

/**
 * Image content block for API
 */
export interface ImageContentBlock {
  type: 'image';
  data: string;
  mimeType: string;
}

/**
 * Document content block for API (PDFs)
 */
export interface DocumentContentBlock {
  type: 'document';
  data: string;
  mimeType: string;
  fileName?: string;
}

/**
 * Content block union type
 */
export type ContentBlock = ImageContentBlock | DocumentContentBlock;

/**
 * Supported image MIME types
 */
const SUPPORTED_IMAGE_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
]);

/**
 * Supported document MIME types
 */
const SUPPORTED_DOCUMENT_TYPES = new Set([
  'application/pdf',
]);

/**
 * Check if a MIME type is a supported image type
 */
function isImageType(mimeType: string): boolean {
  return SUPPORTED_IMAGE_TYPES.has(mimeType);
}

/**
 * Check if a MIME type is a supported document type
 */
function isDocumentType(mimeType: string): boolean {
  return SUPPORTED_DOCUMENT_TYPES.has(mimeType);
}

/**
 * Check if a MIME type is supported (image or document)
 */
function isSupportedType(mimeType: string): boolean {
  return isImageType(mimeType) || isDocumentType(mimeType);
}

/**
 * Convert file attachments to content blocks for the API.
 *
 * Supports both the legacy `images` array and the new `attachments` array
 * for backward compatibility with existing clients.
 *
 * @param imagesOrAttachments - Legacy images array OR new attachments array (when called with single arg)
 * @param attachments - New attachments array (when called with two args for backward compat)
 * @returns Array of content blocks (images and documents)
 */
export function convertAttachmentsToContentBlocks(
  imagesOrAttachments?: FileAttachment[],
  attachments?: FileAttachment[],
): ContentBlock[] {
  // Handle single argument case (just attachments)
  // and two argument case (images + attachments for backward compat)
  const allAttachments: FileAttachment[] = [];

  if (imagesOrAttachments && Array.isArray(imagesOrAttachments)) {
    allAttachments.push(...imagesOrAttachments);
  }

  if (attachments && Array.isArray(attachments)) {
    allAttachments.push(...attachments);
  }

  if (allAttachments.length === 0) {
    return [];
  }

  const contentBlocks: ContentBlock[] = [];

  for (const attachment of allAttachments) {
    const { data, mimeType, fileName } = attachment;

    // Skip unsupported MIME types
    if (!isSupportedType(mimeType)) {
      continue;
    }

    if (isImageType(mimeType)) {
      contentBlocks.push({
        type: 'image',
        data,
        mimeType,
      });
    } else if (isDocumentType(mimeType)) {
      contentBlocks.push({
        type: 'document',
        data,
        mimeType,
        fileName,
      });
    }
  }

  return contentBlocks;
}
