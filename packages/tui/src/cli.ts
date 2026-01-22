#!/usr/bin/env node
/**
 * @fileoverview Tron CLI Entry Point
 *
 * Main entry point for the Tron terminal interface.
 */
import { render } from 'ink';
import React from 'react';
import { parseArgs } from 'util';
import { App } from './app.js';
import type { CliConfig } from './types.js';
import { getAuth, login, logout } from './auth/index.js';
import { initializeDebug, debugLog } from './debug/index.js';
import { DEFAULT_MODEL, preloadSettings } from '@tron/agent';

// Start settings preload immediately (runs in parallel with arg parsing)
const settingsPromise = preloadSettings();

// =============================================================================
// Argument Parsing
// =============================================================================

interface ParsedArgs extends CliConfig {
  command?: 'login' | 'logout' | 'auth-status';
}

function parseCliArgs(): ParsedArgs {
  const { values, positionals } = parseArgs({
    options: {
      model: { type: 'string', short: 'm' },
      provider: { type: 'string', short: 'p' },
      resume: { type: 'string', short: 'r' },
      server: { type: 'boolean', short: 's' },
      'ws-port': { type: 'string' },
      'health-port': { type: 'string' },
      verbose: { type: 'boolean', short: 'v' },
      debug: { type: 'boolean', short: 'd' },
      help: { type: 'boolean', short: 'h' },
      version: { type: 'boolean' },
      prompt: { type: 'string' },
      'api-key': { type: 'string' },
      ephemeral: { type: 'boolean', short: 'e' },
    },
    allowPositionals: true,
    strict: false,
  });

  // Check for subcommands
  const firstArg = positionals[0];
  let command: ParsedArgs['command'] = undefined;
  let remainingPositionals = positionals;

  if (firstArg === 'login') {
    command = 'login';
    remainingPositionals = positionals.slice(1);
  } else if (firstArg === 'logout') {
    command = 'logout';
    remainingPositionals = positionals.slice(1);
  } else if (firstArg === 'auth' || firstArg === 'auth-status') {
    command = 'auth-status';
    remainingPositionals = positionals.slice(1);
  }

  // Handle help
  if (values.help) {
    printHelp();
    process.exit(0);
  }

  // Handle version
  if (values.version) {
    console.log('tron v0.1.0');
    process.exit(0);
  }

  // Get working directory from positionals or cwd
  const workingDirectory = remainingPositionals[0]
    ? (remainingPositionals[0].startsWith('/') ? remainingPositionals[0] : `${process.cwd()}/${remainingPositionals[0]}`)
    : process.cwd();

  return {
    command,
    workingDirectory,
    model: values.model as string | undefined,
    provider: values.provider as string | undefined,
    resumeSession: values.resume as string | undefined,
    serverMode: values.server as boolean,
    wsPort: values['ws-port'] ? parseInt(values['ws-port'] as string, 10) : undefined,
    healthPort: values['health-port'] ? parseInt(values['health-port'] as string, 10) : undefined,
    verbose: values.verbose as boolean,
    debug: values.debug as boolean,
    nonInteractive: !!values.prompt,
    initialPrompt: values.prompt as string | undefined,
    ephemeral: values.ephemeral as boolean,
  };
}

function printHelp(): void {
  console.log(`
Tron - Persistent Dual-Interface Coding Agent

USAGE:
  tron [command] [directory] [options]
  tron [options] [directory]

COMMANDS:
  login             Authenticate with Anthropic (OAuth for Claude Max)
  logout            Clear stored authentication
  auth              Show current authentication status

ARGUMENTS:
  [directory]       Working directory for the session (default: current directory)

OPTIONS:
  -m, --model <model>       Model to use (default: claude-opus-4-5-20250514)
  -p, --provider <provider> Provider to use (default: anthropic)
  -r, --resume <session>    Resume a specific session by ID
  -s, --server              Start in server mode (WebSocket + health endpoints)
  --ws-port <port>          WebSocket server port (default: 8080)
  --health-port <port>      Health check port (default: 8081)
  --api-key <key>           Set API key for authentication
  -e, --ephemeral           Ephemeral mode - no persistence (no session files or handoffs)
  -v, --verbose             Enable verbose logging
  -d, --debug               Enable debug mode (full trace logs to stderr and ~/.tron/logs/)
  --prompt <text>           Run a single prompt and exit (non-interactive)
  -h, --help                Show this help message
  --version                 Show version number

EXAMPLES:
  # Authenticate with Claude Max
  tron login

  # Start interactive session in current directory
  tron

  # Start session in a specific project
  tron ~/projects/my-app

  # Resume the most recent session
  tron -r latest

  # Run a single prompt
  tron --prompt "List all TypeScript files"

  # Start as a server
  tron --server --ws-port 8080

KEYBOARD SHORTCUTS:
  Ctrl+C    Exit the session
  Ctrl+L    Clear the screen
  Up/Down   Navigate history

For more information, visit: https://github.com/your-org/tron
`);
}

