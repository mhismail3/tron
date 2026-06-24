#!/bin/bash
# auth.sh - sourced by tron-lib.sh; do not execute directly.

base64url_encode() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

cmd_login() {
    local label=""
    local host_override=""
    local provider=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --label) label="$2"; shift 2 ;;
            --host) host_override="$2"; shift 2 ;;
            --provider) provider="$2"; shift 2 ;;
            --status) cmd_login_status; return ;;
            -h|--help)
                echo ""
                echo "Usage: tron login [--provider <name>] [--label <name>] [--host <hostname>] [--status]"
                echo ""
                echo "  --provider <name>    Provider: anthropic or openai (skips menu)"
                echo "  --label <name>       Account label (default: \$USER@hostname)"
                echo "  --host <hostname>    Override hostname portion of default label"
                echo "  --status             Show current auth status"
                echo ""
                echo "Each machine should have its own OAuth session to avoid token"
                echo "conflicts. The default label uses your hostname to ensure this."
                echo ""
                return ;;
            *) print_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Show existing accounts for all providers
    if [[ -f "$AUTH_FILE" ]]; then
        local now_ms=$(( $(date +%s) * 1000 ))
        _show_provider_accounts "anthropic" "Anthropic" "$now_ms"
        _show_provider_accounts "openai-codex" "OpenAI" "$now_ms"
    fi

    # Provider selection
    if [[ -z "$provider" ]]; then
        echo ""
        echo -e "${BOLD}Select provider:${NC}"
        echo "  1. Anthropic (Claude)"
        echo "  2. OpenAI (Codex)"
        echo ""
        printf "Choice [1]: "
        read -r choice
        case "${choice:-1}" in
            1|anthropic) provider="anthropic" ;;
            2|openai)    provider="openai" ;;
            *)
                print_error "Invalid choice: $choice"
                return 1 ;;
        esac
    fi

    case "$provider" in
        anthropic) cmd_login_anthropic "$label" "$host_override" ;;
        openai)    cmd_login_openai "$label" "$host_override" ;;
        *)
            print_error "Unknown provider: $provider (use 'anthropic' or 'openai')"
            return 1 ;;
    esac
}

_show_provider_accounts() {
    local provider_key="$1"
    local display_name="$2"
    local now_ms="$3"

    local account_count
    account_count=$(jq -r ".providers[\"${provider_key}\"].accounts // [] | length" "$AUTH_FILE" 2>/dev/null)
    if [[ "$account_count" -gt 0 ]]; then
        echo ""
        echo -e "${DIM}Existing ${display_name} accounts:${NC}"
        jq -r --argjson now "$now_ms" --arg pk "$provider_key" '
            .providers[$pk].accounts | to_entries[] |
            .value.label as $l |
            .value.oauth.expiresAt as $e |
            (.key + 1) as $i |
            if $e > $now then
                "  \($i). \($l)  (expires \($e / 1000 | strftime("%Y-%m-%d %H:%M")) \u2014 \u001b[32mvalid\u001b[0m)"
            else
                "  \($i). \($l)  (expires \($e / 1000 | strftime("%Y-%m-%d %H:%M")) \u2014 \u001b[31mEXPIRED\u001b[0m)"
            end
        ' "$AUTH_FILE" 2>/dev/null | while IFS= read -r line; do echo -e "$line"; done
        echo ""
    fi
}

_prompt_account_label() {
    local label="$1"
    local host_override="$2"

    if [[ -z "$label" ]]; then
        local hostname_short
        hostname_short="${host_override:-$(hostname -s 2>/dev/null || hostname | cut -d. -f1)}"
        local default_label="${USER:-default}@${hostname_short}"
        printf "Account label [${BOLD}%s${NC}]: " "$default_label" >&2
        read -r label
        label="${label:-$default_label}"
    fi

    echo "$label"
}

_save_oauth_tokens() {
    local provider_key="$1"
    local label="$2"
    local access_token="$3"
    local refresh_token="$4"
    local expires_at="$5"

    if [[ ! -f "$AUTH_FILE" ]]; then
        echo '{"version":1,"providers":{}}' > "$AUTH_FILE"
        chmod 600 "$AUTH_FILE"
    fi

    local tmp_file="${AUTH_FILE}.tmp"

    jq --arg pk "$provider_key" \
       --arg label "$label" \
       --arg at "$access_token" \
       --arg rt "$refresh_token" \
       --argjson ea "$expires_at" \
       '
       .providers[$pk].accounts //= [] |
       (.providers[$pk].accounts | map(.label) | index($label)) as $idx |
       if $idx != null then
           .providers[$pk].accounts[$idx].oauth = {accessToken: $at, refreshToken: $rt, expiresAt: $ea}
       else
           .providers[$pk].accounts += [{label: $label, oauth: {accessToken: $at, refreshToken: $rt, expiresAt: $ea}}]
       end |
       .lastUpdated = (now | todate)
       ' "$AUTH_FILE" > "$tmp_file" && mv "$tmp_file" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
}

