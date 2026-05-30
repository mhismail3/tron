#!/bin/bash
# logs.sh - sourced by tron-lib.sh; do not execute directly.

query_logs() {
    local level=""
    local output=""
    local format="text"
    local limit=50
    local session=""
    local search=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--level)   level="$2"; shift 2 ;;
            -o|--output)  output="$2"; shift 2 ;;
            -n|--limit)   limit="$2"; shift 2 ;;
            --tail)        limit="$2"; shift 2 ;;
            --json)        format="json"; shift ;;
            -s|--session) session="$2"; shift 2 ;;
            -q|--search)  search="$2"; shift 2 ;;
            -h|--help)
                echo ""
                echo -e "${CYAN}tron logs${NC} - Query database logs"
                echo ""
                echo "Usage: tron logs [options]"
                echo ""
                echo "Options:"
                echo "  -l, --level LEVEL    Filter by level (trace/debug/info/warn/error)"
                echo "  -n, --limit N        Number of logs to show (default: 50)"
                echo "  --tail N             Alias for --limit N"
                echo "  --json               Emit newline-delimited JSON rows"
                echo "  -o, --output FILE    Write output to file"
                echo "  -s, --session ID     Filter by session ID"
                echo "  -q, --search TEXT    Search log messages"
                echo ""
                return 0
                ;;
            *) shift ;;
        esac
    done

    # Database mode
    if [ ! -f "$DB_PATH" ]; then
        print_error "Database not found: $DB_PATH"
        echo "The server may not have been started yet."
        return 1
    fi

    local table_exists
    table_exists=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='logs';" 2>/dev/null)
    if [ -z "$table_exists" ]; then
        print_error "Logs table not found in database"
        return 1
    fi

    # Build SQL query
    local conditions=()

    if [ -n "$level" ]; then
        local level_num
        case "$level" in
            trace) level_num=10 ;;
            debug) level_num=20 ;;
            info)  level_num=30 ;;
            warn)  level_num=40 ;;
            error) level_num=50 ;;
            *)
                print_error "Invalid level: $level (valid: trace/debug/info/warn/error)"
                return 1
                ;;
        esac
        conditions+=("level_num >= $level_num")
    fi

    [ -n "$session" ] && conditions+=("session_id LIKE '%$session%'")
    if ! [[ "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -lt 1 ]; then
        print_error "Invalid limit: $limit"
        return 1
    fi

    local where_clause=""
    if [ ${#conditions[@]} -gt 0 ]; then
        where_clause="WHERE $(IFS=' AND '; echo "${conditions[*]}")"
    fi

    local sql
    local select_clause="timestamp, level, component, message, session_id, error_message"
    if [ "$format" = "json" ]; then
        select_clause="json_object('timestamp', timestamp, 'level', level, 'component', component, 'message', message, 'sessionId', session_id, 'workspaceId', workspace_id, 'traceId', trace_id, 'origin', origin, 'errorMessage', error_message)"
    fi

    if [ -n "$search" ]; then
        local escaped_search="${search//\'/\'\'}"
        local search_cond="(message LIKE '%${escaped_search}%' OR component LIKE '%${escaped_search}%' OR error_message LIKE '%${escaped_search}%')"
        sql="SELECT $select_clause
             FROM logs
             WHERE ${search_cond}
             ${where_clause:+AND ${where_clause#WHERE }}
             ORDER BY timestamp DESC
             LIMIT $limit"
    else
        sql="SELECT $select_clause
             FROM logs
             $where_clause
             ORDER BY timestamp DESC
             LIMIT $limit"
    fi

    local result
    result=$(sqlite3 -separator '|' "$DB_PATH" "$sql" 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Database query failed: $result"
        return 1
    fi

    if [ -z "$result" ]; then
        echo -e "${DIM}No logs found matching criteria${NC}"
        return 0
    fi

    if [ "$format" = "json" ]; then
        if [ -n "$output" ]; then
            echo "$result" > "$output"
            print_success "Wrote $(wc -l < "$output" | tr -d ' ') logs to $output"
        else
            echo "$result"
        fi
        return 0
    fi

    if [ -n "$output" ]; then
        echo "$result" | while IFS='|' read -r ts lvl comp msg sess err; do
            local line="${ts} ${lvl} [${comp}] ${msg}"
            [ -n "$sess" ] && line="$line (${sess})"
            [ -n "$err" ] && line="$line | Error: $err"
            echo "$line"
        done > "$output"
        print_success "Wrote $(wc -l < "$output" | tr -d ' ') logs to $output"
    else
        echo -e "${CYAN}Database Logs${NC}"
        echo -e "${DIM}Database: $DB_PATH${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$result" | while IFS='|' read -r ts lvl comp msg sess err; do
            local color=""
            case "$lvl" in
                TRACE|DEBUG|trace|debug) color="$DIM" ;;
                INFO|info)  color="$GREEN" ;;
                WARN|warn)  color="$YELLOW" ;;
                ERROR|error) color="$RED" ;;
            esac

            local time_part="${ts:11:8}"
            local line="${time_part} ${color}${lvl}${NC} [${comp}] ${msg}"
            [ -n "$sess" ] && line="$line ${DIM}(${sess:0:12}...)${NC}"
            [ -n "$err" ] && line="$line\n  ${RED}Error: $err${NC}"

            echo -e "$line"
        done
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        local count=$(echo "$result" | wc -l | tr -d ' ')
        echo -e "${DIM}Showing $count logs (limit: $limit)${NC}"
    fi
}

write_deployment_result() {
    local status="$1"
    local error_msg="${2:-null}"
    local commit
    local previous_commit

    commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    previous_commit=$(cat "$DEPLOYED_COMMIT_FILE" 2>/dev/null || echo "unknown")

    if [ "$error_msg" = "null" ]; then
        error_msg="null"
    else
        error_msg="\"$error_msg\""
    fi

    cat > "$CONTRIBUTOR_DIR/last-deployment.json" << RESULT
{
  "status": "$status",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "commit": "$commit",
  "previousCommit": "$previous_commit",
  "error": $error_msg
}
RESULT
}