// =============================================================================
// Main
// =============================================================================

async function main(): Promise<void> {
  const config = parseCliArgs();

  // Initialize debug mode if enabled
  if (config.debug) {
    initializeDebug(true);
    debugLog.info('cli', 'Tron CLI starting', {
      workingDirectory: config.workingDirectory,
      model: config.model ?? DEFAULT_MODEL,
      provider: config.provider ?? 'anthropic',
      debug: true,
    });
  }

  // Handle auth commands
  if (config.command === 'login') {
    await runLogin();
    return;
  }

  if (config.command === 'logout') {
    await runLogout();
    return;
  }

  if (config.command === 'auth-status') {
    await runAuthStatus();
    return;
  }

  // Non-interactive mode
  if (config.nonInteractive && config.initialPrompt) {
    await runNonInteractive(config);
    return;
  }

  // Server mode
  if (config.serverMode) {
    await runServerMode(config);
    return;
  }

  // Interactive TUI mode
  await runInteractive(config);
}

async function runLogin(): Promise<void> {
  console.log('\nTron Authentication\n');

  // Check for environment variable - this takes precedence
  if (process.env.ANTHROPIC_API_KEY) {
    console.log('Warning: ANTHROPIC_API_KEY environment variable is set.');
    console.log('This takes precedence over stored OAuth tokens.');
    console.log('\nTo use OAuth instead, run:');
    console.log('  unset ANTHROPIC_API_KEY');
    console.log('  tron login\n');
    return;
  }

  // Clear any existing stored auth before OAuth login
  await logout(true);

  try {
    await login();
  } catch (error) {
    console.error(`Authentication failed: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}

async function runLogout(): Promise<void> {
  await logout();
}

async function runAuthStatus(): Promise<void> {
  console.log('\nTron Authentication Status\n');

  const auth = await getAuth();
  if (!auth) {
    console.log('Not authenticated.\n');
    console.log('Run "tron login" to authenticate with Claude Max,');
    console.log('or set ANTHROPIC_API_KEY environment variable.\n');
    return;
  }

  if (auth.type === 'api_key') {
    const masked = auth.apiKey.slice(0, 8) + '...' + auth.apiKey.slice(-4);
    console.log(`Auth type: API Key`);
    console.log(`Key: ${masked}\n`);
  } else {
    const expiresInMs = auth.expiresAt - Date.now();
    const expiresInMinutes = Math.floor(expiresInMs / 1000 / 60);
    const hours = Math.floor(expiresInMinutes / 60);
    const minutes = expiresInMinutes % 60;
    console.log(`Auth type: Claude Max (OAuth)`);
    console.log(`Token valid for: ${hours}h ${minutes}m (auto-refreshes)\n`);
  }
}

async function runInteractive(config: CliConfig): Promise<void> {
  // Check if terminal supports raw mode (required for interactive input)
  if (!process.stdin.isTTY) {
    console.error('\nError: Interactive mode requires a TTY terminal.');
    console.error('If you are using "tsx watch", use "tsx" instead (no watch mode).');
    console.error('\nAlternatives:');
    console.error('  npx tsx packages/tui/src/cli.ts     # Direct run');
    console.error('  npm run dev:tui                      # Uses tsx without watch');
    console.error('  tron --prompt "your query"           # Non-interactive mode');
    console.error('  tron --server                        # Server mode (no TTY needed)\n');
    process.exit(1);
  }

  const disableKittyKeyboard = () => {
    process.stdout.write('\x1b[<u');
  };

  // Enable Kitty keyboard protocol for modified keys like Shift+Enter.
  process.stdout.write('\x1b[>1u');
  process.on('exit', disableKittyKeyboard);

  // Suppress pino logs unless in debug mode
  // This must be set BEFORE any @tron/core imports that create loggers
  if (!config.debug) {
    process.env.LOG_LEVEL = 'silent';
  }

  // Clear terminal and move cursor to top-left
  // \x1b[2J = clear entire screen
  // \x1b[H = move cursor to home position (0,0)
  // \x1b[3J = clear scrollback buffer (optional, works in most modern terminals)
  process.stdout.write('\x1b[2J\x1b[H\x1b[3J');

  // Ensure settings are loaded before render (runs in parallel with auth check)
  const [auth] = await Promise.all([getAuth(), settingsPromise]);
  if (!auth) {
    console.log('\nNot authenticated.\n');
    console.log('Run "tron login" to authenticate with Claude Max,');
    console.log('or set ANTHROPIC_API_KEY environment variable.\n');
    process.exit(1);
  }

  const { waitUntilExit } = render(
    React.createElement(App, { config, auth })
  );

  try {
    await waitUntilExit();
  } finally {
    disableKittyKeyboard();
    process.removeListener('exit', disableKittyKeyboard);
  }
}

async function runNonInteractive(config: CliConfig): Promise<void> {
  // Check authentication
  const auth = await getAuth();
  if (!auth) {
    console.log('\nNot authenticated.\n');
    console.log('Run "tron login" to authenticate with Claude Max,');
    console.log('or set ANTHROPIC_API_KEY environment variable.\n');
    process.exit(1);
  }

  const {
    TronAgent,
    ReadTool,
    WriteTool,
    EditTool,
    BashTool,
    AstGrepTool,
  } = await import('@tron/agent');

  // Create tools
  const tools = [
    new ReadTool({ workingDirectory: config.workingDirectory }),
    new WriteTool({ workingDirectory: config.workingDirectory }),
    new EditTool({ workingDirectory: config.workingDirectory }),
    new BashTool({ workingDirectory: config.workingDirectory }),
    new AstGrepTool({ workingDirectory: config.workingDirectory }),
  ];

  // Create agent with auth
  const agent = new TronAgent({
    provider: {
      model: config.model ?? DEFAULT_MODEL,
      auth,
    },
    tools,
    maxTurns: 50,
  }, {
    workingDirectory: config.workingDirectory,
  });

  console.log(`\nProcessing: ${config.initialPrompt}\n`);

  // Run agent
  const result = await agent.run(config.initialPrompt!);

  if (result.success) {
    // Find the last assistant message and display it
    const lastAssistantMsg = [...result.messages].reverse().find(m => m.role === 'assistant');
    if (lastAssistantMsg && 'content' in lastAssistantMsg) {
      const content = lastAssistantMsg.content;
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === 'text') {
            console.log('\nResponse:\n');
            console.log(block.text);
          }
        }
      } else if (typeof content === 'string') {
        console.log('\nResponse:\n');
        console.log(content);
      }
    }
    console.log('\nDone\n');
    console.log(`Turns: ${result.turns}`);
    console.log(`Tokens: ${result.totalTokenUsage.inputTokens} in / ${result.totalTokenUsage.outputTokens} out`);
  } else {
    console.error(`\nError: ${result.error}\n`);
    process.exit(1);
  }
}

async function runServerMode(config: CliConfig): Promise<void> {
  // Dynamic import to avoid loading server in interactive mode
  const { TronServer } = await import('@tron/agent');

  // Respect env vars for ports and DB path (used by tron beta/prod scripts)
  const wsPort = config.wsPort
    ?? (process.env.TRON_WS_PORT ? parseInt(process.env.TRON_WS_PORT, 10) : 8080);
  const healthPort = config.healthPort
    ?? (process.env.TRON_HEALTH_PORT ? parseInt(process.env.TRON_HEALTH_PORT, 10) : 8081);
  const eventStoreDbPath = process.env.TRON_EVENT_STORE_DB;

  const server = new TronServer({
    wsPort,
    healthPort,
    eventStoreDbPath,
    defaultModel: config.model,
    defaultProvider: config.provider,
  });

  // Handle shutdown
  const shutdown = async (signal: string) => {
    console.log(`\nReceived ${signal}, shutting down...`);
    await server.stop();
    process.exit(0);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  await server.start();

  console.log(`
Tron Server Started

WebSocket: ws://localhost:${wsPort}/ws
Health:    http://localhost:${healthPort}/health

Press Ctrl+C to stop.
`);
}

// Run
main().catch((error) => {
  console.error('Error:', error.message);
  process.exit(1);
});
