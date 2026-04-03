# Account management

## Auth status

```bash
gws auth status
```

Shows current authentication state: logged-in account, token expiry, enabled scopes.

## Re-authentication

If auth is expired or invalid (exit code 2 on any `gws` command):

1. Check status: `gws auth status`
2. If token refresh failed, tell the user to run `gws auth login` — this requires an interactive browser flow.
3. After re-login, export credentials for headless use:
   ```bash
   gws auth export --unmasked > ~/.tron/system/mods/google/credentials.json
   ```

## Credential file

Location: `~/.tron/system/mods/google/credentials.json`

Set via environment variable for headless/cron use:
```
GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=~/.tron/system/mods/google/credentials.json
```

## Signing up for third-party services

When you need to sign up for a service using the Google account:

1. Use the browser automation tools to navigate to the sign-up page.
2. Look for "Sign in with Google" or "Continue with Google" options.
3. Authenticate with the Google account shown in `gws auth status`.
4. Complete any profile setup required.
5. Save the service credentials/API keys to memory for future use.

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

## GCP project

The GCP project is set up via `gws auth setup`. To use a specific project:
```bash
gws auth setup --project my-project-id
```

Or set the project for API quota:
```
GOOGLE_WORKSPACE_PROJECT_ID=project-id
```

## Logout

```bash
gws auth logout
```

Clears saved credentials and token cache.