cmd_login_anthropic() {
    local label="$1"
    local host_override="$2"

    label=$(_prompt_account_label "$label" "$host_override")

    # Generate PKCE
    local code_verifier
    code_verifier=$(openssl rand 32 | base64url_encode)
    local code_challenge
    code_challenge=$(printf '%s' "$code_verifier" | openssl dgst -sha256 -binary | base64url_encode)

    local encoded_redirect_uri encoded_scope
    encoded_redirect_uri=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${ANTHROPIC_OAUTH_REDIRECT_URI}''', safe=''))")
    encoded_scope=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${ANTHROPIC_OAUTH_SCOPES}''', safe=''))")
    local auth_url="${ANTHROPIC_OAUTH_AUTH_ENDPOINT}?code=true&client_id=${ANTHROPIC_OAUTH_CLIENT_ID}&response_type=code&redirect_uri=${encoded_redirect_uri}&scope=${encoded_scope}&code_challenge=${code_challenge}&code_challenge_method=S256&state=${code_verifier}"

    echo ""
    print_status "Opening browser for Anthropic authentication..."
    echo -e "  Account: ${BOLD}${label}${NC}"
    echo ""
    echo "If browser doesn't open, visit:"
    echo "$auth_url"
    echo ""

    open "$auth_url"

    echo "After signing in, copy the FULL URL from your browser's address bar."
    printf "Paste the redirect URL: "
    read -r auth_input
    echo ""

    if [[ -z "$auth_input" ]]; then
        print_error "No input provided"
        return 1
    fi

    local code=""
    local state=""

    if [[ "$auth_input" == http* ]]; then
        code=$(python3 -c "
import sys, urllib.parse
q = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
print(q.get('code',[''])[0])
" "$auth_input" 2>/dev/null)
        state=$(python3 -c "
import sys, urllib.parse
q = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
print(q.get('state',[''])[0])
" "$auth_input" 2>/dev/null)
    else
        code="$auth_input"
        state="$code_verifier"
    fi

    if [[ -z "$code" ]]; then
        print_error "Could not extract authorization code from input"
        return 1
    fi

    print_status "Exchanging authorization code..."

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "$ANTHROPIC_OAUTH_TOKEN_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "User-Agent: tron-agent/1.0" \
        -d "{
            \"grant_type\": \"authorization_code\",
            \"client_id\": \"${ANTHROPIC_OAUTH_CLIENT_ID}\",
            \"code\": \"${code}\",
            \"state\": \"${state}\",
            \"redirect_uri\": \"${ANTHROPIC_OAUTH_REDIRECT_URI}\",
            \"code_verifier\": \"${code_verifier}\"
        }")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        print_error "Token exchange failed (HTTP $http_code): $body"
        return 1
    fi

    local access_token refresh_token expires_in expires_at
    access_token=$(echo "$body" | jq -r '.access_token')
    refresh_token=$(echo "$body" | jq -r '.refresh_token')
    expires_in=$(echo "$body" | jq -r '.expires_in')
    expires_at=$(( $(date +%s) * 1000 + expires_in * 1000 ))

    _save_oauth_tokens "anthropic" "$label" "$access_token" "$refresh_token" "$expires_at"

    print_success "Saved Anthropic tokens for account \"${label}\""

    local hours_left=$(( expires_in / 3600 ))
    echo -e "  ${DIM}Token expires in ~${hours_left}h${NC}"
    echo ""
}

cmd_login_openai() {
    local label="$1"
    local host_override="$2"

    label=$(_prompt_account_label "$label" "$host_override")

    # Check if port is available
    if lsof -i ":${OPENAI_OAUTH_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
        print_error "Port ${OPENAI_OAUTH_PORT} is already in use. Cannot start OAuth callback server."
        echo -e "  ${DIM}Check what's using it: lsof -i :${OPENAI_OAUTH_PORT}${NC}"
        return 1
    fi

    # Generate PKCE (OpenAI requires code_challenge)
    local code_verifier
    code_verifier=$(openssl rand 32 | base64url_encode)
    local code_challenge
    code_challenge=$(printf '%s' "$code_verifier" | openssl dgst -sha256 -binary | base64url_encode)

    local encoded_redirect_uri encoded_scope
    encoded_redirect_uri=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${OPENAI_OAUTH_REDIRECT_URI}''', safe=''))")
    encoded_scope=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${OPENAI_OAUTH_SCOPES}''', safe=''))")
    local auth_url="${OPENAI_OAUTH_AUTH_ENDPOINT}?response_type=code&client_id=${OPENAI_OAUTH_CLIENT_ID}&redirect_uri=${encoded_redirect_uri}&scope=${encoded_scope}&code_challenge=${code_challenge}&code_challenge_method=S256&state=${code_verifier}"

    echo ""
    print_status "Opening browser for OpenAI authentication..."
    echo -e "  Account: ${BOLD}${label}${NC}"
    echo ""

    # Start local callback server in background
    local code_file
    code_file=$(mktemp)
    local error_file
    error_file=$(mktemp)

    python3 -c "
