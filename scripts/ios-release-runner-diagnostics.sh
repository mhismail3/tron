#!/usr/bin/env bash
set -uo pipefail

# Read-only, secret-safe evidence collector for the dedicated TestFlight host.
# It intentionally excludes process environments, keychains, runner credential
# files, signing identities, provisioning profiles, and raw GitHub job logs.

runner_user="tron-ci"
runner_name="tron-ios-release"
runner_label="tron-ios-release"
runner_home="/Users/$runner_user"
runner_dir="$runner_home/actions-runner"
runner_service_label="com.tron.ios-release-runner"
runner_bootstrap_label="com.tron.ios-release-runner-bootstrap"
runner_bootstrap_dir="/Library/Application Support/Tron/ReleaseRunner"
runner_log_dir="/Library/Logs/Tron"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
diagnostic_trace_id="$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$$"
diagnostic_status=0

emit() {
    local level="$1" event="$2" details="${3:-}" timestamp
    timestamp="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    details="${details//$'\r'/ }"
    details="${details//$'\n'/ }"
    printf 'timestamp=%s level=%s component=ios-release-runner-diagnostics trace=%s event=%s%s\n' \
        "$timestamp" "$level" "$diagnostic_trace_id" "$event" \
        "$([[ -n "$details" ]] && printf ' %s' "$details")"
    [[ "$level" != "error" ]] || diagnostic_status=1
}

listener_observation_is_valid() {
    local process_uid="$1" manager_uid="$2" manager_name="$3" security_session="$4" expected_uid="$5"
    [[ "$process_uid" == "$expected_uid" \
        && "$manager_uid" == "$expected_uid" \
        && "$manager_name" == "Background" \
        && "$security_session" == \{*\} ]]
}

if [[ "${1:-}" == "--self-test" ]]; then
    (( $# == 1 )) || { echo "error: diagnostics self-test takes no additional arguments" >&2; exit 1; }
    sample="$(emit info self_test $'line_one=true\nline_two=true')"
    [[ "$sample" == *"event=self_test line_one=true line_two=true"* ]] \
        || { echo "error: diagnostics logging did not sanitize multiline fields" >&2; exit 1; }
    [[ "$sample" != *$'\nline_two'* ]] \
        || { echo "error: diagnostics logging admitted a multiline field" >&2; exit 1; }
    listener_observation_is_valid 502 502 Background '{"audit_uid":502,"is_root":false}' 502 \
        || { echo "error: diagnostics rejected a valid listener observation" >&2; exit 1; }
    if listener_observation_is_valid 0 502 Background '{"audit_uid":502,"is_root":false}' 502 \
        || listener_observation_is_valid 502 502 Background 'verification-error' 502; then
        echo "error: diagnostics accepted an invalid listener observation" >&2
        exit 1
    fi
    echo "iOS release runner diagnostics self-test passed"
    exit 0
fi
(( $# == 0 )) || { echo "usage: scripts/ios-release-runner-diagnostics.sh [--self-test]" >&2; exit 1; }

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] \
    || { emit error unsupported_host "os=$(/usr/bin/uname -s)"; exit 1; }

emit info collection_started "pid=$$"
if ! /usr/bin/sudo -v; then
    emit error sudo_unavailable "reason=authentication_failed"
    exit 1
fi

git_head="$(/usr/bin/git -C "$project_dir" rev-parse HEAD 2>/dev/null || true)"
git_dirty=false
if [[ -n "$(/usr/bin/git -C "$project_dir" status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
    git_dirty=true
fi
emit info repository_source "git_head=${git_head:-unavailable} git_dirty=$git_dirty"

runner_uid="$(/usr/bin/id -u "$runner_user" 2>/dev/null || true)"
if [[ "$runner_uid" =~ ^[0-9]+$ ]]; then
    runner_primary_group="$(/usr/bin/id -gn "$runner_user" 2>/dev/null || true)"
    runner_home_mode="$(/usr/bin/sudo /usr/bin/stat -f '%Lp' "$runner_home" 2>/dev/null || true)"
    runner_admin=false
    if /usr/sbin/dseditgroup -o checkmember -m "$runner_user" admin 2>/dev/null \
        | /usr/bin/grep -q 'yes'; then
        runner_admin=true
    fi
    if [[ "$runner_uid" -ge 500 && "$runner_primary_group" == "staff" \
        && "$runner_home_mode" == "700" && "$runner_admin" == "false" ]]; then
        emit info account_observed \
            "uid=$runner_uid primary_group=$runner_primary_group home_mode=$runner_home_mode admin=$runner_admin"
    else
        emit error account_observed \
            "uid=$runner_uid primary_group=${runner_primary_group:-unavailable} home_mode=${runner_home_mode:-unavailable} admin=$runner_admin"
    fi
else
    emit error account_missing "runner_user=$runner_user"
fi

inspect_file() {
    local expected_mode="$1" path="$2" metadata sha256
    if ! /usr/bin/sudo /bin/test -e "$path" && ! /usr/bin/sudo /bin/test -L "$path"; then
        emit error installed_file_missing "path=$path expected_mode=$expected_mode"
        return
    fi
    if /usr/bin/sudo /bin/test -L "$path"; then
        emit error installed_file_unsafe "path=$path reason=symlink"
        return
    fi
    metadata="$(/usr/bin/sudo /usr/bin/stat -f '%Su:%Sg:%Lp:%l:%z' "$path" 2>/dev/null || true)"
    sha256="$(/usr/bin/sudo /usr/bin/shasum -a 256 "$path" 2>/dev/null | /usr/bin/awk '{print $1}')"
    if [[ "$metadata" == root:wheel:"$expected_mode":1:* && "$sha256" =~ ^[[:xdigit:]]{64}$ ]]; then
        emit info installed_file_observed \
            "path=$path metadata=$metadata sha256=$sha256"
    else
        emit error installed_file_observed \
            "path=$path metadata=${metadata:-unavailable} sha256=${sha256:-unavailable} expected=root:wheel:$expected_mode:1"
    fi
}

inspect_launchd_target() {
    local output state pid last_exit target="$1"
    if ! output="$(/usr/bin/sudo /bin/launchctl print "$target" 2>&1)"; then
        emit error launchd_target_absent "target=$target"
        return
    fi
    state="$(printf '%s\n' "$output" | /usr/bin/awk -F' = ' '/^[[:space:]]*state = / {print $2; exit}')"
    pid="$(printf '%s\n' "$output" | /usr/bin/awk -F' = ' '/^[[:space:]]*pid = / {print $2; exit}')"
    last_exit="$(printf '%s\n' "$output" | /usr/bin/awk -F' = ' '/^[[:space:]]*last exit code = / {print $2; exit}')"
    emit info launchd_target_observed \
        "target=$target state=${state:-unavailable} pid=${pid:-none} last_exit=${last_exit:-none}"
}

for file_contract in \
    "644:$runner_bootstrap_dir/$runner_service_label.plist" \
    "600:/Library/LaunchDaemons/$runner_bootstrap_label.plist" \
    "755:$runner_bootstrap_dir/bootstrap-user-agent" \
    "755:$runner_bootstrap_dir/start-runner" \
    "600:$runner_log_dir/ios-release-runner-bootstrap.log" \
    "600:$runner_log_dir/ios-release-runner-launchd.log" \
    "600:$runner_log_dir/ios-release-runner-launchd-error.log"; do
    inspect_file "${file_contract%%:*}" "${file_contract#*:}"
done

for journal_path in \
    "$runner_bootstrap_dir/background-service-backup" \
    "$runner_bootstrap_dir/legacy-system-service.plist"; do
    if /usr/bin/sudo /bin/test -e "$journal_path" || /usr/bin/sudo /bin/test -L "$journal_path"; then
        emit error rollback_journal_present "path=$journal_path steady_state=false"
    else
        emit info rollback_journal_absent "path=$journal_path"
    fi
done

if [[ "$runner_uid" =~ ^[0-9]+$ ]]; then
    inspect_launchd_target "system/$runner_bootstrap_label"
    inspect_launchd_target "user/$runner_uid/$runner_service_label"
    listener_pid="$(
        /usr/bin/sudo /usr/bin/pgrep -u "$runner_uid" \
            -f "^$runner_dir/bin/Runner.Listener run" 2>/dev/null \
            | /usr/bin/head -1
    )"
    if [[ "$listener_pid" =~ ^[0-9]+$ ]]; then
        listener_process_uid="$(
            /usr/bin/sudo /bin/ps -o uid= -p "$listener_pid" 2>/dev/null \
                | /usr/bin/xargs
        )"
        listener_process="$(
            /usr/bin/sudo /bin/ps -o pid=,ppid=,uid=,user= -p "$listener_pid" 2>/dev/null \
                | /usr/bin/xargs
        )"
        listener_manager_uid="$(
            /usr/bin/sudo /bin/launchctl bsexec "$listener_pid" \
                /bin/launchctl manageruid 2>/dev/null || true
        )"
        listener_manager_name="$(
            /usr/bin/sudo /bin/launchctl bsexec "$listener_pid" \
                /bin/launchctl managername 2>/dev/null || true
        )"
        listener_security="$(
            /usr/bin/sudo /bin/launchctl bsexec "$listener_pid" \
                /usr/bin/python3 "$project_dir/scripts/ios-release-verify.py" \
                security-session --require-non-root \
                --require-audit-uid "$runner_uid" 2>&1 || true
        )"
        if listener_observation_is_valid \
            "$listener_process_uid" \
            "$listener_manager_uid" \
            "$listener_manager_name" \
            "$listener_security" \
            "$runner_uid"; then
            emit info listener_identity_observed \
                "process='$listener_process' process_uid=$listener_process_uid manager_uid=$listener_manager_uid manager_name=$listener_manager_name security_session=$listener_security"
        else
            emit error listener_identity_observed \
                "process='${listener_process:-unavailable}' process_uid=${listener_process_uid:-unavailable} manager_uid=${listener_manager_uid:-unavailable} manager_name=${listener_manager_name:-unavailable} security_session=${listener_security:-unavailable}"
        fi
    else
        emit error listener_missing "expected_uid=$runner_uid"
    fi
