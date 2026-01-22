/**
 * @fileoverview Tests for Attachment Processing
 *
 * TDD: Tests for converting file attachments to content blocks
 * for the Claude and OpenAI APIs.
 */
import { describe, it, expect } from 'vitest';
import {
  convertAttachmentsToContentBlocks,
  type FileAttachment,
  type ContentBlock,
} from '../attachments.js';

describe('Attachment Processing', () => {
  describe('convertAttachmentsToContentBlocks', () => {
    it('converts image attachments to image content blocks', () => {
      const attachments: FileAttachment[] = [
        {
          data: 'base64imagedata',
          mimeType: 'image/jpeg',
          fileName: 'photo.jpg',
        },
      ];

      const blocks = convertAttachmentsToContentBlocks(attachments);

      expect(blocks).toHaveLength(1);
      expect(blocks[0]).toEqual({
        type: 'image',
        data: 'base64imagedata',
        mimeType: 'image/jpeg',
      });
    });

    it('converts PNG image attachments correctly', () => {
      const attachments: FileAttachment[] = [
        {
          data: 'pngdata',
          mimeType: 'image/png',
        },
      ];

      const blocks = convertAttachmentsToContentBlocks(attachments);

      expect(blocks).toHaveLength(1);
      expect(blocks[0].type).toBe('image');
      expect(blocks[0].mimeType).toBe('image/png');
    });

    it('converts GIF and WebP image types', () => {
      const attachments: FileAttachment[] = [
        { data: 'gifdata', mimeType: 'image/gif' },
        { data: 'webpdata', mimeType: 'image/webp' },
      ];

      const blocks = convertAttachmentsToContentBlocks(attachments);

      expect(blocks).toHaveLength(2);
      expect(blocks[0].type).toBe('image');
      expect(blocks[1].type).toBe('image');
    });

    it('converts PDF attachments to document content blocks', () => {
      const attachments: FileAttachment[] = [
        {
          data: 'pdfbase64data',
          mimeType: 'application/pdf',
          fileName: 'report.pdf',
        },
      ];

      const blocks = convertAttachmentsToContentBlocks(attachments);

      expect(blocks).toHaveLength(1);
      expect(blocks[0]).toEqual({
        type: 'document',
        data: 'pdfbase64data',
        mimeType: 'application/pdf',
        fileName: 'report.pdf',
      });
    });

    it('handles mixed image and PDF attachments', () => {
      const attachments: FileAttachment[] = [
        { data: 'img1', mimeType: 'image/png' },
        { data: 'pdf1', mimeType: 'application/pdf', fileName: 'doc.pdf' },
        { data: 'img2', mimeType: 'image/jpeg' },
      ];

      const blocks = convertAttachmentsToContentBlocks(attachments);

      expect(blocks).toHaveLength(3);
      expect(blocks[0].type).toBe('image');
      expect(blocks[1].type).toBe('document');
      expect(blocks[2].type).toBe('image');
    });

    it('preserves order of attachments', () => {
      const attachments: FileAttachment[] = [
        { data: 'first', mimeType: 'image/jpeg' },
        { data: 'second', mimeType: 'application/pdf' },
        { data: 'third', mimeType: 'image/png' },
      ];

      const blocks = convertAttachmentsToContentBlocks(attachments);

      expect(blocks[0].data).toBe('first');
      expect(blocks[1].data).toBe('second');
      expect(blocks[2].data).toBe('third');
    });

    it('returns empty array for empty attachments', () => {
      const blocks = convertAttachmentsToContentBlocks([]);
      expect(blocks).toEqual([]);
    });

    it('returns empty array for undefined attachments', () => {
      const blocks = convertAttachmentsToContentBlocks(undefined);
      expect(blocks).toEqual([]);
    });

    it('filters out unsupported MIME types', () => {
      const attachments: FileAttachment[] = [
        { data: 'valid', mimeType: 'image/jpeg' },
        { data: 'invalid', mimeType: 'application/zip' },
        { data: 'also-valid', mimeType: 'application/pdf' },
      ];

      const blocks = convertAttachmentsToContentBlocks(attachments);

      expect(blocks).toHaveLength(2);
      expect(blocks[0].mimeType).toBe('image/jpeg');
      expect(blocks[1].mimeType).toBe('application/pdf');
    });
  });

  describe('mergeAttachments (backward compatibility)', () => {
    it('merges legacy images array with new attachments array', () => {
      const images: FileAttachment[] = [
        { data: 'legacy-img', mimeType: 'image/png' },
      ];
      const attachments: FileAttachment[] = [
        { data: 'new-pdf', mimeType: 'application/pdf', fileName: 'new.pdf' },
      ];

      const blocks = convertAttachmentsToContentBlocks(images, attachments);

      expect(blocks).toHaveLength(2);
      expect(blocks[0].data).toBe('legacy-img');
      expect(blocks[1].data).toBe('new-pdf');
    });

    it('handles only legacy images array', () => {
      const images: FileAttachment[] = [
        { data: 'legacy1', mimeType: 'image/jpeg' },
        { data: 'legacy2', mimeType: 'image/png' },
      ];

      const blocks = convertAttachmentsToContentBlocks(images, undefined);

      expect(blocks).toHaveLength(2);
    });

    it('handles only new attachments array', () => {
      const attachments: FileAttachment[] = [
        { data: 'new1', mimeType: 'image/jpeg' },
        { data: 'new2', mimeType: 'application/pdf' },
      ];

      const blocks = convertAttachmentsToContentBlocks(undefined, attachments);

      expect(blocks).toHaveLength(2);
    });

    it('handles both arrays empty', () => {
      const blocks = convertAttachmentsToContentBlocks([], []);
      expect(blocks).toEqual([]);
    });

    it('handles both arrays undefined', () => {
      const blocks = convertAttachmentsToContentBlocks(undefined, undefined);
      expect(blocks).toEqual([]);
    });
  });
});
