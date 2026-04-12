# Account management

## First-time setup (cold start)

For a machine with no GCP project, no OAuth client, and no `gws` auth at all, do these in order. Skip to "Auth status" below if `gws auth status` already returns a valid account.

1. **Install the CLI:**
   ```bash
   brew install googleworkspace-cli
   ```

2. **Pick or create a GCP project** at https://console.cloud.google.com/projectcreate. Enable billing only if you'll use paid APIs — most Workspace APIs (Gmail, Drive, Calendar, Docs, Forms, Sheets, Slides) are free-tier.

3. **Enable the APIs you need** on that project at https://console.cloud.google.com/apis/library. Typical set: Gmail API, Google Drive API, Google Calendar API, Google Docs API, Google Forms API, Google Sheets API, Google Slides API, Google Chat API, Cloud Pub/Sub API. API enablement is per-project — a `PERMISSION_DENIED` later almost always means you forgot to enable that service.

4. **Configure the OAuth consent screen** at https://console.cloud.google.com/apis/credentials/consent:
   - User type: `External`
   - Publishing status: `Testing` is fine for a single-user setup (add your own Google account as a test user)
   - **Heads up**: Testing mode refresh tokens expire every 7 days. For long-running headless use, click "Publish app" once you're confident in the scopes.

5. **Create OAuth credentials** at https://console.cloud.google.com/apis/credentials → "Create Credentials" → "OAuth client ID" → application type **Desktop app**. Download the `client_secret_*.json` file.

6. **Store client credentials in the vault:**
   ```bash
   # Extract client_id and client_secret from the downloaded JSON
   CLIENT_ID=$(jq -r '.installed.client_id' ~/Downloads/client_secret_*.json)
   CLIENT_SECRET=$(jq -r '.installed.client_secret' ~/Downloads/client_secret_*.json)

   ~/.tron/skills/vault/scripts/vault.sh set google-workspace-client \
     --type password \
     --desc "OAuth client credentials (client_id + client_secret) for the gws CLI" \
     --tags "google,gws,oauth" \
     --field username="$CLIENT_ID" \
     --field password="$CLIENT_SECRET"

   # Delete the downloaded JSON — vault is the canonical store
   rm ~/Downloads/client_secret_*.json
   ```

7. **Run the interactive login** (pulls client creds from vault):
   ```bash
   CLIENT_ID=$(~/.tron/skills/vault/scripts/vault.sh get google-workspace-client --field username)
   CLIENT_SECRET=$(~/.tron/skills/vault/scripts/vault.sh get google-workspace-client --field password)
   GOOGLE_WORKSPACE_CLI_CLIENT_ID="$CLIENT_ID" \
   GOOGLE_WORKSPACE_CLI_CLIENT_SECRET="$CLIENT_SECRET" \
   gws auth login
   ```
   This opens a browser, completes OAuth, and persists tokens to `gws`'s own state dir. Use scope flags if you want narrower access (see "Scopes" below).

8. **Verify:**
   ```bash
   CLIENT_ID=$(~/.tron/skills/vault/scripts/vault.sh get google-workspace-client --field username)
   CLIENT_SECRET=$(~/.tron/skills/vault/scripts/vault.sh get google-workspace-client --field password)
   GOOGLE_WORKSPACE_CLI_CLIENT_ID="$CLIENT_ID" \
   GOOGLE_WORKSPACE_CLI_CLIENT_SECRET="$CLIENT_SECRET" \
   gws auth status
   ```
   Should show your account and `Token valid: yes`.

9. **Store the user credentials (tokens) in the vault** — see "Storing credentials in the vault" below.

## Auth status

```bash
gws auth status
```

Shows the current authentication state: logged-in account, token expiry, enabled scopes.

## Vault entries

Two vault entries are used:

| Entry name | Type | Fields | Purpose |
|---|---|---|---|
| `google-workspace-client` | password | `username` (client_id), `password` (client_secret) | OAuth app identity — needed for login and every API call |
| `google-workspace-cli` | secret | `value` (authorized-user JSON) | User tokens (refresh + access) — obtained after `gws auth login` |

Both are required. Client credentials identify the OAuth app; user credentials authorize the account.

## Storing user credentials in the vault

After `gws auth login`, export the tokens to the vault. Use `set` for first-time, `update` to refresh:

```bash
VAULT=~/.tron/skills/vault/scripts/vault.sh
CLIENT_ID=$($VAULT get google-workspace-client --field username)
CLIENT_SECRET=$($VAULT get google-workspace-client --field password)
TMP=$(mktemp) && trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
GOOGLE_WORKSPACE_CLI_CLIENT_ID="$CLIENT_ID" \
GOOGLE_WORKSPACE_CLI_CLIENT_SECRET="$CLIENT_SECRET" \
gws auth export --unmasked > "$TMP"

# First time:
$VAULT set google-workspace-cli \
  --type secret \
  --desc "Authorized-user JSON for the gws Google Workspace CLI" \
  --tags "google,gws,oauth" \
  --field-file value="$TMP"

# Or to refresh an existing entry:
$VAULT update google-workspace-cli --field-file value="$TMP"
```

