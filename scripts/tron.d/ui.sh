#!/bin/bash

# Native UI developer publication commands. These talk to the running server's
# public engine transport and therefore exercise the same capability contracts,
# authority, validation, idempotency, audit, and serialization as iOS.

ui_require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        print_error "tron ui requires '$1'"
        return 1
    }
}

ui_invoke() {
    local function_id="$1"
    local payload="$2"
    local idempotency_key="${3:-}"
    local token request response request_id hello hello_id hello_response frames

    ui_require_tool jq
    ui_require_tool perl
    ui_require_tool websocat
    [ -f "$AUTH_FILE" ] || {
        print_error "Tron bearer token is unavailable at $AUTH_FILE"
        return 1
    }
    token="$(jq -er '.bearerToken | select(type == "string" and length > 0)' "$AUTH_FILE")" || {
        print_error "Tron bearer token is missing from $AUTH_FILE"
        return 1
    }
    request_id="tron-ui-$$-$RANDOM"
    hello_id="tron-ui-hello-$$-$RANDOM"
    request="$(jq -cn \
        --arg id "$request_id" \
        --arg functionId "$function_id" \
        --arg idempotencyKey "$idempotency_key" \
        --argjson payload "$payload" \
        '{type:"invoke", id:$id, functionId:$functionId, payload:$payload}
         + (if $idempotencyKey == "" then {} else {idempotencyKey:$idempotencyKey} end)')"

    hello="$(jq -cn --arg id "$hello_id" \
        '{type:"hello",id:$id,protocolVersion:1}')"
    # A fresh developer-command connection has no subscriptions, so the only
    # inbound text frames are the hello and invocation responses. The message
    # cap makes websocat exit after both; Perl's inherited alarm fails closed
    # if a peer accepts the socket but never completes either exchange.
    frames="$({
        printf '%s\n' "$hello"
        printf '%s\n' "$request"
    } | perl -e 'alarm shift; exec @ARGV' 70 \
        websocat -t -B 1048576 --max-messages-rev 2 --no-close \
        -H="Authorization: Bearer $token" \
        "${TRON_UI_ENGINE_URL:-ws://127.0.0.1:$PROD_PORT/engine}")" || {
        print_error "The running Tron server did not complete the engine handshake"
        return 1
    }
    hello_response="$(jq -sce --arg id "$hello_id" \
        '[.[] | select(.id == $id)][0]' <<<"$frames")" || {
        print_error "The running Tron server did not return a correlated engine handshake"
        return 1
    }
    if ! jq -e '.type == "hello.ok" and .protocolVersion == 1' >/dev/null <<<"$hello_response"; then
        jq '.error // .' <<<"$hello_response" >&2
        return 1
    fi
    response="$(jq -sce --arg id "$request_id" \
        '[.[] | select(.id == $id)][0]' <<<"$frames")" || {
        print_error "Could not invoke $function_id on the running Tron server"
        return 1
    }

    if ! jq -e --arg id "$request_id" \
        '.id == $id and .type == "response" and .ok == true and .result.child.error == null' \
        >/dev/null <<<"$response"; then
        jq '.result.child.error // .error // .' <<<"$response" >&2
        return 1
    fi
    jq '.result.child.value' <<<"$response"
}

ui_definition_payload() {
    local file="$1"
    [ -f "$file" ] || {
        print_error "Definition file not found: $file"
        return 1
    }
    jq -ce '{definition:.}' "$file"
}

ui_expected_active_revision() {
    local definition_id="$1"
    local history
    history="$(ui_invoke "native_ui::list_revisions" "$(jq -cn --arg id "$definition_id" '{definitionId:$id,limit:100}')")" || return 1
    jq -c '[.revisions[] | select(.status == "active") | .revision] | max // null' <<<"$history"
}

cmd_ui() {
    local action="${1:-help}"
    shift || true
    case "$action" in
        validate)
            [ "$#" -eq 1 ] || { print_error "Usage: tron ui validate <file>"; return 2; }
            ui_invoke "native_ui::validate_definition" "$(ui_definition_payload "$1")"
            ;;
        preview)
            [ "$#" -eq 1 ] || { print_error "Usage: tron ui preview <file>"; return 2; }
            ui_invoke "native_ui::create_preview" "$(ui_definition_payload "$1")" "ui-preview-$(date +%s)-$$-$RANDOM"
            ;;
        activate)
            [ "$#" -eq 1 ] || { print_error "Usage: tron ui activate <file>"; return 2; }
            local definition_id expected definition
            definition="$(jq -c . "$1")" || return 1
            definition_id="$(jq -er '.definitionId' <<<"$definition")" || return 1
            expected="$(ui_expected_active_revision "$definition_id")" || return 1
            ui_invoke "native_ui::activate_definition" \
                "$(jq -cn --argjson definition "$definition" --argjson expected "$expected" \
                    '{definition:$definition,expectedActiveRevision:$expected}')" \
                "ui-activate-$(date +%s)-$$-$RANDOM"
            ;;
        history)
            [ "$#" -eq 1 ] || { print_error "Usage: tron ui history <definition-id>"; return 2; }
            ui_invoke "native_ui::list_revisions" "$(jq -cn --arg id "$1" '{definitionId:$id,limit:100}')"
            ;;
        rollback)
            [ "$#" -eq 2 ] || { print_error "Usage: tron ui rollback <definition-id> <revision>"; return 2; }
            local expected
            expected="$(ui_expected_active_revision "$1")" || return 1
            ui_invoke "native_ui::rollback_definition" \
                "$(jq -cn --arg id "$1" --argjson revision "$2" --argjson expected "$expected" \
                    '{definitionId:$id,targetRevision:$revision,expectedActiveRevision:$expected}')" \
                "ui-rollback-$(date +%s)-$$-$RANDOM"
            ;;
        help|-h|--help)
            echo "Usage: tron ui <validate|preview|activate|history|rollback> ..."
            echo "  validate <file>"
            echo "  preview <file>"
            echo "  activate <file>"
            echo "  history <definition-id>"
            echo "  rollback <definition-id> <revision>"
            ;;
        *)
            print_error "Unknown tron ui action: $action"
            return 2
            ;;
    esac
}
