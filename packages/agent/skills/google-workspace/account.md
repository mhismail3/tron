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

5. **Create OAuth credentials** at https://console.cloud.google.com/apis/credentials → "Create Credentials" → "OAuth client ID" → application type **Desktop app**. Note the client ID and client secret (or download the `client_secret.json`).

6. **Tell `gws` about it:**
   ```bash
   gws auth setup --project <PROJECT_ID>
   ```
   It will prompt for the client id/secret, or accept a path to the downloaded `client_secret.json`.

7. **Run the interactive login:**
   ```bash
   gws auth login
   ```
   This opens a browser, completes OAuth, and persists tokens to `gws`'s own state dir. Use scope flags if you want narrower access (see "Scopes" below).

8. **Verify:**
   ```bash
   gws auth status
   ```
   Should show your account and `Token valid: yes`.

9. **Store the credentials in the vault** — see "Storing credentials in the vault" below.

## Auth status

```bash
gws auth status
```

Shows the current authentication state: logged-in account, token expiry, enabled scopes.

## Storing credentials in the vault

The credentials live in the Tron vault as a single encrypted entry named `google-workspace-cli`. The vault is the canonical store — there is no long-lived plaintext file on disk.

To store (or refresh) the entry:

```bash
TMP=$(mktemp) && trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
gws auth export --unmasked > "$TMP"
~/.tron/skills/vault/scripts/vault.sh set google-workspace-cli \
  --type secret \
  --desc "Authorized-user JSON for the gws Google Workspace CLI" \
  --tags "google,gws,oauth" \
  --field-file value="$TMP"
```

Why the temp file: `vault.sh set --field-file` accepts file paths only, and writing through `mktemp` keeps the secret off the process arg list and out of shell history. The `trap` ensures cleanup even on error.

To inspect the metadata (no secret values shown):

```bash
~/.tron/skills/vault/scripts/vault.sh list | grep -A2 google-workspace-cli
```

## Using the credentials with gws (per-call materialization)

The `gws` CLI reads its credentials from the file path in `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`. **Do not** keep a long-lived plaintext copy on disk. Materialize a temp file just for the duration of the command:

```bash
# Pattern for a single gws call
TMP=$(mktemp) && trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"
~/.tron/skills/vault/scripts/vault.sh get google-workspace-cli --field value > "$TMP"
GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="$TMP" gws gmail +triage --max 10
```

For a sequence of calls, materialize once at the top of your script and clean up at the end via `trap`. Always:

- `chmod 600` the temp file before writing to it.
- Use `mktemp` (never a hardcoded path).
- Set `trap 'rm -f "$TMP"' EXIT` so the file is removed even on failure.
- Override `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` per-command (inline, not via `export`) so it doesn't leak into other tools running in the same shell.

The launchd plist sets no default for `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` — every `gws` call must supply the path inline.

## Re-authentication

If auth is expired or invalid (exit code 2 on any `gws` command):

1. Check status: `gws auth status`
2. Run the interactive flow (requires a browser): `gws auth login`
3. Re-run the "Storing credentials in the vault" command above to refresh the vault entry. The vault is **not** auto-synced with `gws`'s local state.

### Agent-driven reauth (using the browse-the-web skill)

The reauth flow can be fully automated end-to-end **if** the user is already signed into the right Google account in the agent-browser session — or willing to enter their password without 2FA blocking. Use the `browse-the-web` skill (CLI: `agent-browser`) to drive the OAuth consent flow.

How `gws auth login` works under the hood: it starts a local HTTP server on a random port (the OAuth `redirect_uri` for the Desktop OAuth client), prints a `https://accounts.google.com/o/oauth2/v2/auth?...` URL, opens it in the system browser, then waits for Google to redirect back to the local server with an auth code. We hijack the browser step.

```bash
# 1. Start gws auth login in the background, capturing stdout
LOGIN_LOG=$(mktemp) && trap 'rm -f "$LOGIN_LOG"' EXIT
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

- The vault entry stores a long-lived `refresh_token`. Treat the vault master key (`~/.tron/workspace/vault/.master-key`) as equally sensitive — leaking it leaks Google account access. If compromised: revoke at https://myaccount.google.com/permissions and re-do `gws auth login` + the vault store command.
- After `gws auth login`, you **must** re-run the vault store command. `gws` writes its local state, but the vault is not auto-synced — forgetting this leaves agent sessions using the old creds.
- API enablement is per-project. A `PERMISSION_DENIED` from a service usually means that service's API isn't enabled yet — turn it on in the GCP console.
- Consent screen `Testing` mode tokens expire every 7 days. For long-running headless setups, publish the OAuth app (consent screen → "Publish app").
- Always materialize the credentials to a temp file (`mktemp`) for the duration of a single command and clean up via `trap`. Never write them to a known long-lived path.
- The launchd plist sets no default for `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` — every call must supply the path inline.
- Use inline env var overrides (`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=... gws ...`) rather than `export`, so the path doesn't leak into other tools in the same shell session.
