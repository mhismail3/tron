#!/bin/bash
# auth.sh - sourced by tron-lib.sh; do not execute directly.

_auth_storage_is_initialized() {
    [[ -f "$AUTH_FILE" ]] && jq -e '
        type == "object" and
        .version == 1 and
        (.providers | type == "object") and
        (.lastUpdated | type == "string") and
        (.bearerToken | type == "string" and length > 0)
    ' "$AUTH_FILE" >/dev/null 2>&1
}

_run_tron_auth_owner() {
    local action="$1"
    shift
    if [[ ( "$action" == "begin-oauth" || "$action" == "complete-oauth" ) \
        && -f "${RUST_WORKSPACE:-}/Cargo.toml" ]] \
        && command -v cargo >/dev/null 2>&1; then
        ( cd "$RUST_WORKSPACE" && cargo run --quiet --bin tron -- auth "$action" "$@" )
        return
    fi

    if [[ -z "${RUST_WORKSPACE:-}" ]]; then
        if [[ ! -x "$INSTALLED_BINARY" ]]; then
            print_error "The installed Tron CLI has no paired helper binary. Run 'tron install' from the workspace."
            return 1
        fi
        "$INSTALLED_BINARY" auth "$action" "$@"
        return
    fi

    local binary=""
    if [[ -x "${RELEASE_BINARY:-}" ]]; then
        binary="$RELEASE_BINARY"
    elif [[ -x "${DEV_SERVER_BINARY:-}" ]]; then
        binary="$DEV_SERVER_BINARY"
    fi
    if [[ -z "$binary" ]]; then
        print_error "No matching workspace Tron binary is available. Build with 'cargo build' first."
        return 1
    fi
    "$binary" auth "$action" "$@"
}

_run_with_contributor_pair_read() {
    if [ -n "${RUST_WORKSPACE:-}" ]; then
        "$@"
        return
    fi

    begin_contributor_pair_read || return 1
    local status=0
    "$@" || status=$?
    end_contributor_pair_read || return 1
    return "$status"
}

cmd_login() {
    _run_with_contributor_pair_read _cmd_login "$@"
}

