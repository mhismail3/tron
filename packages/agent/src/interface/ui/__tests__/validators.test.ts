/**
 * @fileoverview Tests for UI Component Validators
 *
 * TDD: Validates the UI validation functions used by RenderAppUI tool.
 */

import { describe, it, expect } from 'vitest';
import {
  validateRenderAppUIParams,
  validateUIComponent,
} from '../validators.js';

describe('UI Validators', () => {
  describe('validateRenderAppUIParams', () => {
    it('should validate minimal valid params', () => {
      const result = validateRenderAppUIParams({
        canvasId: 'test',
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      expect(result.valid).toBe(true);
      expect(result.errors).toHaveLength(0);
    });

    it('should not require canvasId (optional with auto-generation)', () => {
      const result = validateRenderAppUIParams({
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      expect(result.valid).toBe(true);
    });

    it('should reject invalid canvasId if provided', () => {
      const result = validateRenderAppUIParams({
        canvasId: 123, // Invalid - not a string
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      expect(result.valid).toBe(false);
      expect(result.errors.some((e) => e.toLowerCase().includes('canvasid'))).toBe(true);
    });

    it('should require ui', () => {
      const result = validateRenderAppUIParams({
        canvasId: 'test',
      });
      expect(result.valid).toBe(false);
      expect(result.errors.some((e) => e.toLowerCase().includes('ui'))).toBe(true);
    });

    it('should validate optional title as string', () => {
      const result = validateRenderAppUIParams({
        canvasId: 'test',
        title: 123, // Invalid - not a string
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      expect(result.valid).toBe(false);
      expect(result.errors.some((e) => e.toLowerCase().includes('title'))).toBe(true);
    });

    it('should validate optional state as object', () => {
      const result = validateRenderAppUIParams({
        canvasId: 'test',
        ui: { $tag: 'Text', $children: 'Hello' },
        state: 'not-an-object',
      });
      expect(result.valid).toBe(false);
      expect(result.errors.some((e) => e.toLowerCase().includes('state'))).toBe(true);
    });

    it('should pass with valid state object', () => {
      const result = validateRenderAppUIParams({
        canvasId: 'test',
        ui: { $tag: 'Text', $children: 'Hello' },
        state: { toggle1: true, slider1: 0.5 },
      });
      expect(result.valid).toBe(true);
    });

    it('should reject null params', () => {
      const result = validateRenderAppUIParams(null);
      expect(result.valid).toBe(false);
    });

    it('should reject non-object params', () => {
      const result = validateRenderAppUIParams('invalid');
      expect(result.valid).toBe(false);
    });
  });

  describe('validateUIComponent', () => {
    describe('basic validation', () => {
      it('should require $tag property', () => {
        const result = validateUIComponent({});
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('$tag'))).toBe(true);
      });

      it('should reject unknown tags', () => {
        const result = validateUIComponent({ $tag: 'UnknownComponent' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.toLowerCase().includes('unknown'))).toBe(true);
      });

      it('should accept all valid layout tags', () => {
        const layoutTags = ['VStack', 'HStack', 'ZStack', 'ScrollView', 'Spacer', 'Divider'];
        for (const tag of layoutTags) {
          const result = validateUIComponent({ $tag: tag });
          // Spacer and Divider need no children, others need arrays
          if (tag !== 'Spacer' && tag !== 'Divider') {
            const resultWithChildren = validateUIComponent({ $tag: tag, $children: [] });
            expect(resultWithChildren.errors.filter((e) => e.includes('Unknown'))).toHaveLength(0);
          }
        }
      });

      it('should accept all valid content tags', () => {
        const contentTags = [
          { $tag: 'Text', $children: 'Hello' },
          { $tag: 'Icon', $props: { name: 'star' } },
          { $tag: 'Image', $props: { data: 'base64...' } },
        ];
        for (const comp of contentTags) {
          const result = validateUIComponent(comp);
          expect(result.errors.filter((e) => e.includes('Unknown'))).toHaveLength(0);
        }
      });
    });

    describe('Button validation', () => {
      it('should require label and actionId', () => {
        const result = validateUIComponent({ $tag: 'Button' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('label'))).toBe(true);
        expect(result.errors.some((e) => e.includes('actionId'))).toBe(true);
      });

      it('should pass with valid props', () => {
        const result = validateUIComponent({
          $tag: 'Button',
          $props: { label: 'Click', actionId: 'action1' },
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('Toggle validation', () => {
      it('should require label and bindingId', () => {
        const result = validateUIComponent({ $tag: 'Toggle' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('label'))).toBe(true);
        expect(result.errors.some((e) => e.includes('bindingId'))).toBe(true);
      });

      it('should pass with valid props', () => {
        const result = validateUIComponent({
          $tag: 'Toggle',
          $props: { label: 'Enable', bindingId: 'toggle1' },
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('Slider validation', () => {
      it('should require bindingId', () => {
        const result = validateUIComponent({ $tag: 'Slider' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('bindingId'))).toBe(true);
      });

      it('should pass with valid props', () => {
        const result = validateUIComponent({
          $tag: 'Slider',
          $props: { bindingId: 'slider1' },
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('TextField validation', () => {
      it('should require bindingId', () => {
        const result = validateUIComponent({ $tag: 'TextField' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('bindingId'))).toBe(true);
      });

      it('should pass with valid props', () => {
        const result = validateUIComponent({
          $tag: 'TextField',
          $props: { bindingId: 'field1' },
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('Picker validation', () => {
      it('should require bindingId and options', () => {
        const result = validateUIComponent({ $tag: 'Picker' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('bindingId'))).toBe(true);
        expect(result.errors.some((e) => e.includes('options'))).toBe(true);
      });

      it('should pass with valid props', () => {
        const result = validateUIComponent({
          $tag: 'Picker',
          $props: {
            bindingId: 'picker1',
            options: [{ label: 'One', value: '1' }],
          },
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('List validation', () => {
      it('should require items array', () => {
        const result = validateUIComponent({ $tag: 'List' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('items'))).toBe(true);
      });

      it('should pass with valid props', () => {
        const result = validateUIComponent({
          $tag: 'List',
          $props: { items: [{ id: '1' }, { id: '2' }] },
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('Icon validation', () => {
      it('should require name prop', () => {
        const result = validateUIComponent({ $tag: 'Icon' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('name'))).toBe(true);
      });

      it('should pass with valid props', () => {
        const result = validateUIComponent({
          $tag: 'Icon',
          $props: { name: 'star.fill' },
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('Badge validation', () => {
      it('should require text prop', () => {
        const result = validateUIComponent({ $tag: 'Badge' });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('text'))).toBe(true);
      });

      it('should pass with valid props', () => {
        const result = validateUIComponent({
          $tag: 'Badge',
          $props: { text: 'New' },
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('nested components', () => {
      it('should validate children recursively', () => {
        const result = validateUIComponent({
          $tag: 'VStack',
          $children: [
            { $tag: 'Button' }, // Invalid - missing props
            { $tag: 'Text', $children: 'Valid' },
          ],
        });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('Button'))).toBe(true);
      });

      it('should pass with valid nested structure', () => {
        const result = validateUIComponent({
          $tag: 'VStack',
          $children: [
            { $tag: 'Button', $props: { label: 'OK', actionId: 'ok' } },
            { $tag: 'Text', $children: 'Hello' },
          ],
        });
        expect(result.valid).toBe(true);
      });

      it('should support deeply nested structures', () => {
        const result = validateUIComponent({
          $tag: 'VStack',
          $children: [
            {
              $tag: 'HStack',
              $children: [
                {
                  $tag: 'Section',
                  $children: [
                    { $tag: 'Button', $props: { label: 'A', actionId: 'a' } },
                  ],
                },
              ],
            },
          ],
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('depth limit', () => {
      it('should enforce depth limit of 50', () => {
        // Create deeply nested structure
        let ui: unknown = { $tag: 'Text', $children: 'deep' };
        for (let i = 0; i < 60; i++) {
          ui = { $tag: 'VStack', $children: [ui] };
        }
        const result = validateUIComponent(ui);
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('depth'))).toBe(true);
      });
    });

    describe('Text component', () => {
      it('should require string children', () => {
        const result = validateUIComponent({
          $tag: 'Text',
          $children: [{ $tag: 'Button' }], // Wrong type
        });
        expect(result.valid).toBe(false);
        expect(result.errors.some((e) => e.includes('string'))).toBe(true);
      });

      it('should pass with string children', () => {
        const result = validateUIComponent({
          $tag: 'Text',
          $children: 'Hello world',
        });
        expect(result.valid).toBe(true);
      });
    });

    describe('warnings', () => {
      it('should warn when children provided to non-container components', () => {
        const result = validateUIComponent({
          $tag: 'Button',
          $props: { label: 'OK', actionId: 'ok' },
          $children: [{ $tag: 'Text', $children: 'nested' }],
        });
        // Valid but with warning
        expect(result.valid).toBe(true);
        expect(result.warnings.some((w) => w.includes('ignores'))).toBe(true);
      });
    });
  });
});
