#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$project_dir/config/ci-toolchain.env"

runner_user="tron-ci"
runner_home="/Users/$runner_user"
runner_dir="$runner_home/actions-runner"
runner_label="tron-ios-release"
runner_name="tron-ios-release"
runner_service_label="com.tron.ios-release-runner"
runner_bootstrap_label="com.tron.ios-release-runner-bootstrap"
runner_bootstrap_dir="/Library/Application Support/Tron/ReleaseRunner"
runner_service_plist="$runner_bootstrap_dir/$runner_service_label.plist"
legacy_runner_service_plist="/Library/LaunchDaemons/$runner_service_label.plist"
legacy_runner_service_backup="$runner_bootstrap_dir/legacy-system-service.plist"
runner_bootstrap_plist="/Library/LaunchDaemons/$runner_bootstrap_label.plist"
runner_bootstrap_helper="$runner_bootstrap_dir/bootstrap-user-agent"
runner_bootstrap_helper_source="$project_dir/scripts/ios-release-runner-launchd-bootstrap"
runner_session_entrypoint="$runner_bootstrap_dir/start-runner"
runner_session_entrypoint_source="$project_dir/scripts/ios-release-runner-session-entrypoint"
runner_diagnostics_source="$project_dir/scripts/ios-release-runner-diagnostics.sh"
runner_bootstrap_lock="/var/run/tron-ios-release-runner-bootstrap.lock"
runner_background_backup_dir="$runner_bootstrap_dir/background-service-backup"
runner_log_dir="/Library/Logs/Tron"
runner_bootstrap_log="$runner_log_dir/ios-release-runner-bootstrap.log"
runner_bootstrap_stdout_log="$runner_log_dir/ios-release-runner-launchd.log"
runner_bootstrap_stderr_log="$runner_log_dir/ios-release-runner-launchd-error.log"
# The only previously shipped Background helper required SessionCreate=true.
# Repair recognizes that exact root-owned helper so it can upgrade the live
# topology transactionally without accepting arbitrary privileged code.
legacy_background_helper_sha256="7312787b9ddbb2f5064402b97d6df0c0358ce8987768ebe9161cffc574d13e1a"
bootstrap_trace_id="$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$$"
durable_log_ready=false
durable_log_warning_emitted=false
bootstrap_phase=initialization

log_event() {
    local level="$1" event="$2" details="${3:-}" line timestamp
    timestamp="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    details="${details//$'\r'/ }"
    details="${details//$'\n'/ }"
    line="timestamp=$timestamp level=$level component=ios-release-runner-bootstrap trace=$bootstrap_trace_id event=$event"
    [[ -z "$details" ]] || line="$line $details"
    printf '%s\n' "$line" >&2
    if [[ "$durable_log_ready" == "true" ]]; then
        if ! printf '%s\n' "$line" \
            | /usr/bin/sudo -n /usr/bin/tee -a "$runner_bootstrap_log" >/dev/null 2>&1; then
            durable_log_ready=false
            if [[ "$durable_log_warning_emitted" != "true" ]]; then
                durable_log_warning_emitted=true
                printf 'warning: durable iOS release runner logging became unavailable\n' >&2
            fi
        fi
    fi
    return 0
}

record_unhandled_error() {
    local exit_status="$1" source_line="$2"
    log_event error unhandled_command_failure \
        "phase=$bootstrap_phase source_line=$source_line exit_status=$exit_status"
    return 0
}

die() {
    log_event error fatal "message=$*"
    exit 1
}

gh_executable="$(command -v gh || true)"
# This macOS-only bootstrap relies on BSD utility flags. Do not let Homebrew
# coreutils or another interactive-shell PATH change their semantics.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

configure_runner_service_plist() {
    local plist="$1" create_session="${2:-false}"
    /bin/rm -f "$plist"
    /usr/bin/plutil -create xml1 "$plist"
    /usr/libexec/PlistBuddy -c "Add :Label string $runner_service_label" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$plist"
    if [[ "$create_session" == "true" ]]; then
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $runner_dir/runsvc.sh" "$plist"
    else
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $runner_session_entrypoint" "$plist"
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $runner_user" "$plist"
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $runner_dir/runsvc.sh" "$plist"
    fi
    /usr/libexec/PlistBuddy -c "Add :WorkingDirectory string $runner_dir" "$plist"
    /usr/libexec/PlistBuddy -c "Add :StandardOutPath string $runner_home/Library/Logs/$runner_service_label/stdout.log" "$plist"
    /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $runner_home/Library/Logs/$runner_service_label/stderr.log" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$plist"
    if [[ "$create_session" == "true" ]]; then
        /usr/libexec/PlistBuddy -c "Add :SessionCreate bool true" "$plist"
    fi
    /usr/libexec/PlistBuddy -c "Add :LimitLoadToSessionType string Background" "$plist"
    /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$plist"
    /usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$plist"
    /usr/libexec/PlistBuddy -c "Add :Umask integer 63" "$plist"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$plist"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:ACTIONS_RUNNER_SVC string 1" \
        "$plist"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:HOME string $runner_home" \
        "$plist"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:PATH string $PATH" \
        "$plist"
}

configure_runner_bootstrap_plist() {
    local plist="$1" runner_uid="$2"
    /bin/rm -f "$plist"
    /usr/bin/plutil -create xml1 "$plist"
    /usr/libexec/PlistBuddy -c "Add :Label string $runner_bootstrap_label" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $runner_bootstrap_helper" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $runner_user" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $runner_uid" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string $runner_service_plist" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string $runner_service_label" "$plist"
    /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$plist"
    /usr/libexec/PlistBuddy -c "Add :KeepAlive dict" "$plist"
    /usr/libexec/PlistBuddy -c "Add :KeepAlive:SuccessfulExit bool false" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 30" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$plist"
    /usr/libexec/PlistBuddy -c "Add :Umask integer 63" "$plist"
    /usr/libexec/PlistBuddy -c "Add :StandardOutPath string $runner_bootstrap_stdout_log" "$plist"
    /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $runner_bootstrap_stderr_log" "$plist"
}

configure_legacy_runner_bootstrap_plist() {
    local plist="$1" runner_uid="$2"
    /bin/rm -f "$plist"
    /usr/bin/plutil -create xml1 "$plist"
    /usr/libexec/PlistBuddy -c "Add :Label string $runner_bootstrap_label" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $runner_bootstrap_helper" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $runner_user" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $runner_uid" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string $runner_service_plist" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string $runner_service_label" "$plist"
    /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$plist"
    /usr/libexec/PlistBuddy -c "Add :KeepAlive dict" "$plist"
    /usr/libexec/PlistBuddy -c "Add :KeepAlive:SuccessfulExit bool false" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 30" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$plist"
}

classify_runner_service_state() {
    local legacy_exists="$1" backup_exists="$2" candidate_count="$3"
    if [[ "$legacy_exists" == "true" && "$backup_exists" == "true" ]]; then
        echo invalid
    elif [[ "$legacy_exists" == "true" ]]; then
        echo legacy
    elif [[ "$backup_exists" == "true" ]]; then
        echo journaled
    elif [[ "$candidate_count" == "3" || "$candidate_count" == "4" ]]; then
        echo current
    else
        echo invalid
    fi
}

classify_existing_runner_directory_mode() {
    local mode="$1"
    case "$mode" in
        700) echo private ;;
        # The former installer extracted the checksum-pinned runner archive as
        # root. BSD tar therefore preserved the archive's `./` mode (0755)
        # over the mode-0700 directory that the bootstrap had just created.
        755) echo legacy-archive ;;
        *) echo invalid ;;
    esac
}