fi

gh_executable="$(command -v gh || true)"
if [[ "$gh_executable" == /* && -x "$gh_executable" ]] \
    && "$gh_executable" auth status >/dev/null 2>&1; then
    repository="$("$gh_executable" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    if [[ -n "$repository" ]]; then
        remote_runner="$(
            "$gh_executable" api "repos/$repository/actions/runners?per_page=100" \
                --jq "[.runners[] | select(.name == \"$runner_name\") | {id, status, busy, labels: [.labels[].name]}] | @json" 2>/dev/null || true
        )"
        remote_runner_state="$(
            "$gh_executable" api "repos/$repository/actions/runners?per_page=100" \
                --jq "[.runners[] | select(.name == \"$runner_name\")] | if length == 1 then [.[0].status, .[0].busy, ([.[0].labels[].name] | index(\"$runner_label\") != null)] | @tsv else \"invalid-count\" end" 2>/dev/null || true
        )"
        case "$remote_runner_state" in
            $'online\tfalse\ttrue' | $'online\ttrue\ttrue')
                emit info remote_runner_observed "observation=$remote_runner"
                ;;
            *)
                emit error remote_runner_observed "observation=${remote_runner:-unavailable}"
                ;;
        esac
        for workflow in ci.yml release-ios.yml; do
            while IFS= read -r run_observation; do
                [[ -n "$run_observation" ]] \
                    && emit info workflow_run_observed \
                        "workflow=$workflow observation=$run_observation"
            done < <(
                "$gh_executable" run list --workflow "$workflow" --branch main --limit 3 \
                    --json databaseId,status,conclusion,event,headSha,createdAt,updatedAt,url \
                    --jq '.[] | @json' 2>/dev/null || true
            )
        done
    else
        emit error github_repository_unavailable "reason=resolution_failed"
    fi
else
    emit error github_cli_unavailable "reason=missing_or_unauthenticated"
fi

tail_owned_log() {
    local path="$1" source="$2" line
    if ! /usr/bin/sudo /bin/test -f "$path" || /usr/bin/sudo /bin/test -L "$path"; then
        emit warning owned_log_unavailable "source=$source"
        return
    fi
    while IFS= read -r line; do
        line="${line//$'\r'/ }"
        line="${line//$'\n'/ }"
        printf 'log_source=%s %s\n' "$source" "$line"
    done < <(/usr/bin/sudo /usr/bin/tail -n 80 "$path" 2>/dev/null)
}

tail_owned_log "$runner_log_dir/ios-release-runner-bootstrap.log" bootstrap
tail_owned_log "$runner_log_dir/ios-release-runner-launchd.log" launchd
tail_owned_log "$runner_log_dir/ios-release-runner-launchd-error.log" launchd-error
for session_log in stdout.log stderr.log; do
    session_log_path="$runner_home/Library/Logs/$runner_service_label/$session_log"
    if /usr/bin/sudo /bin/test -f "$session_log_path" \
        && ! /usr/bin/sudo /bin/test -L "$session_log_path"; then
        session_log_metadata="$(
            /usr/bin/sudo /usr/bin/stat -f '%Su:%Sg:%Lp:%l' \
                "$session_log_path" 2>/dev/null || true
        )"
        if [[ "$session_log_metadata" != "$runner_user:staff:600:1" ]]; then
            emit error session_log_unsafe \
                "stream=$session_log metadata=${session_log_metadata:-unavailable} expected=$runner_user:staff:600:1"
            continue
        fi
        while IFS= read -r line; do
            printf 'log_source=session-%s %s\n' "$session_log" "$line"
        done < <(
            /usr/bin/sudo /usr/bin/tail -n 200 "$session_log_path" 2>/dev/null \
                | /usr/bin/grep 'component=ios-release-runner-session' \
                | /usr/bin/tail -n 40 || true
        )
    fi
done

emit info collection_finished "status=$diagnostic_status"
exit "$diagnostic_status"
