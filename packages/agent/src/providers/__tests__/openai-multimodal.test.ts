/**
 * @fileoverview Tests for OpenAI Multimodal Support
 *
 * Tests conversion of images and documents to OpenAI input_image format.
 */
import { describe, it, expect } from 'vitest';
import { convertToResponsesInput } from '../openai/message-converter.js';
import type { Context, UserMessage, ImageContent, DocumentContent } from '../../types/index.js';
import type { ResponsesInputItem, MessageContent } from '../openai/types.js';

describe('OpenAI Provider Multimodal Support', () => {
  describe('convertToResponsesInput', () => {
    it('converts text-only user message with string format', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: 'Hello, world!',
          } as UserMessage,
        ],
      };

      const input = convertToResponsesInput(context);

      expect(input).toHaveLength(1);
      const msg = input[0] as { type: 'message'; role: 'user'; content: MessageContent[] };
      expect(msg.type).toBe('message');
      expect(msg.role).toBe('user');
      expect(msg.content).toHaveLength(1);
      expect(msg.content[0]).toEqual({ type: 'input_text', text: 'Hello, world!' });
    });

    it('converts image content to input_image format', () => {
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

      const input = convertToResponsesInput(context);

      expect(input).toHaveLength(1);
      const msg = input[0] as { type: 'message'; content: MessageContent[] };
      expect(msg.content).toHaveLength(2);
      expect(msg.content[0]).toEqual({ type: 'input_text', text: 'What is in this image?' });
      expect(msg.content[1]).toEqual({
        type: 'input_image',
        image_url: 'data:image/jpeg;base64,base64imagedata',
        detail: 'auto',
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

      const input = convertToResponsesInput(context);

      expect(input).toHaveLength(1);
      const msg = input[0] as { type: 'message'; content: MessageContent[] };
      expect(msg.content).toHaveLength(3);
      expect((msg.content[1] as { type: 'input_image'; image_url: string }).image_url).toBe(
        'data:image/png;base64,image1data'
      );
      expect((msg.content[2] as { type: 'input_image'; image_url: string }).image_url).toBe(
        'data:image/webp;base64,image2data'
      );
    });

    it('adds document content as text placeholder', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Summarize this document' },
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

      const input = convertToResponsesInput(context);

      expect(input).toHaveLength(1);
      const msg = input[0] as { type: 'message'; content: MessageContent[] };
      expect(msg.content).toHaveLength(2);
      expect(msg.content[0]).toEqual({ type: 'input_text', text: 'Summarize this document' });
      expect(msg.content[1]).toEqual({
        type: 'input_text',
        text: '[Document: report.pdf (application/pdf)]',
      });
    });

    it('handles document without fileName', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [
              {
                type: 'document',
                data: 'pdfdata',
                mimeType: 'application/pdf',
              } as DocumentContent,
            ],
          } as UserMessage,
        ],
      };

      const input = convertToResponsesInput(context);

      expect(input).toHaveLength(1);
      const msg = input[0] as { type: 'message'; content: MessageContent[] };
      expect(msg.content).toHaveLength(1);
      expect(msg.content[0]).toEqual({
        type: 'input_text',
        text: '[Document: unnamed (application/pdf)]',
      });
    });

    it('preserves order of mixed content', () => {
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

      const input = convertToResponsesInput(context);

      expect(input).toHaveLength(1);
      const msg = input[0] as { type: 'message'; content: MessageContent[] };
      expect(msg.content).toHaveLength(3);
      expect((msg.content[0] as { type: 'input_image'; image_url: string }).image_url).toContain('first');
      expect((msg.content[1] as { type: 'input_text'; text: string }).text).toBe('middle');
      expect((msg.content[2] as { type: 'input_image'; image_url: string }).image_url).toContain('last');
    });

    it('generates correct data URL format for different MIME types', () => {
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

        const input = convertToResponsesInput(context);
        const msg = input[0] as { type: 'message'; content: MessageContent[] };
        const imgContent = msg.content[0] as { type: 'input_image'; image_url: string };
        expect(imgContent.image_url).toBe(`data:${mimeType};base64,testdata`);
      }
    });

    it('handles empty content array', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [],
          } as unknown as UserMessage,
        ],
      };

      const input = convertToResponsesInput(context);

      // Should not add a message with empty content
      expect(input).toHaveLength(0);
    });

    it('handles text array content without images', () => {
      const context: Context = {
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'First part' },
              { type: 'text', text: 'Second part' },
            ],
          } as UserMessage,
        ],
      };

      const input = convertToResponsesInput(context);

      expect(input).toHaveLength(1);
      const msg = input[0] as { type: 'message'; content: MessageContent[] };
      expect(msg.content).toHaveLength(2);
      expect(msg.content[0]).toEqual({ type: 'input_text', text: 'First part' });
      expect(msg.content[1]).toEqual({ type: 'input_text', text: 'Second part' });
    });
  });
});
