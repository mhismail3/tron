#!/usr/bin/env npx tsx
/**
 * Key sequence tester - run this to see what escape sequences
 * your terminal sends for various key combinations.
 *
 * Usage: npx tsx packages/tui/src/debug/key-test.ts
 */

import * as readline from 'readline';

readline.emitKeypressEvents(process.stdin);
if (process.stdin.isTTY) {
  process.stdin.setRawMode(true);
}

console.log('Press any key combination to see its escape sequence.');
console.log('Press Ctrl+C to exit.\n');

process.stdin.on('keypress', (str, key) => {
  // Show the raw string as hex
  const hex = str ? Buffer.from(str).toString('hex') : 'none';
  const chars = str ? str.split('').map((c: string) => c.charCodeAt(0)).join(', ') : 'none';

  console.log('---');
  console.log('String:', JSON.stringify(str));
  console.log('Hex:', hex);
  console.log('Char codes:', chars);
  console.log('Key object:', JSON.stringify(key, null, 2));

  if (key && key.ctrl && key.name === 'c') {
    process.exit();
  }
});