bootstrap_self_test() {
    local acl_entry acl_listing acl_probe acl_tail bootstrap_plist_probe legacy_bootstrap_plist_probe legacy_plist_probe plist_probe
    acl_probe="$(mktemp -d -t tron-runner-acl)"
    plist_probe="$(mktemp -t tron-runner-agent.plist)"
    legacy_plist_probe="$(mktemp -t tron-runner-legacy-agent.plist)"
    bootstrap_plist_probe="$(mktemp -t tron-runner-bootstrap.plist)"
    legacy_bootstrap_plist_probe="$(mktemp -t tron-runner-legacy-bootstrap.plist)"
    trap '/bin/chmod -N "$acl_probe" >/dev/null 2>&1 || true; /bin/rmdir "$acl_probe" >/dev/null 2>&1 || true; /bin/rm -f "$plist_probe" "$legacy_plist_probe" "$bootstrap_plist_probe" "$legacy_bootstrap_plist_probe"' EXIT
    chmod 750 "$acl_probe"
    acl_entry="user:$(id -un) deny list,search"
    chmod +a "$acl_entry" "$acl_probe"
    chmod +a "$acl_entry" "$acl_probe"
    acl_listing="$(ls -lde "$acl_probe")"
    [[ "$acl_listing" == *"$acl_entry"* ]] \
        || die "runner isolation ACL is not idempotent"
    acl_tail="${acl_listing#*"$acl_entry"}"
    [[ "$acl_tail" != *"$acl_entry"* ]] \
        || die "runner isolation ACL is not idempotent"
    [[ "$(/usr/bin/stat -f '%Su' "$acl_probe")" == "$(id -un)" ]] \
        || die "macOS ownership inspection is unavailable"
    if /bin/test -r "$acl_probe" || /bin/test -x "$acl_probe"; then
        die "runner isolation ACL does not deny list and search access"
    fi
    chmod -a "$acl_entry" "$acl_probe"
    /bin/rmdir "$acl_probe"

    configure_runner_service_plist "$plist_probe"
    plutil -lint "$plist_probe" >/dev/null
    [[ "$(plutil -extract LimitLoadToSessionType raw -o - "$plist_probe")" == "Background" ]] \
        || die "release runner agent is not restricted to the Background domain"
    [[ "$(plutil -extract EnvironmentVariables.HOME raw -o - "$plist_probe")" == "$runner_home" ]] \
        || die "release runner agent has the wrong HOME"
    [[ "$(plutil -extract ProgramArguments.0 raw -o - "$plist_probe")" == "$runner_session_entrypoint" ]] \
        || die "release runner agent does not use the fail-closed session entry point"
    [[ "$(plutil -extract ProgramArguments.2 raw -o - "$plist_probe")" == "$runner_dir/runsvc.sh" ]] \
        || die "release runner agent has the wrong listener program"
    ! plutil -extract UserName raw -o - "$plist_probe" >/dev/null 2>&1 \
        || die "release runner agent must inherit its user-domain identity"
    ! plutil -extract GroupName raw -o - "$plist_probe" >/dev/null 2>&1 \
        || die "release runner agent must inherit its user-domain group"
    ! plutil -extract SessionCreate raw -o - "$plist_probe" >/dev/null 2>&1 \
        || die "release runner agent must inherit its Background audit session"
    configure_runner_service_plist "$legacy_plist_probe" true
    [[ "$(plutil -extract SessionCreate raw -o - "$legacy_plist_probe")" == "true" ]] \
        || die "release runner repair cannot recognize the prior audit-session contract"
    configure_runner_bootstrap_plist "$bootstrap_plist_probe" 502
    plutil -lint "$bootstrap_plist_probe" >/dev/null
    [[ "$(plutil -extract ProgramArguments.1 raw -o - "$bootstrap_plist_probe")" == "$runner_user" ]] \
        || die "release runner bootstrap daemon has the wrong account"
    [[ "$(plutil -extract ProgramArguments.2 raw -o - "$bootstrap_plist_probe")" == "502" ]] \
        || die "release runner bootstrap daemon has the wrong UID"
    [[ "$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$bootstrap_plist_probe")" == "false" ]] \
        || die "release runner bootstrap daemon must retry only after failure"
    [[ "$(plutil -extract StandardOutPath raw -o - "$bootstrap_plist_probe")" == "$runner_bootstrap_stdout_log" ]] \
        || die "release runner bootstrap daemon has the wrong durable output log"
    [[ "$(plutil -extract StandardErrorPath raw -o - "$bootstrap_plist_probe")" == "$runner_bootstrap_stderr_log" ]] \
        || die "release runner bootstrap daemon has the wrong durable error log"
    [[ "$(plutil -extract Umask raw -o - "$bootstrap_plist_probe")" == "63" ]] \
        || die "release runner bootstrap daemon has the wrong log-creation umask"
    configure_legacy_runner_bootstrap_plist "$legacy_bootstrap_plist_probe" 502
    plutil -lint "$legacy_bootstrap_plist_probe" >/dev/null
    ! plutil -extract StandardOutPath raw -o - "$legacy_bootstrap_plist_probe" >/dev/null 2>&1 \
        || die "release runner repair lost the prior no-log bootstrap contract"
    ! plutil -extract StandardErrorPath raw -o - "$legacy_bootstrap_plist_probe" >/dev/null 2>&1 \
        || die "release runner repair lost the prior no-log bootstrap contract"
    ! plutil -extract Umask raw -o - "$legacy_bootstrap_plist_probe" >/dev/null 2>&1 \
        || die "release runner repair lost the prior no-log bootstrap contract"
    /usr/bin/python3 - "$legacy_bootstrap_plist_probe" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    document = plistlib.load(handle)
expected_keys = {
    "KeepAlive",
    "Label",
    "ProcessType",
    "ProgramArguments",
    "RunAtLoad",
    "ThrottleInterval",
}
if set(document) != expected_keys or set(document["KeepAlive"]) != {"SuccessfulExit"}:
    raise SystemExit("error: prior no-log bootstrap contract gained or lost keys")
PY
    [[ "$(classify_runner_service_state true false 0)" == "legacy" ]] \
        || die "release runner migration state machine rejected the legacy state"
    [[ "$(classify_runner_service_state false true 2)" == "journaled" ]] \
        || die "release runner migration state machine rejected an interrupted candidate"
    [[ "$(classify_runner_service_state false false 3)" == "current" \
        && "$(classify_runner_service_state false false 4)" == "current" ]] \
        || die "release runner migration state machine rejected the current topology"
    [[ "$(classify_runner_service_state true true 4)" == "invalid" \
        && "$(classify_runner_service_state false false 1)" == "invalid" \
        && "$(classify_runner_service_state false false 5)" == "invalid" ]] \
        || die "release runner migration state machine accepted an ambiguous topology"
    [[ "$(classify_existing_runner_directory_mode 700)" == "private" \
        && "$(classify_existing_runner_directory_mode 755)" == "legacy-archive" ]] \
        || die "release runner mode classifier rejected a supported state"
    [[ "$(classify_existing_runner_directory_mode 750)" == "invalid" \
        && "$(classify_existing_runner_directory_mode 777)" == "invalid" ]] \
        || die "release runner mode classifier accepted an unsupported state"
    /bin/bash -n "$runner_bootstrap_helper_source"
    /bin/bash -n "$runner_session_entrypoint_source"
    /bin/bash -n "$runner_diagnostics_source"
    "$runner_session_entrypoint_source" --self-test >/dev/null
    "$runner_diagnostics_source" --self-test >/dev/null
    /bin/rm -f \
        "$plist_probe" \
        "$legacy_plist_probe" \
        "$bootstrap_plist_probe" \
        "$legacy_bootstrap_plist_probe"
    trap - EXIT
    echo "iOS release runner bootstrap self-test passed"
}

bootstrap_mode="${1:-install}"
case "$bootstrap_mode" in
    install | --repair-service | --self-test) ;;
    *) die "usage: scripts/bootstrap-ios-release-runner.sh [--repair-service|--self-test]" ;;
esac
if [[ "$bootstrap_mode" == "--self-test" ]]; then
    bootstrap_self_test
    exit 0