_cmd_login() {
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

    if ! _auth_storage_is_initialized; then
        print_error "Auth storage is not initialized. Start the Tron server once, then retry login."
        return 1
    fi

    # Show existing accounts for all providers
    local now_ms=$(( $(date +%s) * 1000 ))
    _show_provider_accounts "anthropic" "Anthropic" "$now_ms"
    _show_provider_accounts "openai-codex" "OpenAI" "$now_ms"

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

_complete_oauth_login() {
    local provider_key="$1"
    local label="$2"
    local code="$3"
    local verifier="$4"
    local expected_state="$5"
    local completion_kind="$6"
    local returned_state="$7"

    if ! printf '%s\0' \
        "$provider_key" \
        "$label" \
        "$code" \
        "$verifier" \
        "$expected_state" \
        "$completion_kind" \
        "$returned_state" \
        | _run_tron_auth_owner complete-oauth; then
        print_error "Could not complete OAuth through the Rust auth owner."
        return 1
    fi
}

cmd_login_anthropic() {
    local label="$1"
    local host_override="$2"

    label=$(_prompt_account_label "$label" "$host_override")

    local flow_output code_verifier expected_state auth_url redirect_uri
    if ! flow_output=$(_run_tron_auth_owner begin-oauth anthropic); then
        print_error "Could not prepare Anthropic OAuth through the Rust auth owner."
        return 1
    fi
    IFS=$'\t' read -r code_verifier expected_state auth_url redirect_uri <<< "$flow_output"
    if [[ -z "$code_verifier" || -z "$expected_state" || -z "$auth_url" || -z "$redirect_uri" ]]; then
        print_error "Rust auth owner returned an invalid Anthropic OAuth flow."
        return 1
    fi

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
    local completion_kind="manual"

    if [[ "$auth_input" == http* ]]; then
        completion_kind="callback"
        local parsed_input
        parsed_input=$(printf '%s' "$auth_input" | python3 -c '
import sys, urllib.parse
query = urllib.parse.parse_qs(urllib.parse.urlparse(sys.stdin.read()).query)
print(query.get("code", [""])[0] + "\t" + query.get("state", [""])[0], end="")
' 2>/dev/null)
        IFS=$'\t' read -r code state <<< "$parsed_input"
    else
        code="$auth_input"
    fi

    if [[ -z "$code" ]]; then
        print_error "Could not extract authorization code from input"
        return 1
    fi

    print_status "Exchanging authorization code..."

    local expires_at
    expires_at=$(_complete_oauth_login \
        "anthropic" "$label" "$code" "$code_verifier" "$expected_state" \
        "$completion_kind" "$state") || return 1

    print_success "Saved Anthropic tokens for account \"${label}\""

    local now_ms=$(( $(date +%s) * 1000 ))
    local hours_left=$(( (expires_at - now_ms) / 3600000 ))
    if (( hours_left < 0 )); then
        hours_left=0
    fi
    echo -e "  ${DIM}Token expires in ~${hours_left}h${NC}"
    echo ""
}

cmd_login_openai() {
    local label="$1"
    local host_override="$2"

    label=$(_prompt_account_label "$label" "$host_override")

    local flow_output code_verifier expected_state auth_url redirect_uri
    if ! flow_output=$(_run_tron_auth_owner begin-oauth openai-codex); then
        print_error "Could not prepare OpenAI OAuth through the Rust auth owner."
        return 1
    fi
    IFS=$'\t' read -r code_verifier expected_state auth_url redirect_uri <<< "$flow_output"
    if [[ -z "$code_verifier" || -z "$expected_state" || -z "$auth_url" || -z "$redirect_uri" ]]; then
        print_error "Rust auth owner returned an invalid OpenAI OAuth flow."
        return 1
    fi

    local callback_authority="${redirect_uri#*://}"
    local callback_port_path="${callback_authority#*:}"
    local callback_port="${callback_port_path%%/*}"
    local callback_path="/${callback_port_path#*/}"
    if [[ ! "$callback_port" =~ ^[0-9]+$ || "$callback_path" == "/$callback_port_path" ]]; then
        print_error "Rust auth owner returned an invalid OpenAI callback URI."
        return 1
    fi

    # Check if port is available
    if lsof -i ":${callback_port}" -sTCP:LISTEN >/dev/null 2>&1; then
        print_error "Port ${callback_port} is already in use. Cannot start OAuth callback server."
        echo -e "  ${DIM}Check what's using it: lsof -i :${callback_port}${NC}"
        return 1
    fi

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

        if parsed.path != '${callback_path}':
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

server = http.server.HTTPServer(('127.0.0.1', ${callback_port}), Handler)
server.timeout = 300  # 5 minute timeout
signal.signal(signal.SIGALRM, lambda *_: sys.exit(1))
signal.alarm(300)
try:
    server.handle_request()
except SystemExit:
    pass
" 8>&- 9>&- &
    local server_pid=$!

    # Give server a moment to start
    sleep 0.3

    if ! kill -0 "$server_pid" 2>/dev/null; then
        print_error "Failed to start OAuth callback server on port ${callback_port}"
        rm -f "$code_file" "$error_file"
        return 1
    fi

    echo "If browser doesn't open, visit:"
    echo "$auth_url"
    echo ""
    echo -e "${DIM}Waiting for authorization (listening on port ${callback_port})...${NC}"

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

    print_status "Exchanging authorization code..."

    local expires_at
    expires_at=$(_complete_oauth_login \
        "openai-codex" "$label" "$code" "$code_verifier" "$expected_state" \
        "callback" "$recv_state") || return 1

    print_success "Saved OpenAI tokens for account \"${label}\""

    local now_ms=$(( $(date +%s) * 1000 ))
    local hours_left=$(( (expires_at - now_ms) / 3600000 ))
    if (( hours_left < 0 )); then
        hours_left=0
    fi
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
            # The Rust owner serializes rotation with every other auth writer.
            _run_with_contributor_pair_read _run_tron_auth_owner rotate "$@"
            ;;
        apns)
            shift
            _run_with_contributor_pair_read _run_tron_auth_owner apns "$@"
            ;;
        notifications)
            shift
            _run_with_contributor_pair_read _run_tron_auth_owner notifications "$@"
            ;;
        ""|-h|--help)
            echo ""
            echo "Usage: tron auth <action>"
            echo ""
            echo "Actions:"
            echo "  rotate    Generate a fresh WebSocket bearer token (forces iOS re-pair)"
            echo "  apns      Configure direct APNs delivery credentials"
            echo "  notifications Configure relay/direct native-notification transport"
            echo ""
            echo "APNs:"
            echo "  tron auth apns configure --team-id ID --key-id ID --private-key-file AuthKey.p8"
            echo "  tron auth apns status"
            echo "  tron auth apns clear"
            echo ""
            echo "Notifications:"
            echo "  tron auth notifications configure-relay --url URL --secret-file FILE"
            echo "  tron auth notifications use relay|direct"
            echo "  tron auth notifications status"
            echo "  tron auth notifications clear-relay"
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
