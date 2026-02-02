/**
 * @fileoverview Tests for Google Gemini Multimodal Support
 *
 * Tests conversion of images and documents to Gemini inlineData format.
 */
import { describe, it, expect } from 'vitest';
import { convertMessages } from '../google/message-converter.js';
import type { Context, UserMessage, ImageContent, DocumentContent } from '@core/types/index.js';

describe('Google Provider Multimodal Support', () => {
  describe('convertMessages', () => {
    it('converts text-only user message', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: 'Hello, world!',
          } as UserMessage,
        ],
      };

      const contents = convertMessages(context);

      expect(contents).toHaveLength(1);
      expect(contents[0].role).toBe('user');
      expect(contents[0].parts).toHaveLength(1);
      expect(contents[0].parts[0]).toEqual({ text: 'Hello, world!' });
    });

    it('converts image content to inlineData format', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'What is in this image?' },
              {
                type: 'image',
                data: 'base64imagedata',
                mimeType: 'image/jpeg',
              } as ImageContent,
            ],
          } as UserMessage,
        ],
      };

      const contents = convertMessages(context);

      expect(contents).toHaveLength(1);
      expect(contents[0].parts).toHaveLength(2);
      expect(contents[0].parts[0]).toEqual({ text: 'What is in this image?' });
      expect(contents[0].parts[1]).toEqual({
        inlineData: {
          mimeType: 'image/jpeg',
          data: 'base64imagedata',
        },
      });
    });

    it('converts multiple images in a single message', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Compare these images' },
              {
                type: 'image',
                data: 'image1data',
                mimeType: 'image/png',
              } as ImageContent,
              {
                type: 'image',
                data: 'image2data',
                mimeType: 'image/webp',
              } as ImageContent,
            ],
          } as UserMessage,
        ],
      };

      const contents = convertMessages(context);

      expect(contents).toHaveLength(1);
      expect(contents[0].parts).toHaveLength(3);
      expect(contents[0].parts[1]).toEqual({
        inlineData: {
          mimeType: 'image/png',
          data: 'image1data',
        },
      });
      expect(contents[0].parts[2]).toEqual({
        inlineData: {
          mimeType: 'image/webp',
          data: 'image2data',
        },
      });
    });

    it('converts PDF document to inlineData format', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Summarize this PDF' },
              {
                type: 'document',
                data: 'pdfbase64data',
                mimeType: 'application/pdf',
                fileName: 'report.pdf',
              } as DocumentContent,
            ],
          } as UserMessage,
        ],
      };

      const contents = convertMessages(context);

      expect(contents).toHaveLength(1);
      expect(contents[0].parts).toHaveLength(2);
      expect(contents[0].parts[0]).toEqual({ text: 'Summarize this PDF' });
      expect(contents[0].parts[1]).toEqual({
        inlineData: {
          mimeType: 'application/pdf',
          data: 'pdfbase64data',
        },
      });
    });

    it('handles mixed content with text, images, and PDFs', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Analyze these' },
              {
                type: 'image',
                data: 'imgdata',
                mimeType: 'image/gif',
              } as ImageContent,
              {
                type: 'document',
                data: 'pdfdata',
                mimeType: 'application/pdf',
              } as DocumentContent,
            ],
          } as UserMessage,
        ],
      };

      const contents = convertMessages(context);

      expect(contents).toHaveLength(1);
      expect(contents[0].parts).toHaveLength(3);
      expect(contents[0].parts[0]).toEqual({ text: 'Analyze these' });
      expect(contents[0].parts[1]).toEqual({
        inlineData: {
          mimeType: 'image/gif',
          data: 'imgdata',
        },
      });
      expect(contents[0].parts[2]).toEqual({
        inlineData: {
          mimeType: 'application/pdf',
          data: 'pdfdata',
        },
      });
    });

    it('preserves order of content blocks', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [
              {
                type: 'image',
                data: 'first',
                mimeType: 'image/jpeg',
              } as ImageContent,
              { type: 'text', text: 'middle' },
              {
                type: 'image',
                data: 'last',
                mimeType: 'image/png',
              } as ImageContent,
            ],
          } as UserMessage,
        ],
      };

      const contents = convertMessages(context);

      expect(contents).toHaveLength(1);
      expect(contents[0].parts).toHaveLength(3);
      expect((contents[0].parts[0] as { inlineData: { data: string } }).inlineData.data).toBe('first');
      expect((contents[0].parts[1] as { text: string }).text).toBe('middle');
      expect((contents[0].parts[2] as { inlineData: { data: string } }).inlineData.data).toBe('last');
    });

    it('handles different image MIME types correctly', () => {
      const mimeTypes = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];

      for (const mimeType of mimeTypes) {
        const context: Context = {
          messages: [
            {
              role: 'user',
              content: [
                {
                  type: 'image',
                  data: 'testdata',
                  mimeType,
                } as ImageContent,
              ],
            } as UserMessage,
          ],
        };

        const contents = convertMessages(context);
        const part = contents[0].parts[0] as { inlineData: { mimeType: string } };
        expect(part.inlineData.mimeType).toBe(mimeType);
      }
    });
  });
});