fi
if [[ "$bootstrap_mode" == "install" ]]; then
    (( $# == 0 )) || die "usage: scripts/bootstrap-ios-release-runner.sh [--repair-service|--self-test]"
else
    (( $# == 1 )) || die "usage: scripts/bootstrap-ios-release-runner.sh [--repair-service|--self-test]"
fi
[[ "$gh_executable" == /* && -x "$gh_executable" ]] \
    || die "GitHub CLI is required"

run_as_runner() (
    # Never hand the service account a current working directory inside the
    # invoking user's otherwise-private home.
    cd /
    exec sudo -H -u "$runner_user" "$@"
)

run_in_runner_domain() (
    # `launchctl asuser` adopts the target bootstrap and security audit session
    # but deliberately does not change Unix credentials. Adopting another audit
    # session requires privilege, so preserve this order: enter the domain as
    # root, then immediately drop UID/GID before the requested command runs.
    # Reversing the order fails with EPERM on a headless account.
    cd /
    exec /usr/bin/sudo /bin/launchctl asuser "$runner_uid" \
        /usr/bin/sudo -n -H -u "$runner_user" "$@"
)

validate_privileged_directory() {
    local directory="$1" exact_mode="${2:-}" mode
    sudo /bin/test -d "$directory" \
        || die "privileged release path is not a directory: $directory"
    if sudo /bin/test -L "$directory"; then
        die "privileged release directory must not be a symlink: $directory"
    fi
    [[ "$(sudo /usr/bin/stat -f '%Su' "$directory")" == "root" ]] \
        || die "privileged release directory has the wrong owner: $directory"
    mode="$(sudo /usr/bin/stat -f '%Lp' "$directory")"
    if [[ -n "$exact_mode" ]]; then
        [[ "$mode" == "$exact_mode" ]] \
            || die "privileged release directory $directory must have mode 0$exact_mode"
    elif (( (8#$mode & 8#022) != 0 )); then
        die "privileged release directory is group- or world-writable: $directory"
    fi
}

validate_privileged_file() {
    local file="$1" expected_mode="$2"
    sudo /bin/test -f "$file" \
        || die "privileged release path is not a regular file: $file"
    if sudo /bin/test -L "$file"; then
        die "privileged release file must not be a symlink: $file"
    fi
    [[ "$(sudo /usr/bin/stat -f '%Su:%Sg:%Lp' "$file")" == "root:wheel:$expected_mode" ]] \
        || die "privileged release file has the wrong owner or mode: $file"
    [[ "$(sudo /usr/bin/stat -f '%l' "$file")" == "1" ]] \
        || die "privileged release file must not have hard links: $file"
}

initialize_bootstrap_logging() {
    local log_file
    validate_privileged_directory /Library
    validate_privileged_directory /Library/Logs
    if sudo /bin/test -e "$runner_log_dir" || sudo /bin/test -L "$runner_log_dir"; then
        validate_privileged_directory "$runner_log_dir" 755
        [[ "$(sudo /usr/bin/stat -f '%Sg' "$runner_log_dir")" == "wheel" ]] \
            || die "release runner log directory has the wrong group"
    else
        sudo /usr/bin/install -d -m 755 -o root -g wheel "$runner_log_dir" \
            || die "could not create the release runner log directory"
    fi
    for log_file in \
        "$runner_bootstrap_log" \
        "$runner_bootstrap_stdout_log" \
        "$runner_bootstrap_stderr_log"; do
        if sudo /bin/test -e "$log_file" || sudo /bin/test -L "$log_file"; then
            validate_privileged_file "$log_file" 600
        else
            sudo /usr/bin/install -m 600 -o root -g wheel /dev/null "$log_file" \
                || die "could not create a release runner log file"
        fi
    done
    durable_log_ready=true
    log_event info logging_ready \
        "directory_mode=755 file_mode=600 storage=root-owned"
    [[ "$durable_log_ready" == "true" ]] \
        || die "could not append to the durable release runner bootstrap log"
}

validate_privileged_install_roots() {
    validate_privileged_directory /Library
    validate_privileged_directory /Library/LaunchDaemons
    validate_privileged_directory "/Library/Application Support"
    if sudo /bin/test -e "/Library/Application Support/Tron" \
        || sudo /bin/test -L "/Library/Application Support/Tron"; then
        validate_privileged_directory "/Library/Application Support/Tron" 755
        [[ "$(sudo /usr/bin/stat -f '%Sg' "/Library/Application Support/Tron")" == "wheel" ]] \
            || die "privileged Tron support directory has the wrong group"
    fi
    if sudo /bin/test -e "$runner_bootstrap_dir" \
        || sudo /bin/test -L "$runner_bootstrap_dir"; then
        validate_privileged_directory "$runner_bootstrap_dir" 755
        [[ "$(sudo /usr/bin/stat -f '%Sg' "$runner_bootstrap_dir")" == "wheel" ]] \
            || die "release runner bootstrap directory has the wrong group"
    fi
}

ensure_privileged_support_directory() {
    validate_privileged_install_roots
    if ! sudo /bin/test -e "/Library/Application Support/Tron"; then
        sudo /usr/bin/install -d -m 755 -o root -g wheel \
            "/Library/Application Support/Tron" \
            || return 1
    fi
    validate_privileged_directory "/Library/Application Support/Tron" 755
    [[ "$(sudo /usr/bin/stat -f '%Sg' "/Library/Application Support/Tron")" == "wheel" ]] \
        || return 1
    if ! sudo /bin/test -e "$runner_bootstrap_dir"; then
        sudo /usr/bin/install -d -m 755 -o root -g wheel "$runner_bootstrap_dir" \
            || return 1
    fi
    validate_privileged_directory "$runner_bootstrap_dir" 755
    [[ "$(sudo /usr/bin/stat -f '%Sg' "$runner_bootstrap_dir")" == "wheel" ]] \
        || return 1
    [[ "$(sudo /usr/bin/stat -f '%d' "$runner_bootstrap_dir")" \
        == "$(sudo /usr/bin/stat -f '%d' /Library/LaunchDaemons)" ]] \
        || return 1
}

ensure_runner_user_domain() {
    local domain_created=false manager_name manager_uid
    if ! sudo /bin/launchctl print "user/$runner_uid" >/dev/null 2>&1; then
        sudo /bin/launchctl bootstrap "user/$runner_uid" \
            || sudo /bin/launchctl print "user/$runner_uid" >/dev/null 2>&1 \
            || return 1
        domain_created=true
    fi
    manager_uid="$(run_in_runner_domain /bin/launchctl manageruid 2>/dev/null || true)"
    manager_name="$(run_in_runner_domain /bin/launchctl managername 2>/dev/null || true)"
    log_event info runner_domain_observed \
        "created=$domain_created expected_uid=$runner_uid manager_uid=${manager_uid:-unavailable} manager_name=${manager_name:-unavailable}"
    [[ "$manager_uid" == "$runner_uid" && "$manager_name" == "Background" ]]
}

verify_runner_domain_security_session() {
    local identity
    identity="$(
        run_in_runner_domain /usr/bin/python3 -c \
            'import ctypes, os; uid = ctypes.c_uint32(); process = ctypes.CDLL(None, use_errno=True); result = process.getauid(ctypes.byref(uid)); print(f"{os.geteuid()}:{uid.value}" if result == 0 else "error")'
    )" || identity="unavailable"
    log_event info runner_domain_security_observed \
        "expected_identity=$runner_uid:$runner_uid observed_identity=${identity:-unavailable}"
    [[ "$identity" == "$runner_uid:$runner_uid" ]]
}

validate_runner_directory_identity() {
    local directory="$1"
    sudo /bin/test -d "$directory" \
        || die "release runner path is not a directory: $directory"
    if sudo /bin/test -L "$directory"; then
        die "release runner path must not be a symlink: $directory"
    fi
    [[ "$(sudo /usr/bin/stat -f '%Su' "$directory")" == "$runner_user" ]] \
        || die "release runner path has the wrong owner: $directory"
}

validate_private_runner_directory() {
    local directory="$1"
    validate_runner_directory_identity "$directory"
    [[ "$(sudo /usr/bin/stat -f '%Lp' "$directory")" == "700" ]] \
        || die "release runner path must have mode 0700: $directory"
}

validate_existing_runner_install() {
    validate_runner_directory_identity "$runner_dir"
    existing_runner_directory_mode="$(sudo /usr/bin/stat -f '%Lp' "$runner_dir")"
    existing_runner_directory_state="$(
        classify_existing_runner_directory_mode "$existing_runner_directory_mode"
    )"
    [[ "$existing_runner_directory_state" != "invalid" ]] \
        || die "existing release runner path has unsupported mode 0$existing_runner_directory_mode"
    local path
    for path in \
        "$runner_dir/config.sh" \
        "$runner_dir/bin/runsvc.sh" \
        "$runner_dir/bin/Runner.Listener" \
        "$runner_dir/runsvc.sh" \
        "$runner_dir/.runner" \
        "$runner_dir/.credentials"; do
        sudo /bin/test -f "$path" \
            || die "existing release runner file is missing: $path"
        if sudo /bin/test -L "$path"; then
            die "existing release runner file must not be a symlink: $path"
        fi
        [[ "$(sudo /usr/bin/stat -f '%Su' "$path")" == "$runner_user" ]] \
            || die "existing release runner file has the wrong owner: $path"
    done
    installed_runner_version="$(
        run_as_runner "$runner_dir/bin/Runner.Listener" --version \
            | /usr/bin/tail -1
    )"
    [[ "$installed_runner_version" == "$TRON_RELEASE_RUNNER_VERSION" ]] \
        || die "installed release runner version $installed_runner_version does not match $TRON_RELEASE_RUNNER_VERSION"
}

normalize_existing_runner_directory_mode() {
    validate_runner_directory_identity "$runner_dir"
    local observed_mode
    observed_mode="$(sudo /usr/bin/stat -f '%Lp' "$runner_dir")"
    [[ "$observed_mode" == "$existing_runner_directory_mode" ]] \
        || die "release runner directory mode changed during repair"
    case "$existing_runner_directory_state" in
        private) ;;
        legacy-archive)
            # Tighten the known legacy archive mode as the directory owner.
            # Root must not follow or mutate paths below the runner-owned home.
            run_as_runner /bin/chmod 700 "$runner_dir" \
                || die "could not tighten the legacy release runner directory"
            ;;
        *) die "release runner directory mode is not repairable" ;;
    esac
    validate_private_runner_directory "$runner_dir"
    # Revalidate every executable and registration file after the mutation so
    # a path replacement cannot carry stale pre-normalization evidence forward.
    validate_existing_runner_install
    [[ "$existing_runner_directory_state" == "private" ]] \
        || die "release runner directory did not reach the private mode"
}

stage_runner_service_files() {
    runner_plist_staging="$(mktemp -t tron-ios-release-runner.plist)"
    runner_legacy_plist_staging="$(mktemp -t tron-ios-release-runner-legacy.plist)"
    runner_bootstrap_plist_staging="$(mktemp -t tron-ios-release-bootstrap.plist)"
    runner_legacy_bootstrap_plist_staging="$(mktemp -t tron-ios-release-legacy-bootstrap.plist)"
    configure_runner_service_plist "$runner_plist_staging"
    configure_runner_service_plist "$runner_legacy_plist_staging" true
    configure_runner_bootstrap_plist "$runner_bootstrap_plist_staging" "$runner_uid"
    configure_legacy_runner_bootstrap_plist \
        "$runner_legacy_bootstrap_plist_staging" "$runner_uid"
    plutil -lint "$runner_plist_staging" >/dev/null
    plutil -lint "$runner_legacy_plist_staging" >/dev/null
    plutil -lint "$runner_bootstrap_plist_staging" >/dev/null
    plutil -lint "$runner_legacy_bootstrap_plist_staging" >/dev/null
}

install_runner_service_files() {
    local path
    log_event info service_files_install_started "candidate_file_count=4"
    ensure_privileged_support_directory || return 1
    for path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper" \
        "$runner_session_entrypoint"; do
        if sudo /bin/test -e "$path" || sudo /bin/test -L "$path"; then
            echo "error: refusing to replace existing release service path: $path" >&2
            return 1
        fi
    done
    sudo /usr/bin/install -m 755 -o root -g wheel \
        "$runner_bootstrap_helper_source" "$runner_bootstrap_helper" \
        || return 1
    sudo /usr/bin/install -m 755 -o root -g wheel \
        "$runner_session_entrypoint_source" "$runner_session_entrypoint" \
        || return 1
    sudo /usr/bin/install -m 644 -o root -g wheel \
        "$runner_plist_staging" "$runner_service_plist" \
        || return 1
    sudo /usr/bin/install -m 600 -o root -g wheel \
        "$runner_bootstrap_plist_staging" "$runner_bootstrap_plist" \
        || return 1
    validate_installed_runner_service_files
    log_event info service_files_installed "candidate_file_count=4"
}

validate_installed_runner_service_files() {
    validate_privileged_install_roots
    validate_privileged_file "$runner_service_plist" 644
    validate_privileged_file "$runner_bootstrap_plist" 600
    validate_privileged_file "$runner_bootstrap_helper" 755
    validate_privileged_file "$runner_session_entrypoint" 755
    sudo /usr/bin/cmp -s "$runner_plist_staging" "$runner_service_plist" \
        || die "installed release runner agent differs from the staged contract"
    sudo /usr/bin/cmp -s "$runner_bootstrap_plist_staging" "$runner_bootstrap_plist" \
        || die "installed release runner bootstrap daemon differs from the staged contract"
    sudo /usr/bin/cmp -s "$runner_bootstrap_helper_source" "$runner_bootstrap_helper" \
        || die "installed release runner bootstrap helper differs from repository source"
    sudo /usr/bin/cmp -s "$runner_session_entrypoint_source" "$runner_session_entrypoint" \
        || die "installed release runner session entry point differs from repository source"
}

current_runner_service_files_match() {
    sudo /usr/bin/cmp -s "$runner_plist_staging" "$runner_service_plist" \
        && sudo /usr/bin/cmp -s "$runner_bootstrap_plist_staging" "$runner_bootstrap_plist" \
        && sudo /usr/bin/cmp -s "$runner_bootstrap_helper_source" "$runner_bootstrap_helper" \
        && sudo /usr/bin/cmp -s "$runner_session_entrypoint_source" "$runner_session_entrypoint"
}

validate_legacy_background_runner_service_files() {
    validate_privileged_install_roots
    validate_privileged_file "$runner_service_plist" 644
    validate_privileged_file "$runner_bootstrap_plist" 600
    validate_privileged_file "$runner_bootstrap_helper" 755
    legacy_background_runner_service_files_match \
        || die "existing Background service is not the recognized prior contract"
}

legacy_background_runner_service_files_match() {
    local helper_sha
    if sudo /bin/test -e "$runner_session_entrypoint" \
        || sudo /bin/test -L "$runner_session_entrypoint"; then
        return 1
    fi
    sudo /usr/bin/cmp -s "$runner_legacy_plist_staging" "$runner_service_plist" \
        || return 1
    sudo /usr/bin/cmp -s "$runner_legacy_bootstrap_plist_staging" "$runner_bootstrap_plist" \
        || return 1
    helper_sha="$(sudo /usr/bin/shasum -a 256 "$runner_bootstrap_helper" | /usr/bin/awk '{print $1}')"
    [[ "$helper_sha" == "$legacy_background_helper_sha256" ]] \
        || return 1
}

validate_background_service_backup() {
    local agent_backup bootstrap_backup helper_backup helper_sha
    validate_privileged_directory "$runner_background_backup_dir" 700
    agent_backup="$runner_background_backup_dir/$(/usr/bin/basename "$runner_service_plist")"
    bootstrap_backup="$runner_background_backup_dir/$(/usr/bin/basename "$runner_bootstrap_plist")"
    helper_backup="$runner_background_backup_dir/$(/usr/bin/basename "$runner_bootstrap_helper")"
    validate_privileged_file "$agent_backup" 644
    validate_privileged_file "$bootstrap_backup" 600
    validate_privileged_file "$helper_backup" 755
    sudo /usr/bin/cmp -s "$runner_legacy_plist_staging" "$agent_backup" \
        || die "Background rollback journal has an unrecognized agent contract"
    sudo /usr/bin/cmp -s "$runner_legacy_bootstrap_plist_staging" "$bootstrap_backup" \
        || die "Background rollback journal has an inconsistent bootstrap daemon"
    helper_sha="$(sudo /usr/bin/shasum -a 256 "$helper_backup" | /usr/bin/awk '{print $1}')"
    [[ "$helper_sha" == "$legacy_background_helper_sha256" ]] \
        || die "Background rollback journal has an unrecognized bootstrap helper"
}

create_background_service_backup() {
    local path backup_path
    log_event info background_journal_create_started "file_count=3"
    if sudo /bin/test -e "$runner_background_backup_dir" \
        || sudo /bin/test -L "$runner_background_backup_dir"; then
        return 1
    fi
    sudo /usr/bin/install -d -m 700 -o root -g wheel "$runner_background_backup_dir" \
        || return 1
    validate_privileged_directory "$runner_background_backup_dir" 700
    for path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper"; do
        backup_path="$runner_background_backup_dir/$(/usr/bin/basename "$path")"
        sudo /bin/cp -p "$path" "$backup_path" || return 1
        sudo /usr/bin/cmp -s "$path" "$backup_path" || return 1
    done
    validate_privileged_file "$runner_background_backup_dir/$(/usr/bin/basename "$runner_service_plist")" 644
    validate_privileged_file "$runner_background_backup_dir/$(/usr/bin/basename "$runner_bootstrap_plist")" 600
    validate_privileged_file "$runner_background_backup_dir/$(/usr/bin/basename "$runner_bootstrap_helper")" 755
    log_event info background_journal_created "file_count=3 mode=700"
}

remove_background_service_backup() {
    local path
    for path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper"; do
        sudo /bin/rm -f "$runner_background_backup_dir/$(/usr/bin/basename "$path")" \
            || return 1
    done
    sudo /bin/rmdir "$runner_background_backup_dir" || return 1
    log_event info background_journal_removed "file_count=3"
}

rollback_background_service_upgrade() {
    local path backup_path expected_mode
    log_event warning background_rollback_started "runner_id=${repair_runner_id:-unavailable}"
    stop_runner_candidate_services || return 1
    wait_for_all_runner_listeners_exit || return 1
    wait_for_remote_runner_status offline || return 1
    sudo /bin/rm -f "$runner_session_entrypoint" || return 1
    for path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper"; do
        sudo /bin/rm -f "$path" || return 1
        backup_path="$runner_background_backup_dir/$(/usr/bin/basename "$path")"
        sudo /bin/test -f "$backup_path" || return 1
        case "$path" in
            "$runner_service_plist") expected_mode=644 ;;
            "$runner_bootstrap_plist") expected_mode=600 ;;
            "$runner_bootstrap_helper") expected_mode=755 ;;
            *) return 1 ;;
        esac
        sudo /usr/bin/install -m "$expected_mode" -o root -g wheel "$backup_path" "$path" \
            || return 1
    done
    validate_legacy_background_runner_service_files
    remove_background_service_backup || return 1
    start_installed_runner_service_files || return 1
    wait_for_new_runner_listener "" || return 1
    wait_for_remote_runner_status online || return 1
    restore_remote_runner_label || return 1
    background_service_upgrade_active=false
    log_event warning background_rollback_completed \
        "runner_id=${repair_runner_id:-unavailable} status=$remote_runner_status labeled=$remote_runner_release_labeled"
}

legacy_runner_service_is_valid() {
    local legacy_plist="${1:-$legacy_runner_service_plist}"
    sudo /bin/test -f "$legacy_plist" \
        && ! sudo /bin/test -L "$legacy_plist" \
        && [[ "$(sudo /usr/bin/stat -f '%Su:%Sg:%Lp:%l' "$legacy_plist")" == "root:wheel:600:1" ]] \
        && [[ "$(sudo /usr/libexec/PlistBuddy -c 'Print :Label' "$legacy_plist" 2>/dev/null)" == "$runner_service_label" ]] \
        && [[ "$(sudo /usr/libexec/PlistBuddy -c 'Print :UserName' "$legacy_plist" 2>/dev/null)" == "$runner_user" ]] \
        && [[ "$(sudo /usr/libexec/PlistBuddy -c 'Print :GroupName' "$legacy_plist" 2>/dev/null)" == "staff" ]] \
        && [[ "$(sudo /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$legacy_plist" 2>/dev/null)" == "$runner_dir/runsvc.sh" ]]
}

validate_legacy_runner_service() {
    local legacy_plist="${1:-$legacy_runner_service_plist}"
    validate_privileged_file "$legacy_plist" 600
    legacy_runner_service_is_valid "$legacy_plist" \
        || die "legacy release runner service contract is inconsistent"
}

wait_for_launchd_target_exit() {
    local target="$1"
    for ((launchd_poll = 1; launchd_poll <= 30; launchd_poll++)); do
        if ! sudo /bin/launchctl print "$target" >/dev/null 2>&1; then
            log_event info launchd_target_absent \
                "target=$target polls=$launchd_poll timeout_seconds=30"
            return 0
        fi
        /bin/sleep 1
    done
    log_event error launchd_target_stop_timeout \
        "target=$target polls=30 timeout_seconds=30"
    return 1
}

stop_launchd_target() {
    local bootout_status target="$1"
    if ! sudo /bin/launchctl print "$target" >/dev/null 2>&1; then
        log_event info launchd_target_already_absent "target=$target"
        return 0
    fi
    if sudo /bin/launchctl bootout "$target"; then
        bootout_status=0
    else
        bootout_status=$?
    fi
    log_event info launchd_bootout_requested \
        "target=$target command_status=$bootout_status"
    # `launchctl bootout` acknowledges a teardown request before launchd has
    # necessarily removed the job. The observed absence is the postcondition;
    # the immediate command status alone is neither success nor failure proof.
    wait_for_launchd_target_exit "$target"
}

stop_runner_candidate_services() {
    # Stop the root helper first so it cannot recreate the user agent while the
    # candidate is being removed or a legacy listener is being restored.
    stop_launchd_target "system/$runner_bootstrap_label" || return 1
    stop_launchd_target "user/$runner_uid/$runner_service_label"
}

remove_runner_service_files() {
    log_event info service_files_remove_started "candidate_file_count=4"
    stop_runner_candidate_services || return 1
    sudo /bin/rm -f \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper" \
        "$runner_session_entrypoint" \
        || return 1
    for removed_path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper" \
        "$runner_session_entrypoint"; do
        if sudo /bin/test -e "$removed_path" || sudo /bin/test -L "$removed_path"; then
            return 1
        fi
    done
    log_event info service_files_removed "candidate_file_count=4"
}

start_installed_runner_service_files() {
    local helper_target="system/$runner_bootstrap_label"
    local runner_target="user/$runner_uid/$runner_service_label"
    log_event info launchd_service_start_started \
        "helper_target=$helper_target runner_target=$runner_target"
    sudo /bin/launchctl bootstrap system "$runner_bootstrap_plist" \
        || sudo /bin/launchctl print "$helper_target" >/dev/null 2>&1 \
        || return 1
    sudo /bin/launchctl kickstart -k "$helper_target" \
        || return 1
    for ((service_poll = 1; service_poll <= 30; service_poll++)); do
        if sudo /bin/launchctl print "$runner_target" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    if ! sudo /bin/launchctl print "$runner_target" >/dev/null 2>&1; then
        log_event error launchd_service_start_timeout \
            "runner_target=$runner_target polls=30 timeout_seconds=30"
        return 1
    fi
    log_event info launchd_service_visible \
        "runner_target=$runner_target polls=$service_poll timeout_seconds=30"
    ensure_runner_user_domain || return 1
    verify_runner_domain_security_session || return 1
    log_event info launchd_service_start_completed \
        "helper_target=$helper_target runner_target=$runner_target"
}

start_runner_service_files() {
    validate_installed_runner_service_files
    start_installed_runner_service_files
}

runner_listener_pid() {
    sudo /usr/bin/pgrep -u "$runner_uid" \
        -f "^$runner_dir/bin/Runner.Listener run" 2>/dev/null \
        | /usr/bin/head -1
}

wait_for_all_runner_listeners_exit() {
    for ((listener_poll = 1; listener_poll <= 30; listener_poll++)); do
        if [[ -z "$(runner_listener_pid || true)" ]]; then
            log_event info listener_set_empty \
                "polls=$listener_poll timeout_seconds=30"
            return 0
        fi
        sleep 1
    done
    log_event error listener_set_exit_timeout "polls=30 timeout_seconds=30"
    return 1
}

wait_for_listener_exit() {
    local previous_pid="$1"
    [[ -n "$previous_pid" ]] || return 0
    for ((listener_poll = 1; listener_poll <= 30; listener_poll++)); do
        if ! sudo /bin/kill -0 "$previous_pid" >/dev/null 2>&1; then
            log_event info prior_listener_exited \
                "pid=$previous_pid polls=$listener_poll timeout_seconds=30"
            return 0
        fi
        sleep 1
    done
    log_event error prior_listener_exit_timeout \
        "pid=$previous_pid polls=30 timeout_seconds=30"
    return 1
}

wait_for_new_runner_listener() {
    local previous_pid="$1" listener_pid=""
    for ((listener_poll = 1; listener_poll <= 30; listener_poll++)); do
        listener_pid="$(runner_listener_pid || true)"
        if [[ -n "$listener_pid" && "$listener_pid" != "$previous_pid" ]]; then
            log_event info new_listener_observed \
                "pid=$listener_pid previous_pid=${previous_pid:-none} polls=$listener_poll timeout_seconds=30"
            return 0
        fi
        sleep 1
    done
    log_event error new_listener_timeout \
        "previous_pid=${previous_pid:-none} polls=30 timeout_seconds=30"
    return 1
}

wait_for_runner_online() {
    runner_summary=""
    for ((runner_poll = 1; runner_poll <= 60; runner_poll++)); do
        runner_summary="$(
            "$gh_executable" api "repos/$repository/actions/runners?per_page=100" \
                --jq ".runners[]
                    | select(.name == \"$runner_name\")
                    | select(.status == \"online\")
                    | select([.labels[].name] | index(\"$runner_label\"))
                    | {status, busy, labels: [.labels[].name]}"
        )"
        if [[ -n "$runner_summary" ]]; then
            log_event info remote_runner_online \
                "runner_name=$runner_name polls=$runner_poll timeout_seconds=60"
            return 0
        fi
        sleep 1
    done
    log_event error remote_runner_online_timeout \
        "runner_name=$runner_name polls=60 timeout_seconds=60"
    return 1
}

read_remote_runner_observation() {
    local observation observed_busy observed_labeled observed_status
    observation="$(
        "$gh_executable" api \
            "repos/$repository/actions/runners/$repair_runner_id" \
            --jq "[.busy, .status, ([.labels[].name] | index(\"$runner_label\") != null)] | @tsv"
    )" || return 1
    IFS=$'\t' read -r observed_busy observed_status observed_labeled <<< "$observation"
    case "$observed_busy" in true | false) ;; *) return 1 ;; esac
    case "$observed_status" in online | offline) ;; *) return 1 ;; esac
    case "$observed_labeled" in true | false) ;; *) return 1 ;; esac
    remote_runner_busy="$observed_busy"
    remote_runner_status="$observed_status"
    remote_runner_release_labeled="$observed_labeled"
}

wait_for_remote_runner_status() {
    local expected_status="$1"
    for ((runner_poll = 1; runner_poll <= 60; runner_poll++)); do
        if read_remote_runner_observation 2>/dev/null \
            && [[ "$remote_runner_status" == "$expected_status" ]]; then
            log_event info remote_runner_status_converged \
                "runner_id=$repair_runner_id expected_status=$expected_status observed_status=$remote_runner_status busy=$remote_runner_busy labeled=$remote_runner_release_labeled polls=$runner_poll timeout_seconds=60"
            return 0
        fi
        sleep 1
    done
    log_event error remote_runner_status_timeout \
        "runner_id=$repair_runner_id expected_status=$expected_status observed_status=${remote_runner_status:-unavailable} busy=${remote_runner_busy:-unavailable} labeled=${remote_runner_release_labeled:-unavailable} polls=60 timeout_seconds=60"
    return 1
}

fence_remote_runner() {
    read_remote_runner_observation || return 1
    log_event info remote_runner_fence_started \
        "runner_id=$repair_runner_id status=$remote_runner_status busy=$remote_runner_busy labeled=$remote_runner_release_labeled"
    [[ "$remote_runner_busy" == "false" ]] \
        || return 1
    if [[ "$remote_runner_release_labeled" == "true" ]]; then
        "$gh_executable" api --method DELETE \
            "repos/$repository/actions/runners/$repair_runner_id/labels/$runner_label" \
            >/dev/null \
            || return 1
    fi
    local idle_observations=0
    for ((runner_poll = 1; runner_poll <= 15; runner_poll++)); do
        if read_remote_runner_observation \
            && [[ "$remote_runner_release_labeled" == "false" \
                && "$remote_runner_busy" == "false" ]]; then
            idle_observations=$((idle_observations + 1))
            if (( idle_observations >= 2 )); then
                log_event info remote_runner_fenced \
                    "runner_id=$repair_runner_id status=$remote_runner_status busy=$remote_runner_busy labeled=$remote_runner_release_labeled polls=$runner_poll idle_observations=$idle_observations"
                return 0
            fi
        else
            idle_observations=0
        fi
        sleep 1
    done
    # No launchd state has changed yet. Best-effort reopening is safe even if a
    # job won the narrow pre-fence race; failure leaves scheduling closed.
    restore_remote_runner_label >/dev/null 2>&1 || true
    log_event error remote_runner_fence_timeout \
        "runner_id=$repair_runner_id observed_status=${remote_runner_status:-unavailable} busy=${remote_runner_busy:-unavailable} labeled=${remote_runner_release_labeled:-unavailable} polls=15"
    return 1
}

restore_remote_runner_label() {
    read_remote_runner_observation || return 1
    log_event info remote_runner_unfence_started \
        "runner_id=$repair_runner_id status=$remote_runner_status busy=$remote_runner_busy labeled=$remote_runner_release_labeled"
    if [[ "$remote_runner_release_labeled" == "false" ]]; then
        "$gh_executable" api --method POST \
            "repos/$repository/actions/runners/$repair_runner_id/labels" \
            -f "labels[]=$runner_label" >/dev/null \
            || return 1
    fi
    read_remote_runner_observation || return 1
    [[ "$remote_runner_release_labeled" == "true" ]] || return 1
    runner_summary="$(
        "$gh_executable" api \
            "repos/$repository/actions/runners/$repair_runner_id" \
            --jq '{status, busy, labels: [.labels[].name]}'
    )"
    log_event info remote_runner_unfenced \
        "runner_id=$repair_runner_id status=$remote_runner_status busy=$remote_runner_busy labeled=$remote_runner_release_labeled"
}

acquire_bootstrap_lock() {
    sudo /usr/bin/shlock -f "$runner_bootstrap_lock" -p "$$" \
        || return 1
    bootstrap_lock_held=true
}

rollback_to_legacy_service() {
    log_event warning legacy_rollback_started \
        "runner_id=${repair_runner_id:-unavailable}"
    stop_runner_candidate_services || return 1
    stop_launchd_target "system/$runner_service_label" || return 1
    wait_for_all_runner_listeners_exit || return 1
    wait_for_remote_runner_status offline || return 1
    remove_runner_service_files || return 1

    if sudo /bin/test -e "$legacy_runner_service_backup" \
        || sudo /bin/test -L "$legacy_runner_service_backup"; then
        legacy_runner_service_is_valid "$legacy_runner_service_backup" || return 1
        if sudo /bin/test -e "$legacy_runner_service_plist" \
            || sudo /bin/test -L "$legacy_runner_service_plist"; then
            return 1
        fi
        sudo /bin/mv "$legacy_runner_service_backup" "$legacy_runner_service_plist" \
            || return 1
    fi
    legacy_runner_service_is_valid "$legacy_runner_service_plist" || return 1
    sudo /bin/launchctl bootstrap system "$legacy_runner_service_plist" \
        || return 1
    sudo /bin/launchctl kickstart -k "system/$runner_service_label" \
        || return 1
    wait_for_new_runner_listener "" || return 1
    wait_for_remote_runner_status online || return 1
    restore_remote_runner_label || return 1
    repair_migration_active=false
    log_event warning legacy_rollback_service_restored \
        "runner_id=${repair_runner_id:-unavailable}"
}

prepare_runner_security_context() {
    local baseline_password baseline_keychain runner_keychains runner_library runner_logs runner_path
    runner_library="$runner_home/Library"
    runner_keychains="$runner_library/Keychains"
    for runner_path in "$runner_library" "$runner_keychains"; do
        if sudo /bin/test -L "$runner_path"; then
            die "release runner Library paths must not be symlinks"
        fi
    done
    # Never use root to mutate descendants of the runner-owned home. BSD
    # `install -d` follows a directory symlink, so the isolated account creates
    # and modes its own paths while root performs read-only validation.
    run_as_runner /usr/bin/install -d -m 700 \
        "$runner_library" "$runner_keychains"
    validate_private_runner_directory "$runner_library"
    validate_private_runner_directory "$runner_keychains"
    runner_logs="$runner_library/Logs/$runner_service_label"
    if sudo /bin/test -L "$runner_logs"; then
        die "release runner log directory must not be a symlink"
    fi
    run_as_runner /usr/bin/install -d -m 700 "$runner_logs"
    validate_private_runner_directory "$runner_logs"
    ensure_runner_user_domain \
        || die "could not establish the release account's Background domain"
    verify_runner_domain_security_session \
        || die "release account Background domain has a mixed audit identity"

    baseline_keychain="$runner_keychains/tron-runner-baseline.keychain-db"
    if sudo /bin/test -L "$baseline_keychain"; then
        die "release runner baseline keychain must not be a symlink"
    fi
    if ! sudo /bin/test -e "$baseline_keychain"; then
        baseline_password="$(openssl rand -hex 32)"
        run_in_runner_domain /usr/bin/security create-keychain \
            -p "$baseline_password" "$baseline_keychain"
        unset baseline_password
    fi
    sudo /bin/test -f "$baseline_keychain" \
        || die "release runner baseline keychain is not a regular file"
    [[ "$(sudo /usr/bin/stat -f '%Su' "$baseline_keychain")" == "$runner_user" ]] \
        || die "release runner baseline keychain has the wrong owner"
    [[ "$(sudo /usr/bin/stat -f '%l' "$baseline_keychain")" == "1" ]] \
        || die "release runner baseline keychain must not have hard links"
    run_as_runner /bin/chmod 600 "$baseline_keychain"
    [[ "$(sudo /usr/bin/stat -f '%Su:%Sg:%Lp:%l' "$baseline_keychain")" == "$runner_user:staff:600:1" ]] \
        || die "release runner baseline keychain metadata is inconsistent"

    run_in_runner_domain /usr/bin/env \
        DEVELOPER_DIR="$TRON_RELEASE_IOS_DEVELOPER_DIR" \
        /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null \
        || die "the release account cannot use the pinned Xcode installation"
}

validate_existing_background_service() {
    local listener_pid
    start_runner_service_files || return 1
    listener_pid="$(runner_listener_pid || true)"
    [[ -n "$listener_pid" ]] || return 1
    log_event info guarded_listener_observed \
        "pid=$listener_pid entrypoint=$runner_session_entrypoint"
    if [[ -n "$repair_runner_id" ]]; then
        wait_for_remote_runner_status online
    else
        wait_for_runner_online
    fi
}

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
    || die "the iOS release runner requires an Apple-silicon Mac"
runner_registration_started=false
bootstrap_complete=false
runner_plist_staging=""
runner_legacy_plist_staging=""
runner_bootstrap_plist_staging=""
runner_legacy_bootstrap_plist_staging=""
archive=""
bootstrap_lock_held=false
repair_migration_active=false
background_service_upgrade_active=false
repair_runner_id=""
repair_previous_listener_pid=""
remote_runner_busy=""
remote_runner_release_labeled=""
remote_runner_status=""
existing_runner_directory_mode=""
existing_runner_directory_state=""
repository=""

cleanup_bootstrap() {
    local exit_status=$?
    local cleanup_incomplete=false
    local removal_token="" remaining_runner_id="" runner_id=""
    trap - EXIT
    trap - ERR
    set +e
    log_event info cleanup_started \
        "exit_status=$exit_status migration_active=$repair_migration_active background_upgrade_active=$background_service_upgrade_active registration_started=$runner_registration_started bootstrap_complete=$bootstrap_complete"
    if [[ -n "$archive" ]]; then
        /bin/rm -f "$archive"
    fi
    if (( exit_status != 0 )) && [[ "$repair_migration_active" == "true" ]]; then
        if rollback_to_legacy_service; then
            log_event warning legacy_rollback_completed \
                "runner_id=${repair_runner_id:-unavailable}"
        else
            cleanup_incomplete=true
            log_event error legacy_rollback_failed \
                "runner_id=${repair_runner_id:-unavailable} scheduling=fenced"
        fi
    fi
    if (( exit_status != 0 )) && [[ "$background_service_upgrade_active" == "true" ]]; then
        if rollback_background_service_upgrade; then
            log_event warning background_upgrade_recovered \
                "runner_id=${repair_runner_id:-unavailable}"
        else
            cleanup_incomplete=true
            log_event error background_upgrade_rollback_failed \
                "runner_id=${repair_runner_id:-unavailable} scheduling=fenced"
        fi
    fi
    if (( exit_status != 0 )) \
        && [[ "$bootstrap_complete" != "true" && "$runner_registration_started" == "true" ]]; then
        # Registration and service installation form one transaction. Neither
        # remote credentials nor a launchd job may survive a failed bootstrap.
        if ! remove_runner_service_files; then
            cleanup_incomplete=true
        fi
        runner_id="$(
            "$gh_executable" api "repos/$repository/actions/runners" \
                --jq ".runners[] | select(.name == \"$runner_name\") | .id" 2>/dev/null
        )"
        if sudo /bin/test -f "$runner_dir/.runner"; then
            removal_token="$(
                "$gh_executable" api --method POST \
                    "repos/$repository/actions/runners/remove-token" --jq .token 2>/dev/null
            )"
            if [[ -n "$removal_token" ]]; then
                run_as_runner "$runner_dir/config.sh" remove \
                    --token "$removal_token" >/dev/null 2>&1
            fi
        fi
        if [[ -n "$runner_id" ]]; then
            "$gh_executable" api --method DELETE \
                "repos/$repository/actions/runners/$runner_id" >/dev/null 2>&1
        fi
        run_as_runner /bin/rm -f \
            "$runner_dir/.runner" \
            "$runner_dir/.credentials" \
            "$runner_dir/.credentials_rsaparams"

        if sudo launchctl print "user/$runner_uid/$runner_service_label" >/dev/null 2>&1 \
            || sudo launchctl print "system/$runner_bootstrap_label" >/dev/null 2>&1 \
            || sudo /bin/test -e "$runner_service_plist" \
            || sudo /bin/test -e "$runner_bootstrap_plist" \
            || sudo /bin/test -e "$runner_bootstrap_helper" \
            || sudo /bin/test -e "$runner_session_entrypoint" \
            || sudo /bin/test -e "$runner_dir/.runner" \
            || sudo /bin/test -e "$runner_dir/.credentials"; then
            cleanup_incomplete=true
        fi
        if ! remaining_runner_id="$(
            "$gh_executable" api "repos/$repository/actions/runners" \
                --jq ".runners[] | select(.name == \"$runner_name\") | .id" 2>/dev/null
        )"; then
            cleanup_incomplete=true
        elif [[ -n "$remaining_runner_id" ]]; then
            cleanup_incomplete=true
        fi
        if [[ "$cleanup_incomplete" == "true" ]]; then
            log_event error registration_rollback_incomplete \
                "message=incomplete runner bootstrap rollback; follow the rotation runbook before retrying remote_registration_remaining=unknown"
        else
            log_event warning registration_rollback_completed \
                "remote_registration_remaining=false"
        fi
    fi
    if [[ -n "$runner_plist_staging" ]]; then
        /bin/rm -f "$runner_plist_staging"
    fi
    if [[ -n "$runner_legacy_plist_staging" ]]; then
        /bin/rm -f "$runner_legacy_plist_staging"
    fi
    if [[ -n "$runner_bootstrap_plist_staging" ]]; then
        /bin/rm -f "$runner_bootstrap_plist_staging"
    fi
    if [[ -n "$runner_legacy_bootstrap_plist_staging" ]]; then
        /bin/rm -f "$runner_legacy_bootstrap_plist_staging"
    fi
    if [[ "$cleanup_incomplete" == "true" ]]; then
        log_event error bootstrap_finished \
            "exit_status=1 cleanup_incomplete=true scheduling=fenced"
        if [[ "$bootstrap_lock_held" == "true" ]]; then
            sudo /bin/rm -f "$runner_bootstrap_lock"
        fi
        exit 1
    fi
    log_event info bootstrap_finished \
        "exit_status=$exit_status cleanup_incomplete=false bootstrap_complete=$bootstrap_complete"
    if [[ "$bootstrap_lock_held" == "true" ]]; then
        sudo /bin/rm -f "$runner_bootstrap_lock"
    fi
    exit "$exit_status"
}
trap cleanup_bootstrap EXIT

initialize_bootstrap_logging
trap 'record_unhandled_error "$?" "$LINENO"' ERR
bootstrap_phase=provenance
bootstrap_source_sha256="$(/usr/bin/shasum -a 256 "$project_dir/scripts/bootstrap-ios-release-runner.sh" | /usr/bin/awk '{print $1}')"
toolchain_source_sha256="$(/usr/bin/shasum -a 256 "$project_dir/config/ci-toolchain.env" | /usr/bin/awk '{print $1}')"
release_workflow_sha256="$(/usr/bin/shasum -a 256 "$project_dir/.github/workflows/release-ios.yml" | /usr/bin/awk '{print $1}')"
git_head="$(/usr/bin/git -C "$project_dir" rev-parse HEAD 2>/dev/null || true)"
git_dirty=false
if [[ -n "$(/usr/bin/git -C "$project_dir" status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
    git_dirty=true
fi
log_event info bootstrap_started \
    "mode=$bootstrap_mode pid=$$ git_head=${git_head:-unavailable} git_dirty=$git_dirty bootstrap_sha256=$bootstrap_source_sha256 toolchain_sha256=$toolchain_source_sha256 release_workflow_sha256=$release_workflow_sha256 runner_version=$TRON_RELEASE_RUNNER_VERSION xcode_build=$TRON_RELEASE_IOS_XCODE_BUILD ios_sdk=$TRON_RELEASE_IOS_SDK_VERSION"
bootstrap_phase=lock
acquire_bootstrap_lock \
    || die "another release runner bootstrap or service repair is already active"
log_event info bootstrap_lock_acquired "lock=$runner_bootstrap_lock"

bootstrap_phase=github_preflight
"$gh_executable" auth status >/dev/null \
    || die "authenticate GitHub CLI before bootstrapping"
repository="$("$gh_executable" repo view --json nameWithOwner --jq .nameWithOwner)"
[[ -n "$repository" ]] || die "could not resolve the current GitHub repository"
"$gh_executable" api "repos/$repository/environments/ios-testflight" >/dev/null \
    || die "create the ios-testflight GitHub environment before bootstrapping"
log_event info github_control_plane_ready "environment=ios-testflight"

if [[ "$bootstrap_mode" == "install" ]]; then
    bootstrap_phase=runner_archive_download
    archive="$(mktemp -t tron-actions-runner.XXXXXX.tar.gz)"
    curl --fail --location --silent --show-error "$TRON_RELEASE_RUNNER_URL" --output "$archive"
    actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual_sha" == "$TRON_RELEASE_RUNNER_SHA256" ]] \
        || die "GitHub runner archive checksum mismatch"
fi

bootstrap_phase=runner_account_preparation
if ! dscl . -read "/Users/$runner_user" >/dev/null 2>&1; then
    [[ "$bootstrap_mode" == "install" ]] \
        || die "the release runner account is missing; repair cannot recreate it"
    service_password="$(openssl rand -hex 32)"
    sudo sysadminctl -addUser "$runner_user" \
        -fullName "Tron iOS Release Runner" \
        -password "$service_password" \
        -home "$runner_home" \
        -shell /bin/zsh >/dev/null
    unset service_password
fi
sudo dscl . create "/Users/$runner_user" IsHidden 1

runner_uid="$(id -u "$runner_user")"
(( runner_uid >= 500 )) || die "release runner account is not a standard macOS user"
runner_primary_group="$(id -gn "$runner_user")"
[[ "$runner_primary_group" == "staff" ]] \
    || die "release runner account must use the staff primary group"
recorded_runner_home="$(
    dscl . -read "/Users/$runner_user" NFSHomeDirectory | awk '{print $2}'
)"
[[ "$recorded_runner_home" == "$runner_home" ]] \
    || die "release runner account home is '$recorded_runner_home', expected '$runner_home'"
if dseditgroup -o checkmember -m "$runner_user" admin | grep -q 'yes'; then
    sudo dseditgroup -o edit -d "$runner_user" -t user admin
fi
if dseditgroup -o checkmember -m "$runner_user" admin | grep -q 'yes'; then
    die "release runner account must not be an administrator"
fi

# `sysadminctl` records an explicitly assigned home but does not necessarily
# create it. Repair that normal interrupted-bootstrap state without weakening
# path ownership or following a pre-existing symlink.
[[ ! -L "$runner_home" ]] || die "release runner home must not be a symlink"
[[ ! -e "$runner_home" || -d "$runner_home" ]] \
    || die "release runner home exists but is not a directory"
if [[ ! -e "$runner_home" ]]; then
    validate_privileged_directory /Users
    # The account cannot create a sibling below root-owned /Users, so creation
    # of this previously absent exact path has no user-controlled race.
    sudo /usr/bin/install -d -m 700 -o "$runner_user" -g staff "$runner_home"
fi
validate_private_runner_directory "$runner_home"
log_event info runner_account_validated \
    "uid=$runner_uid primary_group=$runner_primary_group home_mode=700 admin=false"

invoking_user="${SUDO_USER:-${USER:-}}"
[[ -n "$invoking_user" && "$invoking_user" != "root" && "$invoking_user" != "$runner_user" ]] \
    || die "run the bootstrap from a non-root administrator account"
invoking_uid="$(id -u "$invoking_user")"
(( invoking_uid >= 500 )) || die "invoking account is not a standard macOS user"
invoking_home="$(dscl . -read "/Users/$invoking_user" NFSHomeDirectory | awk '{print $2}')"
[[ -n "$invoking_home" && -d "$invoking_home" && ! -L "$invoking_home" ]] \
    || die "could not resolve the invoking user's physical home directory"
[[ "$(/usr/bin/stat -f '%Su' "$invoking_home")" == "$invoking_user" ]] \
    || die "invoking user does not own the resolved home directory"

runner_can_access_invoking_home() {
    run_as_runner /bin/test -r "$invoking_home" \
        || run_as_runner /bin/test -x "$invoking_home"
}

# Standard macOS accounts share the `staff` group, so a mode such as 0750 can
# expose a personal home to another otherwise isolated account. Deny only this
# runner list/search access instead of changing the invoking user's broader
# group permissions.
runner_home_acl="user:$runner_user deny list,search"
bootstrap_phase=invoking_home_isolation
if runner_can_access_invoking_home; then
    sudo /bin/chmod +a "$runner_home_acl" "$invoking_home"
fi
if runner_can_access_invoking_home; then
    die "release runner account can still access the invoking user's home"
fi
log_event info invoking_home_isolation_validated \
    "runner_uid=$runner_uid read_access=false search_access=false"

if [[ "$bootstrap_mode" == "--repair-service" ]]; then
    bootstrap_phase=service_repair
    validate_existing_runner_install
    remote_runner_count="$(
        "$gh_executable" api "repos/$repository/actions/runners?per_page=100" \
            --jq "[.runners[] | select(.name == \"$runner_name\")] | length"
    )"
    [[ "$remote_runner_count" == "1" ]] \
        || die "repair requires exactly one registered $runner_name runner"
    repair_runner_id="$(
        "$gh_executable" api "repos/$repository/actions/runners?per_page=100" \
            --jq ".runners[] | select(.name == \"$runner_name\") | .id"
    )"
    [[ "$repair_runner_id" =~ ^[0-9]+$ ]] \
        || die "repair could not resolve the exact registered runner ID"
    read_remote_runner_observation \
        || die "repair could not read the exact registered runner state"
    log_event info remote_runner_observed \
        "runner_id=$repair_runner_id status=$remote_runner_status busy=$remote_runner_busy labeled=$remote_runner_release_labeled"
    [[ "$remote_runner_busy" == "false" ]] \
        || die "release runner is busy; wait for the active job before repairing its service"
    normalize_existing_runner_directory_mode

    stage_runner_service_files
    candidate_path_count=0
    for candidate_path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper" \
        "$runner_session_entrypoint"; do
        if sudo /bin/test -e "$candidate_path" || sudo /bin/test -L "$candidate_path"; then
            candidate_path_count=$((candidate_path_count + 1))
        fi
    done
    background_backup_exists=false
    if sudo /bin/test -e "$runner_background_backup_dir" \
        || sudo /bin/test -L "$runner_background_backup_dir"; then
        background_backup_exists=true
        validate_background_service_backup
        if (( candidate_path_count == 4 )) && current_runner_service_files_match; then
            # A prior process installed and started the corrected candidate but
            # exited before committing its journal. Health verification below
            # decides whether the journal can be removed.
            :
        elif (( candidate_path_count == 3 )) \
            && legacy_background_runner_service_files_match; then
            remove_background_service_backup \
                || die "could not clear a redundant Background rollback journal"
            background_backup_exists=false
        else
            fence_remote_runner \
                || die "could not fence an interrupted Background service upgrade"
            background_service_upgrade_active=true
            rollback_background_service_upgrade \
                || die "could not recover the interrupted Background service upgrade"
            background_backup_exists=false
            candidate_path_count=3
        fi
    fi
    legacy_path_exists=false
    if sudo /bin/test -e "$legacy_runner_service_plist" \
        || sudo /bin/test -L "$legacy_runner_service_plist"; then
        legacy_path_exists=true
    fi
    legacy_backup_exists=false
    if sudo /bin/test -e "$legacy_runner_service_backup" \
        || sudo /bin/test -L "$legacy_runner_service_backup"; then
        legacy_backup_exists=true
    fi
    runner_service_state="$(
        classify_runner_service_state \
            "$legacy_path_exists" "$legacy_backup_exists" "$candidate_path_count"
    )"
    log_event info service_topology_classified \
        "state=$runner_service_state candidate_files=$candidate_path_count legacy_path=$legacy_path_exists legacy_journal=$legacy_backup_exists background_journal=$background_backup_exists"
    [[ "$runner_service_state" != "invalid" ]] \
        || die "release runner repair found an ambiguous or incomplete service topology"

    if [[ "$runner_service_state" == "current" ]]; then
        sudo /bin/launchctl print "system/$runner_service_label" >/dev/null 2>&1 \
            && die "legacy release runner is loaded without its immutable plist"
        [[ "$candidate_path_count" == "3" || "$candidate_path_count" == "4" ]] \
            || die "release runner repair found neither a complete legacy nor Background service"
        if current_runner_service_files_match; then
            log_event info current_service_validation_started \
                "candidate_files=$candidate_path_count background_journal=$background_backup_exists"
            validate_installed_runner_service_files
            prepare_runner_security_context
            validate_existing_background_service \
                || die "existing Background release runner service is not healthy"
            if [[ "$background_backup_exists" == "true" ]]; then
                remove_background_service_backup \
                    || die "verified Background runner still has an uncommitted rollback journal"
                background_backup_exists=false
            fi
            restore_remote_runner_label \
                || die "Background release runner is healthy but its scheduling label could not be restored"
            bootstrap_complete=true
            log_event info current_service_validated \
                "runner_id=$repair_runner_id status=$remote_runner_status labeled=$remote_runner_release_labeled"
            echo "$runner_summary"
            echo "Release runner already uses the verified Background service topology."
            exit 0
        fi

        validate_legacy_background_runner_service_files
        bootstrap_phase=background_service_upgrade
        log_event info background_upgrade_started \
            "runner_id=$repair_runner_id prior_contract=session-create"
        prepare_runner_security_context
        if ! create_background_service_backup; then
            remove_background_service_backup >/dev/null 2>&1 || true
            die "could not journal the prior Background runner service"
        fi
        if ! fence_remote_runner; then
            remove_background_service_backup >/dev/null 2>&1 || true
            die "release runner could not be fenced idle for audit-session repair"
        fi
        background_service_upgrade_active=true
        repair_previous_listener_pid="$(runner_listener_pid || true)"
        remove_runner_service_files \
            || die "could not stop the prior Background runner service"
        wait_for_listener_exit "$repair_previous_listener_pid" \
            || die "prior Background runner listener did not stop"
        wait_for_all_runner_listeners_exit \
            || die "a Background runner listener remained during audit-session repair"
        wait_for_remote_runner_status offline \
            || die "GitHub did not observe the prior Background runner transition offline"
        install_runner_service_files \
            || die "could not install the corrected Background runner service"
        start_runner_service_files \
            || die "could not start the corrected Background runner service"
        wait_for_new_runner_listener "$repair_previous_listener_pid" \
            || die "corrected Background runner did not pass its fail-closed session entry point"
        wait_for_remote_runner_status online \
            || die "GitHub did not observe the corrected Background runner transition online"
        remove_background_service_backup \
            || die "corrected Background runner is healthy but its rollback journal remains"
        background_service_upgrade_active=false
        restore_remote_runner_label \
            || die "corrected Background runner is healthy but its scheduling label remains fenced"
        bootstrap_complete=true
        log_event info background_upgrade_committed \
            "runner_id=$repair_runner_id status=$remote_runner_status labeled=$remote_runner_release_labeled"
        echo "$runner_summary"
        echo "Release runner upgraded transactionally to inherit its Background audit session."
        exit 0
    fi

    fence_remote_runner \
        || die "release runner could not be fenced idle for service repair"
    repair_migration_active=true
    bootstrap_phase=legacy_service_migration
    log_event info legacy_migration_started \
        "runner_id=$repair_runner_id service_state=$runner_service_state"
    ensure_privileged_support_directory \
        || die "could not establish the root-owned release runner support directory"

    if [[ "$runner_service_state" == "legacy" ]]; then
        validate_legacy_runner_service "$legacy_runner_service_plist"
        if (( candidate_path_count != 0 )) \
            || sudo /bin/launchctl print "user/$runner_uid/$runner_service_label" >/dev/null 2>&1 \
            || sudo /bin/launchctl print "system/$runner_bootstrap_label" >/dev/null 2>&1; then
            remove_runner_service_files \
                || die "could not clear an interrupted Background candidate"
        fi
        if sudo /bin/test -e "$legacy_runner_service_backup" \
            || sudo /bin/test -L "$legacy_runner_service_backup"; then
            die "legacy rollback journal already exists"
        fi
        sudo /bin/mv "$legacy_runner_service_plist" "$legacy_runner_service_backup" \
            || die "could not persist the legacy release runner rollback journal"
        validate_legacy_runner_service "$legacy_runner_service_backup"
    else
        validate_legacy_runner_service "$legacy_runner_service_backup"
        remove_runner_service_files \
            || die "could not clear the interrupted Background candidate"
    fi

    repair_previous_listener_pid="$(runner_listener_pid || true)"
    stop_launchd_target "system/$runner_service_label" \
        || die "could not stop the legacy release runner listener"
    wait_for_all_runner_listeners_exit \
        || die "legacy release runner listener did not stop"
    wait_for_remote_runner_status offline \
        || die "GitHub did not observe the exact legacy runner transition offline"

    prepare_runner_security_context
    install_runner_service_files \
        || die "could not install the Background release runner service"
    start_runner_service_files \
        || die "could not start the Background release runner service"
    wait_for_new_runner_listener "$repair_previous_listener_pid" \
        || die "Background release runner did not pass its fail-closed session entry point"
    wait_for_remote_runner_status online \
        || die "GitHub did not observe the exact Background runner transition online"
    validate_legacy_runner_service "$legacy_runner_service_backup"
    # The verified candidate is now the committed topology. From this point on,
    # cleanup must leave it running and scheduling fenced rather than attempt a
    # rollback whose journal may already have been removed.
    repair_migration_active=false
    sudo /bin/rm -f "$legacy_runner_service_backup" \
        || die "Background runner committed but its legacy rollback journal could not be removed; scheduling remains fenced"
    if sudo /bin/test -e "$legacy_runner_service_backup" \
        || sudo /bin/test -L "$legacy_runner_service_backup"; then
        die "Background runner committed but its legacy rollback journal remains; scheduling remains fenced"
    fi
    restore_remote_runner_label \
        || die "Background release runner is online but its scheduling label remains fenced"
    bootstrap_complete=true
    log_event info legacy_migration_committed \
        "runner_id=$repair_runner_id status=$remote_runner_status labeled=$remote_runner_release_labeled"
    echo "$runner_summary"
    echo "Release runner migrated transactionally to its Background user domain."
    exit 0
fi

bootstrap_phase=fresh_install
prepare_runner_security_context
log_event info fresh_install_started "runner_version=$TRON_RELEASE_RUNNER_VERSION"
validate_privileged_install_roots
for service_target in \
    "system/$runner_service_label" \
    "user/$runner_uid/$runner_service_label" \
    "system/$runner_bootstrap_label"; do
    sudo /bin/launchctl print "$service_target" >/dev/null 2>&1 \
        && die "release runner launchd target already exists: $service_target"
done
for service_path in \
    "$legacy_runner_service_plist" \
    "$legacy_runner_service_backup" \
    "$runner_service_plist" \
    "$runner_bootstrap_plist" \
    "$runner_bootstrap_helper" \
    "$runner_session_entrypoint" \
    "$runner_background_backup_dir"; do
    if sudo /bin/test -e "$service_path" || sudo /bin/test -L "$service_path"; then
        die "release runner service path already exists: $service_path"
    fi
done
existing_runner_id="$(
    "$gh_executable" api "repos/$repository/actions/runners?per_page=100" \
        --jq ".runners[] | select(.name == \"$runner_name\") | .id"
)"
[[ -z "$existing_runner_id" ]] \
    || die "GitHub already has a runner named $runner_name; use the documented rotation flow"

if sudo /bin/test -L "$runner_dir"; then
    die "release runner installation must not be a symlink"
fi
if sudo /bin/test -e "$runner_dir/.runner"; then
    die "a runner is already configured at $runner_dir; rotate it through the documented runbook"
fi
run_as_runner /usr/bin/install -d -m 700 "$runner_dir"
validate_private_runner_directory "$runner_dir"
# Stream the checksum-verified archive to tar running as the isolated account.
# Root never follows or rewrites paths below the runner-owned home.
run_as_runner /usr/bin/tar -xzf - -C "$runner_dir" < "$archive"
# The archive owns executable modes below this directory, but its root `./`
# entry must never broaden the service installation itself. Reassert the
# private boundary explicitly so tar implementation or privilege differences
# cannot recreate the legacy 0755 state.
run_as_runner /bin/chmod 700 "$runner_dir"
validate_private_runner_directory "$runner_dir"
for runner_executable in "$runner_dir/config.sh" "$runner_dir/bin/runsvc.sh"; do
    sudo /bin/test -f "$runner_executable" \
        || die "verified runner archive is missing $(basename "$runner_executable")"
    sudo /bin/test -x "$runner_executable" \
        || die "verified runner archive contains a non-executable $(basename "$runner_executable")"
    if sudo /bin/test -L "$runner_executable"; then
        die "verified runner executable must not be a symlink: $runner_executable"
    fi
done
registration_token="$(
    "$gh_executable" api --method POST \
        "repos/$repository/actions/runners/registration-token" --jq .token
)"
[[ -n "$registration_token" ]] || die "could not obtain a repository runner token"
runner_registration_started=true
run_as_runner "$runner_dir/config.sh" \
    --url "https://github.com/$repository" \
    --token "$registration_token" \
    --name "$runner_name" \
    --labels "$runner_label" \
    --work "_work" \
    --unattended \
    --disableupdate
unset registration_token

for generated_runner_file in \
    "$runner_dir/.runner" \
    "$runner_dir/.credentials"; do
    sudo /bin/test -f "$generated_runner_file" \
        || die "runner configuration did not generate $(basename "$generated_runner_file")"
    if sudo /bin/test -L "$generated_runner_file"; then
        die "runner configuration generated an unsafe symlink: $generated_runner_file"
    fi
done

# GitHub's `svc.sh` assumes a logged-in Aqua session. Tron owns the equivalent
# headless Background LaunchAgent and a root-only boot helper that recreates the
# hidden account's user domain after every reboot.
run_as_runner /usr/bin/install -m 755 \
    "$runner_dir/bin/runsvc.sh" "$runner_dir/runsvc.sh"

stage_runner_service_files
install_runner_service_files \
    || die "could not install the Background release runner service"
start_runner_service_files \
    || die "could not start the Background release runner service"
wait_for_new_runner_listener "" \
    || die "Background release runner did not pass its fail-closed session entry point"
wait_for_runner_online \
    || die "release runner did not become online with its dedicated label"
sudo /usr/bin/pmset -c sleep 0
sudo /usr/bin/pmset -a tcpkeepalive 1
bootstrap_complete=true
log_event info fresh_install_committed \
    "runner_name=$runner_name remote_status=online labeled=true"
echo "$runner_summary"
echo "Release runner installed. Confirm ios-testflight environment secrets before enabling delivery."
