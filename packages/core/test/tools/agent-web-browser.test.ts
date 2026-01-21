/**
 * @fileoverview AgentWebBrowserTool unit tests (mocked, fast)
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentWebBrowserTool, type BrowserDelegate } from '../../src/tools/agent-web-browser.js';

describe('AgentWebBrowserTool', () => {
  let mockDelegate: BrowserDelegate;
  let tool: AgentWebBrowserTool;

  beforeEach(() => {
    mockDelegate = {
      execute: vi.fn(),
      ensureSession: vi.fn(),
      hasSession: vi.fn(),
    };
    tool = new AgentWebBrowserTool({ delegate: mockDelegate });
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(tool.name).toBe('AgentWebBrowser');
      expect(tool.description).toContain('Control a web browser');
    });

    it('should define parameters schema', () => {
      expect(tool.parameters).toBeDefined();
      expect(tool.parameters.type).toBe('object');
      expect(tool.parameters.properties).toBeDefined();
      expect(tool.parameters.required).toEqual(['action']);
    });

    it('should define action parameter', () => {
      expect(tool.parameters.properties.action).toBeDefined();
      expect(tool.parameters.properties.action.type).toBe('string');
    });
  });

  describe('execute - no delegate', () => {
    it('should return error when delegate not configured', async () => {
      const toolWithoutDelegate = new AgentWebBrowserTool({});
      const result = await toolWithoutDelegate.execute({ action: 'navigate', url: 'https://example.com' });

      expect(result.content).toBeDefined();
      expect(Array.isArray(result.content)).toBe(true);
      const content = result.content as any[];
      expect(content[0].text).toContain('not available');
    });
  });

  describe('execute - with delegate', () => {
    it('should return error when action is missing', async () => {
      const result = await tool.execute({});

      expect(result.content).toBeDefined();
      expect(Array.isArray(result.content)).toBe(true);
      const content = result.content as any[];
      expect(content[0].text).toContain('action');
    });

    it('should call delegate.ensureSession', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { url: 'https://example.com' } });

      await tool.execute({ action: 'navigate', url: 'https://example.com' });

      expect(mockDelegate.ensureSession).toHaveBeenCalled();
    });

    it('should execute navigate action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { url: 'https://example.com' } });

      const result = await tool.execute({ action: 'navigate', url: 'https://example.com' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'navigate',
        expect.objectContaining({ action: 'navigate', url: 'https://example.com' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Navigated');
    });

    it('should execute click action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: 'button' } });

      const result = await tool.execute({ action: 'click', selector: 'button' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'click',
        expect.objectContaining({ action: 'click', selector: 'button' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Clicked');
    });

    it('should execute fill action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: '#email', value: 'test@example.com' } });

      const result = await tool.execute({ action: 'fill', selector: '#email', value: 'test@example.com' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'fill',
        expect.objectContaining({ action: 'fill', selector: '#email', value: 'test@example.com' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Filled');
    });

    it('should execute screenshot action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({
        success: true,
        data: { screenshot: 'base64data', format: 'png' }
      });

      const result = await tool.execute({ action: 'screenshot' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'screenshot',
        expect.objectContaining({ action: 'screenshot' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Screenshot');
    });

    it('should execute snapshot action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({
        success: true,
        data: {
          snapshot: { role: 'document' },
          elementRefs: [{ ref: 'e1', selector: 'button' }]
        }
      });

      const result = await tool.execute({ action: 'snapshot' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'snapshot',
        expect.objectContaining({ action: 'snapshot' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Snapshot');
    });

    it('should execute goBack action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: {} });

      const result = await tool.execute({ action: 'goBack' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'goBack',
        expect.objectContaining({ action: 'goBack' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('back');
    });

    it('should execute goForward action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: {} });

      const result = await tool.execute({ action: 'goForward' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'goForward',
        expect.objectContaining({ action: 'goForward' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('forward');
    });

    it('should execute reload action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: {} });

      const result = await tool.execute({ action: 'reload' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'reload',
        expect.objectContaining({ action: 'reload' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('reload');
    });

    it('should execute hover action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: 'button' } });

      const result = await tool.execute({ action: 'hover', selector: 'button' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'hover',
        expect.objectContaining({ action: 'hover', selector: 'button' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Hover');
    });

    it('should execute pressKey action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { key: 'Enter' } });

      const result = await tool.execute({ action: 'pressKey', key: 'Enter' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'pressKey',
        expect.objectContaining({ action: 'pressKey', key: 'Enter' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Pressed');
    });

    it('should execute getText action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: '.content', text: 'Hello World' } });

      const result = await tool.execute({ action: 'getText', selector: '.content' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'getText',
        expect.objectContaining({ action: 'getText', selector: '.content' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Text content');
    });

    it('should execute getAttribute action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: 'a', attribute: 'href', value: 'https://example.com' } });

      const result = await tool.execute({ action: 'getAttribute', selector: 'a', attribute: 'href' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'getAttribute',
        expect.objectContaining({ action: 'getAttribute', selector: 'a', attribute: 'href' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('Attribute');
    });

    it('should execute pdf action', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { path: '/tmp/page.pdf' } });

      const result = await tool.execute({ action: 'pdf', path: '/tmp/page.pdf' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'pdf',
        expect.objectContaining({ action: 'pdf', path: '/tmp/page.pdf' })
      );
      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('PDF');
    });

    it('should return error when delegate execution fails', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: false, error: 'Navigation failed' });

      const result = await tool.execute({ action: 'navigate', url: 'https://example.com' });

      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('failed');
      expect(content[0].text).toContain('Navigation failed');
    });

    it('should handle exceptions gracefully', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.ensureSession).mockRejectedValue(new Error('Session creation failed'));

      const result = await tool.execute({ action: 'navigate', url: 'https://example.com' });

      expect(result.content).toBeDefined();
      const content = result.content as any[];
      expect(content[0].text).toContain('error');
    });
  });

  describe('selector conversion', () => {
    it('should convert :contains() with double quotes', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: 'converted' } });

      await tool.execute({ action: 'click', selector: 'button:contains("Submit")' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'click',
        expect.objectContaining({
          selector: 'button:has-text("Submit")'
        })
      );
    });

    it('should convert :contains() with single quotes', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: 'converted' } });

      await tool.execute({ action: 'click', selector: "button:contains('Submit')" });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'click',
        expect.objectContaining({
          selector: 'button:has-text("Submit")'
        })
      );
    });

    it('should convert multiple :contains() in selector', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: 'converted' } });

      await tool.execute({ action: 'click', selector: 'div:contains("Foo") button:contains("Bar")' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'click',
        expect.objectContaining({
          selector: 'div:has-text("Foo") button:has-text("Bar")'
        })
      );
    });

    it('should not modify selectors without :contains()', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: { selector: 'button' } });

      await tool.execute({ action: 'click', selector: 'button.primary' });

      expect(mockDelegate.execute).toHaveBeenCalledWith(
        expect.any(String),
        'click',
        expect.objectContaining({
          selector: 'button.primary'
        })
      );
    });
  });

  describe('session management', () => {
    it('should reuse existing session', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(true);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: {} });

      await tool.execute({ action: 'navigate', url: 'https://example.com' });

      expect(mockDelegate.ensureSession).not.toHaveBeenCalled();
      expect(mockDelegate.hasSession).toHaveBeenCalled();
    });

    it('should create session if not exists', async () => {
      vi.mocked(mockDelegate.hasSession).mockReturnValue(false);
      vi.mocked(mockDelegate.execute).mockResolvedValue({ success: true, data: {} });

      await tool.execute({ action: 'navigate', url: 'https://example.com' });

      expect(mockDelegate.ensureSession).toHaveBeenCalled();
    });
  });
});
