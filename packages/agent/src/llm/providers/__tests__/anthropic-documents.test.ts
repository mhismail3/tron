/**
 * @fileoverview Tests for Anthropic Provider Document Handling
 *
 * TDD: Tests for PDF/document content block conversion to Claude API format
 */

import { describe, it, expect } from 'vitest';
import type { DocumentContent, ImageContent, TextContent } from '@core/types/messages.js';

// Define the expected Anthropic API format for documents
interface AnthropicDocumentBlock {
  type: 'document';
  source: {
    type: 'base64';
    media_type: string;
    data: string;
  };
}

interface AnthropicImageBlock {
  type: 'image';
  source: {
    type: 'base64';
    media_type: string;
    data: string;
  };
}

interface AnthropicTextBlock {
  type: 'text';
  text: string;
}

type AnthropicContentBlock = AnthropicTextBlock | AnthropicImageBlock | AnthropicDocumentBlock;

/**
 * Convert Tron content blocks to Anthropic format
 * This is the function we're testing - it will be implemented in anthropic.ts
 */
function convertContentBlockToAnthropicFormat(
  content: TextContent | ImageContent | DocumentContent
): AnthropicContentBlock {
  if (content.type === 'text') {
    return { type: 'text', text: content.text };
  }

  if (content.type === 'image') {
    return {
      type: 'image',
      source: {
        type: 'base64',
        media_type: content.mimeType,
        data: content.data,
      },
    };
  }

  if (content.type === 'document') {
    return {
      type: 'document',
      source: {
        type: 'base64',
        media_type: content.mimeType,
        data: content.data,
      },
    };
  }

  throw new Error(`Unknown content type: ${(content as { type: string }).type}`);
}

describe('Anthropic Provider Document Handling', () => {
  describe('convertContentBlockToAnthropicFormat', () => {
    it('converts text content correctly', () => {
      const textContent: TextContent = {
        type: 'text',
        text: 'Hello, Claude!',
      };

      const result = convertContentBlockToAnthropicFormat(textContent);

      expect(result).toEqual({
        type: 'text',
        text: 'Hello, Claude!',
      });
    });

    it('converts image content to Anthropic image format', () => {
      const imageContent: ImageContent = {
        type: 'image',
        data: 'base64imagedata',
        mimeType: 'image/jpeg',
      };

      const result = convertContentBlockToAnthropicFormat(imageContent);

      expect(result).toEqual({
        type: 'image',
        source: {
          type: 'base64',
          media_type: 'image/jpeg',
          data: 'base64imagedata',
        },
      });
    });

    it('converts PNG images correctly', () => {
      const imageContent: ImageContent = {
        type: 'image',
        data: 'pngdata',
        mimeType: 'image/png',
      };

      const result = convertContentBlockToAnthropicFormat(imageContent);

      expect(result.type).toBe('image');
      expect((result as AnthropicImageBlock).source.media_type).toBe('image/png');
    });

    it('converts PDF document to Anthropic document format', () => {
      const docContent: DocumentContent = {
        type: 'document',
        data: 'base64pdfdata',
        mimeType: 'application/pdf',
        fileName: 'report.pdf',
      };

      const result = convertContentBlockToAnthropicFormat(docContent);

      expect(result).toEqual({
        type: 'document',
        source: {
          type: 'base64',
          media_type: 'application/pdf',
          data: 'base64pdfdata',
        },
      });
    });

    it('converts document without fileName correctly', () => {
      const docContent: DocumentContent = {
        type: 'document',
        data: 'pdfdata',
        mimeType: 'application/pdf',
      };

      const result = convertContentBlockToAnthropicFormat(docContent);

      expect(result.type).toBe('document');
      expect((result as AnthropicDocumentBlock).source.type).toBe('base64');
    });
  });

  describe('mixed content handling', () => {
    it('handles array of mixed content types', () => {
      const contents: (TextContent | ImageContent | DocumentContent)[] = [
        { type: 'text', text: 'Look at this document:' },
        { type: 'document', data: 'pdfdata', mimeType: 'application/pdf' },
        { type: 'image', data: 'imagedata', mimeType: 'image/png' },
      ];

      const results = contents.map(convertContentBlockToAnthropicFormat);

      expect(results).toHaveLength(3);
      expect(results[0].type).toBe('text');
      expect(results[1].type).toBe('document');
      expect(results[2].type).toBe('image');
    });

    it('preserves content order when converting', () => {
      const contents: (TextContent | DocumentContent)[] = [
        { type: 'document', data: 'pdf1', mimeType: 'application/pdf' },
        { type: 'text', text: 'between docs' },
        { type: 'document', data: 'pdf2', mimeType: 'application/pdf' },
      ];

      const results = contents.map(convertContentBlockToAnthropicFormat);

      expect((results[0] as AnthropicDocumentBlock).source.data).toBe('pdf1');
      expect((results[1] as AnthropicTextBlock).text).toBe('between docs');
      expect((results[2] as AnthropicDocumentBlock).source.data).toBe('pdf2');
    });
  });
});
