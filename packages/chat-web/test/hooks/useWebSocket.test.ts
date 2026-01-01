/**
 * @fileoverview Tests for useWebSocket hook
 */
import { describe, it, expect, vi } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useWebSocket } from '../../src/hooks/useWebSocket.js';

describe('useWebSocket', () => {
  it('should start in disconnected state', () => {
    const { result } = renderHook(() => useWebSocket());
    expect(result.current.status).toBe('disconnected');
  });

  it('should change to connecting when connect is called', () => {
    const { result } = renderHook(() => useWebSocket());

    act(() => {
      result.current.connect();
    });

    expect(result.current.status).toBe('connecting');
  });

  it('should provide send function', () => {
    const { result } = renderHook(() => useWebSocket());

    // Send should exist and be callable (even if not connected)
    expect(typeof result.current.send).toBe('function');
  });

  it('should provide subscribe function that returns unsubscribe', () => {
    const { result } = renderHook(() => useWebSocket());
    const handler = vi.fn();

    const unsubscribe = result.current.subscribe(handler);
    expect(typeof unsubscribe).toBe('function');

    // Cleanup
    unsubscribe();
  });

  it('should start with null lastMessage', () => {
    const { result } = renderHook(() => useWebSocket());
    expect(result.current.lastMessage).toBeNull();
  });

  it('should provide disconnect function', () => {
    const { result } = renderHook(() => useWebSocket());
    expect(typeof result.current.disconnect).toBe('function');
  });

  it('should change to disconnected after disconnect', () => {
    const { result } = renderHook(() => useWebSocket());

    act(() => {
      result.current.connect();
    });

    act(() => {
      result.current.disconnect();
    });

    expect(result.current.status).toBe('disconnected');
  });
});
