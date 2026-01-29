/**
 * @fileoverview Media Utility Tests
 *
 * Tests for image and PDF handling utilities.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import type { Stats } from 'fs';
import * as path from 'path';
import {
  isImageFile,
  isPdfFile,
  isSupportedMediaFile,
  readImageAsBase64,
  getImageMimeType,
  MediaInfo,
  getMediaInfo,
} from '../media.js';

vi.mock('fs/promises');

describe('Media Utilities', () => {
  describe('isImageFile', () => {
    it('recognizes common image extensions', () => {
      expect(isImageFile('photo.jpg')).toBe(true);
      expect(isImageFile('photo.jpeg')).toBe(true);
      expect(isImageFile('image.png')).toBe(true);
      expect(isImageFile('graphic.gif')).toBe(true);
      expect(isImageFile('picture.webp')).toBe(true);
    });

    it('is case insensitive', () => {
      expect(isImageFile('PHOTO.JPG')).toBe(true);
      expect(isImageFile('Image.PNG')).toBe(true);
    });

    it('rejects non-image files', () => {
      expect(isImageFile('document.pdf')).toBe(false);
      expect(isImageFile('code.ts')).toBe(false);
      expect(isImageFile('data.json')).toBe(false);
    });
  });

  describe('isPdfFile', () => {
    it('recognizes PDF files', () => {
      expect(isPdfFile('document.pdf')).toBe(true);
      expect(isPdfFile('REPORT.PDF')).toBe(true);
    });

    it('rejects non-PDF files', () => {
      expect(isPdfFile('image.png')).toBe(false);
      expect(isPdfFile('document.doc')).toBe(false);
    });
  });

  describe('isSupportedMediaFile', () => {
    it('recognizes images and PDFs', () => {
      expect(isSupportedMediaFile('photo.png')).toBe(true);
      expect(isSupportedMediaFile('document.pdf')).toBe(true);
    });

    it('rejects unsupported files', () => {
      expect(isSupportedMediaFile('code.ts')).toBe(false);
      expect(isSupportedMediaFile('video.mp4')).toBe(false);
    });
  });

  describe('getImageMimeType', () => {
    it('returns correct MIME types', () => {
      expect(getImageMimeType('photo.jpg')).toBe('image/jpeg');
      expect(getImageMimeType('photo.jpeg')).toBe('image/jpeg');
      expect(getImageMimeType('image.png')).toBe('image/png');
      expect(getImageMimeType('graphic.gif')).toBe('image/gif');
      expect(getImageMimeType('picture.webp')).toBe('image/webp');
    });

    it('returns null for non-images', () => {
      expect(getImageMimeType('document.pdf')).toBeNull();
      expect(getImageMimeType('code.ts')).toBeNull();
    });
  });

  describe('readImageAsBase64', () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it('reads file and returns base64', async () => {
      const mockData = Buffer.from('fake image data');
      vi.mocked(fs.readFile).mockResolvedValue(mockData);

      const result = await readImageAsBase64('/path/to/image.png');

      expect(result).toBe(mockData.toString('base64'));
      expect(fs.readFile).toHaveBeenCalledWith('/path/to/image.png');
    });

    it('throws for missing file', async () => {
      vi.mocked(fs.readFile).mockRejectedValue(new Error('ENOENT'));

      await expect(readImageAsBase64('/missing.png')).rejects.toThrow();
    });
  });

  describe('getMediaInfo', () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it('returns info for image files', async () => {
      const mockData = Buffer.from('x'.repeat(1024));
      vi.mocked(fs.readFile).mockResolvedValue(mockData);
      vi.mocked(fs.stat).mockResolvedValue({ size: 1024 } as Stats);

      const info = await getMediaInfo('/path/to/image.png');

      expect(info.type).toBe('image');
      expect(info.mimeType).toBe('image/png');
      expect(info.size).toBe(1024);
    });

    it('returns info for PDF files', async () => {
      vi.mocked(fs.stat).mockResolvedValue({ size: 2048 } as Stats);

      const info = await getMediaInfo('/path/to/document.pdf');

      expect(info.type).toBe('pdf');
      expect(info.size).toBe(2048);
    });

    it('throws for unsupported files', async () => {
      await expect(getMediaInfo('/path/to/code.ts')).rejects.toThrow('Unsupported');
    });
  });
});
