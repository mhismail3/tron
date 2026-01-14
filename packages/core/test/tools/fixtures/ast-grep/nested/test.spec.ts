// Test spec fixture for glob filtering tests

import { describe, it, expect } from 'vitest';

describe('Sample tests', () => {
  it('test one', () => {
    console.log('Running test one');
    expect(1 + 1).toBe(2);
  });

  it('test two', () => {
    console.log('Running test two');
    expect(2 * 2).toBe(4);
  });

  it('should handle async', async () => {
    const result = await Promise.resolve(42);
    expect(result).toBe(42);
  });
});

function helperFunction(value: number): number {
  return value * 2;
}

export { helperFunction };