Why the temp file: `vault.sh set --field-file` accepts file paths only, and writing through `mktemp` keeps the secret off the process arg list and out of shell history. The `trap` ensures cleanup even on error.

To inspect the metadata (no secret values shown):

```bash
~/.tron/skills/vault/scripts/vault.sh list | grep -A2 google-workspace-cli
```

## Using the credentials with gws (per-call materialization)

Every `gws` call needs three env vars: the client identity (from `google-workspace-client`) and the user token file (from `google-workspace-cli`). **Do not** keep long-lived plaintext copies on disk.

```bash
# Pattern for a single gws call
VAULT=~/.tron/skills/vault/scripts/vault.sh
CLIENT_ID=$($VAULT get google-workspace-client --field username)
CLIENT_SECRET=$($VAULT get google-workspace-client --field password)
TMP=$(mktemp) && trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
$VAULT get google-workspace-cli --field value > "$TMP"
GOOGLE_WORKSPACE_CLI_CLIENT_ID="$CLIENT_ID" \
GOOGLE_WORKSPACE_CLI_CLIENT_SECRET="$CLIENT_SECRET" \
GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="$TMP" \
gws gmail +triage --max 10
```

For a sequence of calls, materialize once at the top of your script and clean up at the end via `trap`. Always:

- `chmod 600` the temp file before writing to it.
- Use `mktemp` (never a hardcoded path).
- Set `trap 'rm -f "$TMP"' EXIT` so the file is removed even on failure.
- Set all three env vars inline per-command (not via `export`) so they don't leak into other tools running in the same shell.

The launchd plist sets no defaults for any of these env vars — every `gws` call must supply them inline.

## Re-authentication

If auth is expired or invalid (exit code 2 on any `gws` command):

1. Check status:
   ```bash
   CLIENT_ID=$(~/.tron/skills/vault/scripts/vault.sh get google-workspace-client --field username)
   CLIENT_SECRET=$(~/.tron/skills/vault/scripts/vault.sh get google-workspace-client --field password)
   GOOGLE_WORKSPACE_CLI_CLIENT_ID="$CLIENT_ID" \
   GOOGLE_WORKSPACE_CLI_CLIENT_SECRET="$CLIENT_SECRET" \
   gws auth status
   ```
2. Run the interactive flow (requires a browser):
   ```bash
   GOOGLE_WORKSPACE_CLI_CLIENT_ID="$CLIENT_ID" \
   GOOGLE_WORKSPACE_CLI_CLIENT_SECRET="$CLIENT_SECRET" \
   gws auth login
   ```
3. Re-run the "Storing user credentials in the vault" command above to refresh the vault entry. The vault is **not** auto-synced with `gws`'s local state.

### Agent-driven reauth (using the browse-the-web skill)

The reauth flow can be fully automated end-to-end **if** the user is already signed into the right Google account in the agent-browser session — or willing to enter their password without 2FA blocking. Use the `browse-the-web` skill (CLI: `agent-browser`) to drive the OAuth consent flow.

How `gws auth login` works under the hood: it starts a local HTTP server on a random port (the OAuth `redirect_uri` for the Desktop OAuth client), prints a `https://accounts.google.com/o/oauth2/v2/auth?...` URL, opens it in the system browser, then waits for Google to redirect back to the local server with an auth code. We hijack the browser step.