import http.server, urllib.parse, sys, signal

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path != '/auth/callback':
            self.send_response(404)
            self.end_headers()
            return

        if 'error' in params:
            desc = params.get('error_description', params['error'])[0]
            with open('${error_file}', 'w') as f:
                f.write(desc)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><body><h2>Authorization Failed</h2><p>You can close this tab.</p></body></html>')
            raise SystemExit(1)

        code = params.get('code', [''])[0]
        recv_state = params.get('state', [''])[0]

        with open('${code_file}', 'w') as f:
            f.write(code + '\n' + recv_state)

        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(b'<html><body><h2>Authorization Complete</h2><p>You can close this tab and return to the terminal.</p></body></html>')
        raise SystemExit(0)

    def log_message(self, format, *args):
        pass  # suppress request logging

server = http.server.HTTPServer(('127.0.0.1', ${OPENAI_OAUTH_PORT}), Handler)
server.timeout = 300  # 5 minute timeout
signal.signal(signal.SIGALRM, lambda *_: sys.exit(1))
signal.alarm(300)
try:
    server.handle_request()
except SystemExit:
    pass
" &
    local server_pid=$!

    # Give server a moment to start
    sleep 0.3

    if ! kill -0 "$server_pid" 2>/dev/null; then
        print_error "Failed to start OAuth callback server on port ${OPENAI_OAUTH_PORT}"
        rm -f "$code_file" "$error_file"
        return 1
    fi

    echo "If browser doesn't open, visit:"
    echo "$auth_url"
    echo ""
    echo -e "${DIM}Waiting for authorization (listening on port ${OPENAI_OAUTH_PORT})...${NC}"

    open "$auth_url"

    # Wait for the callback server to complete
    wait "$server_pid" 2>/dev/null

    # Check for errors
    if [[ -s "$error_file" ]]; then
        local err_msg
        err_msg=$(<"$error_file")
        print_error "Authorization failed: $err_msg"
        rm -f "$code_file" "$error_file"
        return 1
    fi

    if [[ ! -s "$code_file" ]]; then
        print_error "No authorization code received (timed out or server error)"
        rm -f "$code_file" "$error_file"
        return 1
    fi

    local code recv_state
    code=$(head -1 "$code_file")
    recv_state=$(tail -1 "$code_file")
    rm -f "$code_file" "$error_file"

    if [[ -z "$code" ]]; then
        print_error "Empty authorization code received"
        return 1
    fi

    # Validate state matches (CSRF protection — verifier was used as state)
    if [[ "$recv_state" != "$code_verifier" ]]; then
        print_error "State parameter mismatch (possible CSRF attack)"
        return 1
    fi

    print_status "Exchanging authorization code..."

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "$OPENAI_OAUTH_TOKEN_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "User-Agent: tron-agent/1.0" \
        -d "{
            \"grant_type\": \"authorization_code\",
            \"client_id\": \"${OPENAI_OAUTH_CLIENT_ID}\",
            \"code\": \"${code}\",
            \"redirect_uri\": \"${OPENAI_OAUTH_REDIRECT_URI}\",
            \"code_verifier\": \"${code_verifier}\"
        }")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        print_error "Token exchange failed (HTTP $http_code): $body"
        return 1
    fi

    local access_token refresh_token expires_in expires_at
    access_token=$(echo "$body" | jq -r '.access_token')
    refresh_token=$(echo "$body" | jq -r '.refresh_token // ""')
    expires_in=$(echo "$body" | jq -r '.expires_in')
    expires_at=$(( $(date +%s) * 1000 + expires_in * 1000 ))

    _save_oauth_tokens "openai-codex" "$label" "$access_token" "$refresh_token" "$expires_at"

    print_success "Saved OpenAI tokens for account \"${label}\""

    local hours_left=$(( expires_in / 3600 ))
    echo -e "  ${DIM}Token expires in ~${hours_left}h${NC}"
    echo ""
}

cmd_login_status() {
    if [[ ! -f "$AUTH_FILE" ]]; then
        echo ""
        print_warning "No auth file found"
        echo ""
        return
    fi

    local now_ms=$(( $(date +%s) * 1000 ))

    _show_provider_login_status "anthropic" "Anthropic" "$now_ms"
    _show_provider_login_status "openai-codex" "OpenAI" "$now_ms"

    echo ""
}

