/**
 * @fileoverview Export Module Tests
 */
import { describe, it, expect } from 'vitest';
import {
  TranscriptExporter,
  messagesToTranscript,
  toMarkdown,
  toHTML,
  toJSON,
} from '../export.js';
import type { Message, UserMessage, AssistantMessage } from '../../types/index.js';

describe('Export Module', () => {
  describe('messagesToTranscript', () => {
    it('should convert user message', () => {
      const messages: Message[] = [
        { role: 'user', content: 'Hello world' } as UserMessage,
      ];

      const transcript = messagesToTranscript(messages);

      expect(transcript).toHaveLength(1);
      expect(transcript[0].role).toBe('user');
      expect(transcript[0].content).toBe('Hello world');
    });

    it('should convert assistant message with text', () => {
      const messages: Message[] = [
        {
          role: 'assistant',
          content: [{ type: 'text', text: 'Hi there!' }],
        } as AssistantMessage,
      ];

      const transcript = messagesToTranscript(messages);

      expect(transcript).toHaveLength(1);
      expect(transcript[0].role).toBe('assistant');
      expect(transcript[0].content).toBe('Hi there!');
    });

    it('should include thinking when option enabled', () => {
      const messages: Message[] = [
        {
          role: 'assistant',
          content: [
            { type: 'thinking', thinking: 'Let me think...' },
            { type: 'text', text: 'Response' },
          ],
        } as AssistantMessage,
      ];

      const transcript = messagesToTranscript(messages, { includeThinking: true });

      expect(transcript).toHaveLength(1);
      expect(transcript[0].thinking).toBe('Let me think...');
    });

    it('should include tool calls when option enabled', () => {
      const messages: Message[] = [
        {
          role: 'assistant',
          content: [
            {
              type: 'tool_use',
              id: 'tool_1',
              name: 'read',
              arguments: { path: 'file.txt' },
            },
          ],
        } as AssistantMessage,
      ];

      const transcript = messagesToTranscript(messages, { includeToolCalls: true });

      expect(transcript).toHaveLength(1);
      expect(transcript[0].role).toBe('tool');
      expect(transcript[0].toolName).toBe('read');
    });
  });

  describe('toMarkdown', () => {
    it('should generate valid markdown', () => {
      const transcript = [
        { role: 'user' as const, content: 'Hello' },
        { role: 'assistant' as const, content: 'Hi there!' },
      ];

      const md = toMarkdown(transcript);

      expect(md).toContain('# Conversation Transcript');
      expect(md).toContain('### 👤 User');
      expect(md).toContain('Hello');
      expect(md).toContain('### 🤖 Assistant');
      expect(md).toContain('Hi there!');
    });

    it('should include metadata when option enabled', () => {
      const transcript = [
        { role: 'user' as const, content: 'Test' },
      ];
      const metadata = {
        sessionId: 'sess_123',
        model: 'claude-sonnet',
        totalTokens: { input: 100, output: 50 },
      };

      const md = toMarkdown(transcript, metadata, {
        includeMetadata: true,
        includeStats: true,
      });

      expect(md).toContain('sess_123');
      expect(md).toContain('claude-sonnet');
      expect(md).toContain('100 input');
    });

    it('should include custom title', () => {
      const transcript = [{ role: 'user' as const, content: 'Test' }];

      const md = toMarkdown(transcript, undefined, { title: 'My Conversation' });

      expect(md).toContain('# My Conversation');
    });
  });

  describe('toHTML', () => {
    it('should generate valid HTML', () => {
      const transcript = [
        { role: 'user' as const, content: 'Hello' },
        { role: 'assistant' as const, content: 'Hi there!' },
      ];

      const html = toHTML(transcript);

      expect(html).toContain('<!DOCTYPE html>');
      expect(html).toContain('<html');
      expect(html).toContain('User');
      expect(html).toContain('Hello');
      expect(html).toContain('Assistant');
    });

    it('should escape HTML entities', () => {
      const transcript = [
        { role: 'user' as const, content: '<script>alert("xss")</script>' },
      ];

      const html = toHTML(transcript);

      expect(html).not.toContain('<script>');
      expect(html).toContain('&lt;script&gt;');
    });
  });

  describe('toJSON', () => {
    it('should generate valid JSON', () => {
      const transcript = [
        { role: 'user' as const, content: 'Test' },
      ];

      const json = toJSON(transcript);
      const parsed = JSON.parse(json);

      expect(parsed.messages).toHaveLength(1);
      expect(parsed.messages[0].role).toBe('user');
      expect(parsed.exportedAt).toBeTruthy();
    });

    it('should include metadata when enabled', () => {
      const transcript = [{ role: 'user' as const, content: 'Test' }];
      const metadata = { sessionId: 'sess_123' };

      const json = toJSON(transcript, metadata, { includeMetadata: true });
      const parsed = JSON.parse(json);

      expect(parsed.metadata.sessionId).toBe('sess_123');
    });
  });

  describe('TranscriptExporter', () => {
    const messages: Message[] = [
      { role: 'user', content: 'Hello' } as UserMessage,
      {
        role: 'assistant',
        content: [{ type: 'text', text: 'Hi!' }],
      } as AssistantMessage,
    ];

    it('should export to markdown', () => {
      const exporter = new TranscriptExporter(messages);
      const md = exporter.toMarkdown();

      expect(md).toContain('# Conversation Transcript');
    });

    it('should export to HTML', () => {
      const exporter = new TranscriptExporter(messages);
      const html = exporter.toHTML();

      expect(html).toContain('<!DOCTYPE html>');
    });

    it('should export to JSON', () => {
      const exporter = new TranscriptExporter(messages);
      const json = exporter.toJSON();

      expect(JSON.parse(json).messages).toHaveLength(2);
    });

    it('should export to plain text', () => {
      const exporter = new TranscriptExporter(messages);
      const text = exporter.toPlainText();

      expect(text).toContain('User: Hello');
      expect(text).toContain('Assistant: Hi!');
    });

    it('should use custom options', () => {
      const exporter = new TranscriptExporter(messages, { sessionId: 'test' }, {
        title: 'Custom Title',
        includeMetadata: true,
      });
      const md = exporter.toMarkdown();

      expect(md).toContain('# Custom Title');
      expect(md).toContain('test');
    });
  });
});
