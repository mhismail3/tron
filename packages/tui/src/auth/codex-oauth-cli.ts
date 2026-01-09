/**
 * @fileoverview OpenAI Codex OAuth CLI
 *
 * Provides OAuth authentication for OpenAI Codex (ChatGPT Plus/Pro subscription).
 * Run with: npx tsx packages/tui/src/auth/codex-oauth-cli.ts
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import * as readline from 'readline';
import { randomBytes, createHash } from 'crypto';

// =============================================================================
// Types
// =============================================================================

interface CodexTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

// =============================================================================
// Configuration
// =============================================================================

// OpenAI Codex OAuth configuration from pi-mono project
// https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/utils/oauth/openai-codex.ts
const CODEX_CONFIG = {
  clientId: 'app_EMoamEEZ73f0CkXaXp7hrann',
  authUrl: 'https://auth.openai.com/oauth/authorize',
  tokenUrl: 'https://auth.openai.com/oauth/token',
  redirectUri: 'http://localhost:1455/auth/callback',
  scopes: 'openid profile email offline_access',
};

const CODEX_TOKENS_PATH = path.join(os.homedir(), '.tron', 'codex-tokens.json');

// =============================================================================
// PKCE Helper Functions
// =============================================================================

function base64urlEncode(buffer: Buffer): string {
  return buffer.toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
}

async function generatePkce(): Promise<{ codeVerifier: string; codeChallenge: string }> {
  const codeVerifier = base64urlEncode(randomBytes(32));
  const hash = createHash('sha256').update(codeVerifier).digest();
  const codeChallenge = base64urlEncode(hash);
  return { codeVerifier, codeChallenge };
}

// =============================================================================
// Token Storage
// =============================================================================

async function saveTokens(tokens: CodexTokens): Promise<void> {
  const dir = path.dirname(CODEX_TOKENS_PATH);
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(CODEX_TOKENS_PATH, JSON.stringify(tokens, null, 2), {
    mode: 0o600,
  });
}

async function loadTokens(): Promise<CodexTokens | null> {
  try {
    const data = await fs.readFile(CODEX_TOKENS_PATH, 'utf-8');
    return JSON.parse(data) as CodexTokens;
  } catch {
    return null;
  }
}

async function deleteTokens(): Promise<void> {
  try {
    await fs.unlink(CODEX_TOKENS_PATH);
  } catch {
    // Ignore if doesn't exist
  }
}

// =============================================================================
// Local Callback Server
// =============================================================================

async function startCallbackServer(
  codeVerifier: string
): Promise<CodexTokens> {
  const http = await import('http');

  return new Promise((resolve, reject) => {
    const server = http.createServer(async (req, res) => {
      try {
        const url = new URL(req.url ?? '/', `http://localhost:1455`);

        if (url.pathname === '/auth/callback') {
          const code = url.searchParams.get('code');
          const error = url.searchParams.get('error');
          const errorDescription = url.searchParams.get('error_description');

          if (error) {
            res.writeHead(400, { 'Content-Type': 'text/html' });
            res.end(`<h1>Authentication Failed</h1><p>${errorDescription || error}</p>`);
            server.close();
            reject(new Error(`OAuth error: ${errorDescription || error}`));
            return;
          }

          if (!code) {
            res.writeHead(400, { 'Content-Type': 'text/html' });
            res.end('<h1>Error</h1><p>No authorization code received</p>');
            server.close();
            reject(new Error('No authorization code received'));
            return;
          }

          // Exchange code for tokens
          console.log('\nExchanging authorization code for tokens...');

          const tokenResponse = await fetch(CODEX_CONFIG.tokenUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              grant_type: 'authorization_code',
              client_id: CODEX_CONFIG.clientId,
              code,
              redirect_uri: CODEX_CONFIG.redirectUri,
              code_verifier: codeVerifier,
            }),
          });

          if (!tokenResponse.ok) {
            const errorText = await tokenResponse.text();
            res.writeHead(400, { 'Content-Type': 'text/html' });
            res.end(`<h1>Token Exchange Failed</h1><pre>${errorText}</pre>`);
            server.close();
            reject(new Error(`Token exchange failed: ${errorText}`));
            return;
          }

          const tokenData = await tokenResponse.json() as {
            access_token: string;
            refresh_token: string;
            expires_in: number;
          };

          const tokens: CodexTokens = {
            accessToken: tokenData.access_token,
            refreshToken: tokenData.refresh_token,
            expiresAt: Date.now() + tokenData.expires_in * 1000,
          };

          // Show success page
          res.writeHead(200, { 'Content-Type': 'text/html' });
          res.end(`
            <html>
              <head><title>Authentication Successful</title></head>
              <body style="font-family: system-ui; padding: 40px; text-align: center;">
                <h1 style="color: #10b981;">✓ Authentication Successful</h1>
                <p>You can close this tab and return to the terminal.</p>
              </body>
            </html>
          `);

          server.close();
          resolve(tokens);
        } else {
          res.writeHead(404);
          res.end('Not found');
        }
      } catch (error) {
        console.error('Callback error:', error);
        res.writeHead(500, { 'Content-Type': 'text/html' });
        res.end('<h1>Internal Error</h1>');
        server.close();
        reject(error);
      }
    });

    server.on('error', (error) => {
      reject(error);
    });

    server.listen(1455, 'localhost', () => {
      console.log('Waiting for authentication callback on http://localhost:1455/auth/callback...');
    });

    // Timeout after 5 minutes
    setTimeout(() => {
      server.close();
      reject(new Error('Authentication timed out'));
    }, 5 * 60 * 1000);
  });
}

// =============================================================================
// CLI Commands
// =============================================================================

async function login(): Promise<void> {
  console.log('\n🔐 OpenAI Codex Authentication\n');

  // Check existing tokens
  const existing = await loadTokens();
  if (existing && existing.expiresAt > Date.now()) {
    console.log('You are already authenticated.');
    console.log(`Token expires: ${new Date(existing.expiresAt).toLocaleString()}`);

    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });

    const answer = await new Promise<string>((resolve) => {
      rl.question('Do you want to re-authenticate? (y/N): ', resolve);
    });
    rl.close();

    if (answer.toLowerCase() !== 'y') {
      return;
    }
  }

  // Generate PKCE
  const { codeVerifier, codeChallenge } = await generatePkce();

  // Generate state parameter (required by OpenAI, must be at least 8 chars)
  const state = base64urlEncode(randomBytes(32));

  // Build auth URL (matching pi-mono's implementation)
  const authParams = new URLSearchParams({
    client_id: CODEX_CONFIG.clientId,
    response_type: 'code',
    redirect_uri: CODEX_CONFIG.redirectUri,
    scope: CODEX_CONFIG.scopes,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
    state: state,
  });

  const authUrl = `${CODEX_CONFIG.authUrl}?${authParams.toString()}`;

  console.log('Opening browser for authentication...\n');
  console.log('If the browser does not open, visit this URL:\n');
  console.log(authUrl);
  console.log('');

  // Open browser
  const { exec } = await import('child_process');
  const platform = process.platform;
  const openCommand =
    platform === 'darwin' ? 'open' :
    platform === 'win32' ? 'start' : 'xdg-open';

  exec(`${openCommand} "${authUrl}"`);

  // Start callback server and wait for tokens
  try {
    const tokens = await startCallbackServer(codeVerifier);
    await saveTokens(tokens);

    console.log('\n✅ Authentication successful!');
    console.log(`Tokens saved to: ${CODEX_TOKENS_PATH}`);
    console.log(`Token expires: ${new Date(tokens.expiresAt).toLocaleString()}`);
    console.log('\nYou can now use OpenAI Codex models in Tron.');
  } catch (error) {
    console.error('\n❌ Authentication failed:', error instanceof Error ? error.message : error);
    process.exit(1);
  }
}

async function logout(): Promise<void> {
  await deleteTokens();
  console.log('✅ Logged out. Codex tokens deleted.');
}

async function status(): Promise<void> {
  const tokens = await loadTokens();

  if (!tokens) {
    console.log('❌ Not authenticated with OpenAI Codex.');
    console.log('\nRun: npx tsx packages/tui/src/auth/codex-oauth-cli.ts login');
    return;
  }

  const now = Date.now();
  const expiresIn = tokens.expiresAt - now;

  if (expiresIn <= 0) {
    console.log('⚠️  Tokens expired. Please re-authenticate.');
  } else {
    console.log('✅ Authenticated with OpenAI Codex');
    console.log(`Token expires: ${new Date(tokens.expiresAt).toLocaleString()}`);
    console.log(`Time remaining: ${Math.round(expiresIn / 1000 / 60)} minutes`);
  }
}

async function refresh(): Promise<void> {
  const tokens = await loadTokens();

  if (!tokens || !tokens.refreshToken) {
    console.log('❌ No tokens to refresh. Please login first.');
    process.exit(1);
  }

  console.log('Refreshing tokens...');

  try {
    const response = await fetch(CODEX_CONFIG.tokenUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        grant_type: 'refresh_token',
        client_id: CODEX_CONFIG.clientId,
        refresh_token: tokens.refreshToken,
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Token refresh failed: ${error}`);
    }

    const data = await response.json() as {
      access_token: string;
      refresh_token: string;
      expires_in: number;
    };

    const newTokens: CodexTokens = {
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      expiresAt: Date.now() + data.expires_in * 1000,
    };

    await saveTokens(newTokens);
    console.log('✅ Tokens refreshed successfully!');
    console.log(`New expiry: ${new Date(newTokens.expiresAt).toLocaleString()}`);
  } catch (error) {
    console.error('❌ Failed to refresh tokens:', error instanceof Error ? error.message : error);
    console.log('Please login again.');
    process.exit(1);
  }
}

// =============================================================================
// Main
// =============================================================================

async function main() {
  const command = process.argv[2] || 'login';

  switch (command) {
    case 'login':
      await login();
      break;
    case 'logout':
      await logout();
      break;
    case 'status':
      await status();
      break;
    case 'refresh':
      await refresh();
      break;
    case 'help':
    case '--help':
    case '-h':
      console.log(`
OpenAI Codex OAuth CLI

Usage:
  npx tsx packages/tui/src/auth/codex-oauth-cli.ts [command]

Commands:
  login     Authenticate with OpenAI (default)
  logout    Clear stored tokens
  status    Check authentication status
  refresh   Refresh access token
  help      Show this help message

The tokens are stored at: ~/.tron/codex-tokens.json
`);
      break;
    default:
      console.error(`Unknown command: ${command}`);
      console.log('Run with --help for usage information.');
      process.exit(1);
  }
}

main().catch((error) => {
  console.error('Error:', error);
  process.exit(1);
});
