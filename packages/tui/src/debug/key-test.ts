#!/usr/bin/env npx tsx
/**
 * Key sequence tester - run this to see what escape sequences
 * your terminal sends for various key combinations.
 *
 * Usage: npx tsx packages/tui/src/debug/key-test.ts
 *
 * Tests Kitty keyboard protocol support for Shift+Enter and Alt+Enter.
 */

import * as readline from 'readline';

// Enable Kitty keyboard protocol for enhanced key detection
process.stdout.write('\x1b[>1u');
console.log('Kitty keyboard protocol ENABLED\n');

const cleanup = () => {
  console.log('\n\nDisabling Kitty protocol...');
  process.stdout.write('\x1b[<u');
  process.exit();
};

process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);

readline.emitKeypressEvents(process.stdin);
if (process.stdin.isTTY) {
  process.stdin.setRawMode(true);
}

console.log('Press any key combination to see its escape sequence.');
console.log('Try: Shift+Enter, Option+Enter (Alt+Enter), Ctrl+C');
console.log('Press Ctrl+C to exit.\n');

// Also listen to raw data to see unprocessed sequences
process.stdin.on('data', (data) => {
  const str = data.toString('utf8');
  const hex = data.toString('hex');

  // Check for Kitty Shift+Enter: \x1b[13;2u
  if (/^\x1b\[13;2u$/.test(str)) {
    console.log('>>> DETECTED: Kitty Shift+Enter! (\\x1b[13;2u)');
  }
  // Check for Kitty Alt+Enter: \x1b[13;3u
  if (/^\x1b\[13;3u$/.test(str)) {
    console.log('>>> DETECTED: Kitty Alt+Enter! (\\x1b[13;3u)');
  }
  // Check for standard Alt+Enter: ESC + Enter
  if (str === '\x1b\r' || str === '\x1b\n') {
    console.log('>>> DETECTED: Standard Alt+Enter! (ESC + Enter)');
  }

  console.log('Raw data - Hex:', hex, '| String:', JSON.stringify(str));
});

process.stdin.on('keypress', (str, key) => {
  // Show the raw string as hex
  const hex = str ? Buffer.from(str).toString('hex') : 'none';
  const chars = str ? str.split('').map((c: string) => c.charCodeAt(0)).join(', ') : 'none';

  console.log('---');
  console.log('Keypress - String:', JSON.stringify(str));
  console.log('Hex:', hex);
  console.log('Char codes:', chars);
  console.log('Key object:', JSON.stringify(key, null, 2));

  if (key && key.ctrl && key.name === 'c') {
    cleanup();
  }
});