```bash
# 0. Pull client credentials from vault
VAULT=~/.tron/skills/vault/scripts/vault.sh
CLIENT_ID=$($VAULT get google-workspace-client --field username)
CLIENT_SECRET=$($VAULT get google-workspace-client --field password)

# 1. Start gws auth login in the background, capturing stdout
LOGIN_LOG=$(mktemp) && trap 'rm -f "$LOGIN_LOG"' EXIT
GOOGLE_WORKSPACE_CLI_CLIENT_ID="$CLIENT_ID" \
GOOGLE_WORKSPACE_CLI_CLIENT_SECRET="$CLIENT_SECRET" \
gws auth login > "$LOGIN_LOG" 2>&1 &
LOGIN_PID=$!

# 2. Poll for the consent URL (gws prints it within a second or two)
for i in 1 2 3 4 5 6 7 8 9 10; do
  AUTH_URL=$(grep -o 'https://accounts.google.com/o/oauth2/v2/auth[^ ]*' "$LOGIN_LOG" | head -1)
  [ -n "$AUTH_URL" ] && break
  sleep 1
done
[ -z "$AUTH_URL" ] && { echo "no consent URL captured"; kill $LOGIN_PID; exit 1; }

# 3. Drive the consent flow with agent-browser (must be HEADED — Google blocks headless OAuth)
#    Start the Display stream first per the browse-the-web skill, then:
agent-browser open "$AUTH_URL" --headed --session gws-reauth
agent-browser snapshot -i --json --session gws-reauth
# Click through "Choose an account" → your account → "Continue" / "Allow"
# Use the snapshot @e refs to identify each button. Re-snapshot between clicks.
# In Testing mode you'll hit a "Google hasn't verified this app" warning:
#   click "Advanced" → "Go to <app> (unsafe)"

# 4. Wait for gws to finish (the local server captures the redirect automatically)
wait $LOGIN_PID || { cat "$LOGIN_LOG"; exit 1; }

# 5. Clean up the browser session
agent-browser close --session gws-reauth

# 6. Refresh the vault entry from gws's new local state
TMP=$(mktemp) && chmod 600 "$TMP"
gws auth export --unmasked > "$TMP"
~/.tron/skills/vault/scripts/vault.sh set google-workspace-cli \
  --type secret \
  --desc "Authorized-user JSON for the gws Google Workspace CLI" \
  --tags "google,gws,oauth" \
  --field-file value="$TMP"
rm -f "$TMP"
```

**Hard blockers** that drop you back to manual reauth:
- **2FA**: if Google challenges with TOTP, security key, or phone prompt, the agent cannot solve it. Stop and tell the user.
- **Cold sign-in**: if the agent-browser profile is not signed into Google, the agent has to enter email + password — and 2FA almost always fires on a fresh session. Same outcome.
- **Bot detection**: rare on a persistent profile but possible. If Google dead-ends on a "Couldn't sign you in" challenge, stop and tell the user.

In all blocker cases: kill the background `gws auth login` (`kill $LOGIN_PID`), close the browser session, and tell the user to run `gws auth login` manually in their own browser, then run only step 6 (the vault refresh) when they're done.

## Signing up for third-party services

When you need to sign up for a service using the Google account:

1. Use the browser automation tools to navigate to the sign-up page.
2. Look for "Sign in with Google" or "Continue with Google" options.
3. Authenticate with the Google account shown in `gws auth status`.
4. Complete any profile setup required.
5. Save the service credentials/API keys to the vault for future use.

## Scopes

The default `gws auth login` requests standard scopes for all services. For restricted scopes:

```bash
# Read-only access
gws auth login --readonly

# Full access including Pub/Sub and Cloud Platform
gws auth login --full

# Specific services only
gws auth login -s drive,gmail,sheets

# Custom scopes
gws auth login --scopes 'https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/drive'
```

After changing scopes, re-run the vault store command so the refreshed credentials are persisted.

## GCP project

The GCP project is set up via `gws auth setup`. To use a specific project:

```bash
gws auth setup --project my-project-id
```

Or set the project for API quota at runtime:

```bash
GOOGLE_WORKSPACE_PROJECT_ID=project-id gws ...
```

## Logout

```bash
gws auth logout
```

Clears `gws`'s local credentials and token cache. **This does not touch the vault entry.** To remove the vault copy as well:

```bash
~/.tron/skills/vault/scripts/vault.sh delete google-workspace-cli
```

## Gotchas

- Two vault entries, both required: `google-workspace-client` (OAuth app identity) and `google-workspace-cli` (user tokens). Missing either causes auth failures.
- The vault master key (`~/.tron/workspace/vault/.master-key`) is as sensitive as Google account access — leaking it leaks both client secrets and refresh tokens. If compromised: revoke at https://myaccount.google.com/permissions and re-do setup from scratch.
- After `gws auth login`, you **must** re-run the vault store command for user credentials. `gws` writes its local state, but the vault is not auto-synced — forgetting this leaves agent sessions using old tokens.
- Every `gws` call needs three inline env vars: `GOOGLE_WORKSPACE_CLI_CLIENT_ID`, `GOOGLE_WORKSPACE_CLI_CLIENT_SECRET`, and `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`. The launchd plist sets no defaults — omitting any of them causes auth errors.
- API enablement is per-project. A `PERMISSION_DENIED` from a service usually means that service's API isn't enabled yet — turn it on in the GCP console.
- Consent screen `Testing` mode tokens expire every 7 days. For long-running headless setups, publish the OAuth app (consent screen → "Publish app").
- Always materialize user credentials to a temp file (`mktemp`) for the duration of a single command and clean up via `trap`. Never write them to a known long-lived path.
- Use inline env var overrides rather than `export`, so secrets don't leak into other tools in the same shell session.
