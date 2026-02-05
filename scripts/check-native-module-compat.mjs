#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '..');
const nvmrcPath = resolve(repoRoot, '.nvmrc');

function fail(message, details) {
  console.error(`[check:native] ${message}`);
  if (details) {
    console.error(details.trim());
  }
  process.exit(1);
}

function getExpectedNodeMajor() {
  if (!existsSync(nvmrcPath)) {
    return null;
  }

  const raw = readFileSync(nvmrcPath, 'utf8').trim().replace(/^v/, '');
  const major = Number.parseInt(raw.split('.')[0] ?? '', 10);
  if (Number.isNaN(major)) {
    return null;
  }

  return { raw, major };
}

function checkPinnedNodeMajor() {
  const expected = getExpectedNodeMajor();
  if (!expected) {
    return;
  }

  const currentMajor = Number.parseInt(process.versions.node.split('.')[0] ?? '', 10);
  if (currentMajor === expected.major) {
    return;
  }

  const message = `Node ${process.version} does not match repository runtime ${expected.raw} from .nvmrc.`;
  const guidance = 'Run `nvm use` (or switch your Node version manager) before running tests.';
  if (process.env.TRON_STRICT_NODE_VERSION === '1') {
    fail(message, guidance);
  }

  console.warn(`[check:native] ${message}`);
  console.warn(`[check:native] ${guidance}`);
  console.warn('[check:native] Continuing in non-strict mode.');
}

function runRequireCheck() {
  const agentPath = resolve(repoRoot, 'packages', 'agent');
  const checkScript = `
    const resolved = require.resolve('better-sqlite3', { paths: [${JSON.stringify(agentPath)}, ${JSON.stringify(repoRoot)}] });
    const BetterSqlite3 = require(resolved);
    const db = new BetterSqlite3(':memory:');
    db.close();
  `;

  return spawnSync(process.execPath, ['-e', checkScript], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
}

function isAbiMismatch(output) {
  const patterns = [
    'NODE_MODULE_VERSION',
    'was compiled against a different Node.js version',
    'Module did not self-register',
  ];
  return patterns.some((pattern) => output.includes(pattern));
}

function ensureBetterSqlite3Compat() {
  const initial = runRequireCheck();
  if (initial.status === 0) {
    return;
  }

  const output = `${initial.stderr ?? ''}\n${initial.stdout ?? ''}`;

  if (output.includes("Cannot find module 'better-sqlite3'")) {
    fail('better-sqlite3 is not installed.', 'Run `bun install` to install dependencies first.');
  }

  if (!isAbiMismatch(output)) {
    fail('Failed to load better-sqlite3.', output);
  }

  console.warn('[check:native] Detected better-sqlite3 ABI mismatch. Rebuilding native module...');
  const rebuild = spawnSync('npm', ['rebuild', 'better-sqlite3'], {
    cwd: repoRoot,
    stdio: 'inherit',
  });
  if (rebuild.status !== 0) {
    fail('`npm rebuild better-sqlite3` failed.');
  }

  const verify = runRequireCheck();
  if (verify.status === 0) {
    console.warn('[check:native] better-sqlite3 rebuild complete.');
    return;
  }

  const verifyOutput = `${verify.stderr ?? ''}\n${verify.stdout ?? ''}`;
  fail('better-sqlite3 is still incompatible after rebuild.', verifyOutput);
}

checkPinnedNodeMajor();
ensureBetterSqlite3Compat();
