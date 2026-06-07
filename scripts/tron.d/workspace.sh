#!/bin/bash
# workspace.sh - sourced by tron; do not execute directly.

require_project_dir() {
    if [ ! -f "$RUST_WORKSPACE/Cargo.toml" ]; then
        print_error "Not in project directory: $PROJECT_DIR"
        exit 1
    fi
}

ensure_prod_binary() {
    if validate_prod_binary; then
        return 0
    fi

    print_warning "Contributor service binary is missing or corrupt"

    if [ -f "$CONTRIBUTOR_DIR/tron.bak" ] \
        && file "$CONTRIBUTOR_DIR/tron.bak" 2>/dev/null | grep -q "Mach-O"; then
        print_status "Restoring from backup..."
        if ! create_app_bundle "$INSTALLED_BUNDLE" "$CONTRIBUTOR_DIR/tron.bak"; then
            return 1
        fi
        codesign_bundle "$INSTALLED_BUNDLE"
        print_success "Restored from backup"
        return 0
    fi

    if [ -f "$RELEASE_BINARY" ] \
        && file "$RELEASE_BINARY" 2>/dev/null | grep -q "Mach-O"; then
        print_status "Restoring from release build..."
        create_app_bundle "$INSTALLED_BUNDLE" "$RELEASE_BINARY"
        codesign_bundle "$INSTALLED_BUNDLE"
        print_success "Restored from release build"
        return 0
    fi

    print_error "No valid contributor service binary found. Run: tron deploy"
    return 1
}

build_rust() {
    print_status "Building Rust workspace (release)..."
    (cd "$RUST_WORKSPACE" && cargo build --release) || { print_error "Build failed"; exit 1; }
    print_success "Build complete"
}

build_rust_dev() {
    print_status "Building Rust workspace (dev-server)..."
    prepare_dev_relay_env
    (cd "$RUST_WORKSPACE" && cargo build --profile dev-server) || { print_error "Build failed"; exit 1; }
    print_success "Build complete"
}

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

strip_optional_quotes() {
    local value="$1"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

set_env_if_unset() {
    local key="$1"
    local value="$2"
    if [ -z "${!key+x}" ]; then
        export "$key=$value"
    fi
}

load_dev_relay_env() {
    [ -f "$MAC_APP_LOCAL_ENV_FILE" ] || return 0

    local line key value loaded=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim_value "$line")"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        if [[ "$line" =~ ^(export[[:space:]]+)?(TRON_RELAY_URL|TRON_RELAY_SECRET|TRON_RELAY_ENVIRONMENT)=(.*)$ ]]; then
            key="${BASH_REMATCH[2]}"
            value="$(strip_optional_quotes "$(trim_value "${BASH_REMATCH[3]}")")"
            set_env_if_unset "$key" "$value"
            loaded=1
        elif [[ "$line" == TRON_RELAY_* || "$line" == export[[:space:]]TRON_RELAY_* ]]; then
            print_error "Malformed relay env line in $MAC_APP_LOCAL_ENV_FILE: $line"
            exit 64
        fi
    done < "$MAC_APP_LOCAL_ENV_FILE"

    if [ "$loaded" -eq 1 ]; then
        print_status "Loaded local relay env from $MAC_APP_LOCAL_ENV_FILE"
    fi
}

prepare_dev_relay_env() {
    load_dev_relay_env

    local has_url=0
    local has_secret=0
    [ -n "${TRON_RELAY_URL:-}" ] && has_url=1
    [ -n "${TRON_RELAY_SECRET:-}" ] && has_secret=1

    if [ "$has_url" -ne "$has_secret" ]; then
        print_error "TRON_RELAY_URL and TRON_RELAY_SECRET must be set together"
        echo "hint: add both to packages/mac-app/.env.local or unset both for a push-disabled dev server"
        exit 64
    fi

    if [ "$has_url" -eq 1 ]; then
        export TRON_RELAY_ENVIRONMENT="${TRON_RELAY_ENVIRONMENT:-production}"
        print_status "Relay config available for dev server (secret hidden)"
    fi
}