_show_provider_login_status() {
    local provider_key="$1"
    local display_name="$2"
    local now_ms="$3"

    echo ""
    print_status "${display_name} auth status:"
    echo ""

    # Show active credential
    local active_type active_label
    active_type=$(jq -r ".providers[\"${provider_key}\"].activeCredential.type // empty" "$AUTH_FILE" 2>/dev/null)
    active_label=$(jq -r ".providers[\"${provider_key}\"].activeCredential.label // empty" "$AUTH_FILE" 2>/dev/null)

    # OAuth accounts
    local account_count
    account_count=$(jq -r ".providers[\"${provider_key}\"].accounts // [] | length" "$AUTH_FILE" 2>/dev/null)
    if [[ "$account_count" -gt 0 ]]; then
        echo -e "  ${DIM}OAuth accounts:${NC}"
        jq -r --argjson now "$now_ms" --arg pk "$provider_key" --arg active_label "$active_label" --arg active_type "$active_type" '
            .providers[$pk].accounts[] |
            .label as $l |
            .oauth.expiresAt as $e |
            .oauth.accessToken[0:20] as $t |
            (if $active_type == "oauth" and $active_label == $l then " *" else "  " end) as $marker |
            if $e > $now then
                "\($marker) \($l): \u001b[32mvalid\u001b[0m (~\(($e - $now) / 3600000 | floor)h)  \($t)..."
            else
                "\($marker) \($l): \u001b[31mexpired\u001b[0m  \($t)..."
            end
        ' "$AUTH_FILE" 2>/dev/null | while IFS= read -r line; do echo -e "$line"; done
    fi

    # Named API keys
    local key_count
    key_count=$(jq -r ".providers[\"${provider_key}\"].apiKeys // [] | length" "$AUTH_FILE" 2>/dev/null)
    if [[ "$key_count" -gt 0 ]]; then
        echo -e "  ${DIM}API keys:${NC}"
        jq -r --arg pk "$provider_key" --arg active_label "$active_label" --arg active_type "$active_type" '
            .providers[$pk].apiKeys[] |
            .label as $l |
            .key[0:12] as $hint |
            (if $active_type == "apiKey" and $active_label == $l then " *" else "  " end) as $marker |
            "\($marker) \($l): \($hint)..."
        ' "$AUTH_FILE" 2>/dev/null | while IFS= read -r line; do echo -e "$line"; done
    fi

    if [[ "$account_count" -eq 0 ]] && [[ "$key_count" -eq 0 ]]; then
        echo -e "  ${DIM}(not configured)${NC}"
    fi
}

cmd_auth() {
    local action="${1:-}"
    case "$action" in
        rotate)
            shift
            cmd_auth_rotate "$@"
            ;;
        ""|-h|--help)
            echo ""
            echo "Usage: tron auth <action>"
            echo ""
            echo "Actions:"
            echo "  rotate    Generate a fresh WebSocket bearer token (forces iOS re-pair)"
            echo ""
            echo "After rotation every paired iOS device shows the .unauthorized state"
            echo "and must re-pair using the new token. The token lives in"
            echo "  $AUTH_FILE (bearerToken)"
            echo "with mode 0o600."
            echo ""
            return 0
            ;;
        *)
            print_error "Unknown auth action: $action"
            cmd_auth --help
            return 1
            ;;
    esac
}

cmd_auth_rotate() {
    # Pick the freshest contributor binary in priority order: installed
    # service bundle > dev-server build > workspace `cargo run`. This mirrors how
    # cmd_status / cmd_rollback select binaries — keeping a single
    # source of truth means the rotated token always lands at the path
    # the running daemon will actually consult.
    local binary=""
    if [[ -x "$INSTALLED_BINARY" ]]; then
        binary="$INSTALLED_BINARY"
    elif [[ -x "$DEV_BINARY" ]]; then
        binary="$DEV_BINARY"
    elif [[ -x "$RELEASE_BINARY" ]]; then
        binary="$RELEASE_BINARY"
    elif [[ -x "$DEV_SERVER_BINARY" ]]; then
        binary="$DEV_SERVER_BINARY"
    fi

    if [[ -n "$binary" ]]; then
        "$binary" auth rotate "$@"
    else
        # Workspace source path — dev tree, no built binary on disk yet.
        if ! command -v cargo >/dev/null 2>&1; then
            print_error "No tron binary found and cargo is unavailable. Build with 'cargo build' first."
            return 1
        fi
        ( cd "$RUST_WORKSPACE" && cargo run --quiet --bin tron -- auth rotate "$@" )
    fi
}
