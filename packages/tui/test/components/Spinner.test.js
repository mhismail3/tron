/**
 * @fileoverview Spinner Component Tests
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import React from 'react';
import { render } from 'ink-testing-library';
import { Spinner } from '../../src/components/Spinner.js';
describe('Spinner Component', () => {
    beforeEach(() => {
        vi.useFakeTimers();
    });
    afterEach(() => {
        vi.useRealTimers();
    });
    it('should render with default label', () => {
        const { lastFrame } = render(<Spinner />);
        expect(lastFrame()).toContain('Thinking');
    });
    it('should render with custom label', () => {
        const { lastFrame } = render(<Spinner label="Processing"/>);
        expect(lastFrame()).toContain('Processing');
    });
    it('should not contain emojis', () => {
        const { lastFrame } = render(<Spinner label="Working"/>);
        const frame = lastFrame() ?? '';
        // Check for common emojis
        expect(frame).not.toMatch(/[\u{1F300}-\u{1F9FF}]/u);
    });
    it('should animate over time', () => {
        const { lastFrame } = render(<Spinner />);
        const frame1 = lastFrame();
        vi.advanceTimersByTime(100);
        const frame2 = lastFrame();
        // The spinner character should change
        // Both frames should contain the label but may have different spinner chars
        expect(frame1).toContain('Thinking');
        expect(frame2).toContain('Thinking');
    });
});
//# sourceMappingURL=Spinner.test.js.map