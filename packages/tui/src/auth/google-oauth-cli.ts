/**
 * @fileoverview Google OAuth CLI
 *
 * Provides OAuth authentication for Google Gemini models.
 * Supports both Cloud Code Assist (production) and Antigravity (sandbox) endpoints.
 *
 * Run with: npx tsx packages/tui/src/auth/google-oauth-cli.ts [login|logout|status|refresh]
 */
import * as readline from 'readline';
import {
  generateGooglePKCE,
  getGoogleAuthorizationUrl,
  exchangeGoogleCodeForTokens,
  refreshGoogleOAuthToken,
  saveGoogleOAuthTokens,
  type GoogleOAuthEndpoint,
} from '@tron/agent';
import {
  getProviderAuth,
  clearProviderAuth,
} from '@tron/agent';

// =============================================================================
// Types
// =============================================================================

interface GoogleTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  endpoint?: GoogleOAuthEndpoint;
}

// =============================================================================
// Token Storage (using unified auth)
// =============================================================================

async function loadTokens(): Promise<GoogleTokens | null> {
  const auth = await getProviderAuth('google');
  if (!auth?.oauth) {
    return null;
  }
  return {
    accessToken: auth.oauth.accessToken,
    refreshToken: auth.oauth.refreshToken,
    expiresAt: auth.oauth.expiresAt,
    endpoint: (auth as any).endpoint as GoogleOAuthEndpoint | undefined,
  };
}

async function deleteTokens(): Promise<void> {
  await clearProviderAuth('google');
}

// =============================================================================
// Local Callback Server
// =============================================================================

async function startCallbackServer(
  verifier: string,
  endpoint: GoogleOAuthEndpoint
): Promise<GoogleTokens> {
  const http = await import('http');

  // Use endpoint-specific callback port
  // Antigravity uses 51121, Gemini CLI uses 45289
  const callbackPort = endpoint === 'antigravity' ? 51121 : 45289;

  return new Promise((resolve, reject) => {
    const server = http.createServer(async (req, res) => {
      try {
        const url = new URL(req.url ?? '/', `http://localhost:${callbackPort}`);

        if (url.pathname === '/' || url.pathname === '/callback' || url.pathname === '/oauth-callback') {
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

          try {
            const tokens = await exchangeGoogleCodeForTokens(code, verifier, endpoint);

            // Show success page
            res.writeHead(200, { 'Content-Type': 'text/html' });
            res.end(`
              <html>
                <head><title>Authentication Successful</title></head>
                <body style="font-family: system-ui; padding: 40px; text-align: center;">
                  <h1 style="color: #10b981;">✓ Google Authentication Successful</h1>
                  <p>You can close this tab and return to the terminal.</p>
                </body>
              </html>
            `);

            server.close();
            resolve({
              accessToken: tokens.accessToken,
              refreshToken: tokens.refreshToken,
              expiresAt: tokens.expiresAt,
              endpoint,
            });
          } catch (tokenError) {
            res.writeHead(400, { 'Content-Type': 'text/html' });
            res.end(`<h1>Token Exchange Failed</h1><pre>${tokenError instanceof Error ? tokenError.message : tokenError}</pre>`);
            server.close();
            reject(tokenError);
          }
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

    server.listen(callbackPort, 'localhost', () => {
      console.log(`Waiting for authentication callback on http://localhost:${callbackPort}...`);
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

async function login(endpoint: GoogleOAuthEndpoint = 'cloud-code-assist'): Promise<void> {
  const endpointName = endpoint === 'antigravity' ? 'Antigravity (Sandbox)' : 'Cloud Code Assist (Production)';
  console.log(`\n🔐 Google Gemini Authentication (${endpointName})\n`);

  // Check existing tokens
  const existing = await loadTokens();
  if (existing && existing.expiresAt > Date.now()) {
    console.log('You are already authenticated.');
    console.log(`Endpoint: ${existing.endpoint || 'cloud-code-assist'}`);
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
  const { verifier, challenge } = generateGooglePKCE();

  // Build auth URL
  const authUrl = getGoogleAuthorizationUrl(challenge, endpoint);

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
    const tokens = await startCallbackServer(verifier, endpoint);
    await saveGoogleOAuthTokens({
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: tokens.expiresAt,
    }, endpoint);

    console.log('\n✅ Authentication successful!');
    console.log('Tokens saved to: ~/.tron/auth.json (providers.google)');
    console.log(`Endpoint: ${endpoint}`);
    console.log(`Token expires: ${new Date(tokens.expiresAt).toLocaleString()}`);
    console.log('\nYou can now use Google Gemini models in Tron.');
  } catch (error) {
    console.error('\n❌ Authentication failed:', error instanceof Error ? error.message : error);
    process.exit(1);
  }
}

async function logout(): Promise<void> {
  await deleteTokens();
  console.log('✅ Logged out. Google tokens deleted.');
}

async function status(): Promise<void> {
  const tokens = await loadTokens();

  if (!tokens) {
    console.log('❌ Not authenticated with Google.');
    console.log('\nRun: npx tsx packages/tui/src/auth/google-oauth-cli.ts login');
    return;
  }

  const now = Date.now();
  const expiresIn = tokens.expiresAt - now;

  if (expiresIn <= 0) {
    console.log('⚠️  Tokens expired. Please re-authenticate or run refresh.');
  } else {
    console.log('✅ Authenticated with Google');
    console.log(`Endpoint: ${tokens.endpoint || 'cloud-code-assist'}`);
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
    const newTokens = await refreshGoogleOAuthToken(tokens.refreshToken, tokens.endpoint);

    await saveGoogleOAuthTokens(newTokens, tokens.endpoint);

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
  const endpointArg = process.argv[3];

  // Parse endpoint
  let endpoint: GoogleOAuthEndpoint = 'cloud-code-assist';
  if (endpointArg === 'antigravity' || endpointArg === 'sandbox') {
    endpoint = 'antigravity';
  }

  switch (command) {
    case 'login':
      await login(endpoint);
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
Google Gemini OAuth CLI

Usage:
  npx tsx packages/tui/src/auth/google-oauth-cli.ts [command] [endpoint]

Commands:
  login [endpoint]   Authenticate with Google (default: cloud-code-assist)
  logout             Clear stored tokens
  status             Check authentication status
  refresh            Refresh access token
  help               Show this help message

Endpoints:
  cloud-code-assist  Production endpoint (default, requires paid Google Cloud)
  antigravity        Sandbox endpoint (free tier, may have rate limits)
  sandbox            Alias for antigravity

Examples:
  npx tsx packages/tui/src/auth/google-oauth-cli.ts login
  npx tsx packages/tui/src/auth/google-oauth-cli.ts login antigravity
  npx tsx packages/tui/src/auth/google-oauth-cli.ts status
  npx tsx packages/tui/src/auth/google-oauth-cli.ts refresh

The tokens are stored at: ~/.tron/auth.json (providers.google)
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
