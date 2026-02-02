/**
 * @fileoverview Media Utilities
 *
 * Utilities for handling images and PDFs in the agent context.
 * Supports base64 encoding for API transmission.
 */

import * as fs from 'fs/promises';
import * as path from 'path';

const IMAGE_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.gif', '.webp']);
const PDF_EXTENSION = '.pdf';

const MIME_TYPES: Record<string, string> = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
};

export interface MediaInfo {
  type: 'image' | 'pdf';
  path: string;
  size: number;
  mimeType?: string;
  base64?: string;
}

/**
 * Check if a file is an image based on extension
 */
export function isImageFile(filePath: string): boolean {
  const ext = path.extname(filePath).toLowerCase();
  return IMAGE_EXTENSIONS.has(ext);
}

/**
 * Check if a file is a PDF based on extension
 */
export function isPdfFile(filePath: string): boolean {
  const ext = path.extname(filePath).toLowerCase();
  return ext === PDF_EXTENSION;
}

/**
 * Check if a file is a supported media type (image or PDF)
 */
export function isSupportedMediaFile(filePath: string): boolean {
  return isImageFile(filePath) || isPdfFile(filePath);
}

/**
 * Get the MIME type for an image file
 */
export function getImageMimeType(filePath: string): string | null {
  const ext = path.extname(filePath).toLowerCase();
  return MIME_TYPES[ext] || null;
}

/**
 * Read an image file and return base64 encoded content
 */
export async function readImageAsBase64(filePath: string): Promise<string> {
  const buffer = await fs.readFile(filePath);
  return buffer.toString('base64');
}

/**
 * Get information about a media file
 */
export async function getMediaInfo(filePath: string): Promise<MediaInfo> {
  if (!isSupportedMediaFile(filePath)) {
    throw new Error(`Unsupported media type: ${filePath}`);
  }

  const stats = await fs.stat(filePath);
  const isImage = isImageFile(filePath);

  const info: MediaInfo = {
    type: isImage ? 'image' : 'pdf',
    path: filePath,
    size: stats.size,
  };

  if (isImage) {
    info.mimeType = getImageMimeType(filePath) || undefined;
  }

  return info;
}

/**
 * Prepare an image for API submission
 * Returns the base64 data and MIME type
 */
export async function prepareImageForApi(
  filePath: string
): Promise<{ base64: string; mimeType: string }> {
  if (!isImageFile(filePath)) {
    throw new Error(`Not an image file: ${filePath}`);
  }

  const base64 = await readImageAsBase64(filePath);
  const mimeType = getImageMimeType(filePath);

  if (!mimeType) {
    throw new Error(`Unknown image type: ${filePath}`);
  }

  return { base64, mimeType };
}

/**
 * Format file size for display
 */
export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
