#!/usr/bin/env bash
set -euo pipefail

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
runner_bootstrap_lock="/var/run/tron-ios-release-runner-bootstrap.lock"

die() {
    echo "error: $*" >&2
    exit 1
}

gh_executable="$(command -v gh || true)"
# This macOS-only bootstrap relies on BSD utility flags. Do not let Homebrew
# coreutils or another interactive-shell PATH change their semantics.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

configure_runner_service_plist() {
    local plist="$1"
    /bin/rm -f "$plist"
    /usr/bin/plutil -create xml1 "$plist"
    /usr/libexec/PlistBuddy -c "Add :Label string $runner_service_label" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $runner_dir/runsvc.sh" "$plist"
    /usr/libexec/PlistBuddy -c "Add :WorkingDirectory string $runner_dir" "$plist"
    /usr/libexec/PlistBuddy -c "Add :StandardOutPath string $runner_home/Library/Logs/$runner_service_label/stdout.log" "$plist"
    /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $runner_home/Library/Logs/$runner_service_label/stderr.log" "$plist"
    /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SessionCreate bool true" "$plist"
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
}

classify_runner_service_state() {
    local legacy_exists="$1" backup_exists="$2" candidate_count="$3"
    if [[ "$legacy_exists" == "true" && "$backup_exists" == "true" ]]; then
        echo invalid
    elif [[ "$legacy_exists" == "true" ]]; then
        echo legacy
    elif [[ "$backup_exists" == "true" ]]; then
        echo journaled
    elif [[ "$candidate_count" == "3" ]]; then
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
    local acl_entry acl_listing acl_probe acl_tail bootstrap_plist_probe plist_probe
    acl_probe="$(mktemp -d -t tron-runner-acl)"
    plist_probe="$(mktemp -t tron-runner-agent.plist)"
    bootstrap_plist_probe="$(mktemp -t tron-runner-bootstrap.plist)"
    trap '/bin/chmod -N "$acl_probe" >/dev/null 2>&1 || true; /bin/rmdir "$acl_probe" >/dev/null 2>&1 || true; /bin/rm -f "$plist_probe" "$bootstrap_plist_probe"' EXIT
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
    ! plutil -extract UserName raw -o - "$plist_probe" >/dev/null 2>&1 \
        || die "release runner agent must inherit its user-domain identity"
    ! plutil -extract GroupName raw -o - "$plist_probe" >/dev/null 2>&1 \
        || die "release runner agent must inherit its user-domain group"
    [[ "$(plutil -extract SessionCreate raw -o - "$plist_probe")" == "true" ]] \
        || die "release runner agent must create a non-root security audit session"

    configure_runner_bootstrap_plist "$bootstrap_plist_probe" 502
    plutil -lint "$bootstrap_plist_probe" >/dev/null
    [[ "$(plutil -extract ProgramArguments.1 raw -o - "$bootstrap_plist_probe")" == "$runner_user" ]] \
        || die "release runner bootstrap daemon has the wrong account"
    [[ "$(plutil -extract ProgramArguments.2 raw -o - "$bootstrap_plist_probe")" == "502" ]] \
        || die "release runner bootstrap daemon has the wrong UID"
    [[ "$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$bootstrap_plist_probe")" == "false" ]] \
        || die "release runner bootstrap daemon must retry only after failure"
    [[ "$(classify_runner_service_state true false 0)" == "legacy" ]] \
        || die "release runner migration state machine rejected the legacy state"
    [[ "$(classify_runner_service_state false true 2)" == "journaled" ]] \
        || die "release runner migration state machine rejected an interrupted candidate"
    [[ "$(classify_runner_service_state false false 3)" == "current" ]] \
        || die "release runner migration state machine rejected the current topology"
    [[ "$(classify_runner_service_state true true 3)" == "invalid" \
        && "$(classify_runner_service_state false false 1)" == "invalid" ]] \
        || die "release runner migration state machine accepted an ambiguous topology"
    [[ "$(classify_existing_runner_directory_mode 700)" == "private" \
        && "$(classify_existing_runner_directory_mode 755)" == "legacy-archive" ]] \
        || die "release runner mode classifier rejected a supported state"
    [[ "$(classify_existing_runner_directory_mode 750)" == "invalid" \
        && "$(classify_existing_runner_directory_mode 777)" == "invalid" ]] \
        || die "release runner mode classifier accepted an unsupported state"
    /bin/bash -n "$runner_bootstrap_helper_source"
    /bin/rm -f "$plist_probe" "$bootstrap_plist_probe"
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
    # `launchctl asuser` selects a bootstrap and audit context but deliberately
    # does not change Unix credentials. Drop credentials first so every facet
    # of the process identity belongs to the isolated account.
    cd /
    exec sudo -H -u "$runner_user" \
        /bin/launchctl asuser "$runner_uid" "$@"
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
    if ! sudo /bin/launchctl print "user/$runner_uid" >/dev/null 2>&1; then
        sudo /bin/launchctl bootstrap "user/$runner_uid" \
            || sudo /bin/launchctl print "user/$runner_uid" >/dev/null 2>&1 \
            || return 1
    fi
    [[ "$(run_in_runner_domain /bin/launchctl manageruid)" == "$runner_uid" ]] \
        || return 1
    [[ "$(run_in_runner_domain /bin/launchctl managername)" == "Background" ]] \
        || return 1
}

verify_runner_domain_security_session() {
    local identity
    identity="$(
        run_in_runner_domain /usr/bin/python3 -c \
            'import ctypes, os; uid = ctypes.c_uint32(); process = ctypes.CDLL(None, use_errno=True); result = process.getauid(ctypes.byref(uid)); print(f"{os.geteuid()}:{uid.value}" if result == 0 else "error")'
    )"
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
    runner_bootstrap_plist_staging="$(mktemp -t tron-ios-release-bootstrap.plist)"
    configure_runner_service_plist "$runner_plist_staging"
    configure_runner_bootstrap_plist "$runner_bootstrap_plist_staging" "$runner_uid"
    plutil -lint "$runner_plist_staging" >/dev/null
    plutil -lint "$runner_bootstrap_plist_staging" >/dev/null
}

install_runner_service_files() {
    local path
    ensure_privileged_support_directory || return 1
    for path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper"; do
        if sudo /bin/test -e "$path" || sudo /bin/test -L "$path"; then
            echo "error: refusing to replace existing release service path: $path" >&2
            return 1
        fi
    done
    sudo /usr/bin/install -m 755 -o root -g wheel \
        "$runner_bootstrap_helper_source" "$runner_bootstrap_helper" \
        || return 1
    sudo /usr/bin/install -m 644 -o root -g wheel \
        "$runner_plist_staging" "$runner_service_plist" \
        || return 1
    sudo /usr/bin/install -m 600 -o root -g wheel \
        "$runner_bootstrap_plist_staging" "$runner_bootstrap_plist" \
        || return 1
    validate_installed_runner_service_files
}

validate_installed_runner_service_files() {
    validate_privileged_install_roots
    validate_privileged_file "$runner_service_plist" 644
    validate_privileged_file "$runner_bootstrap_plist" 600
    validate_privileged_file "$runner_bootstrap_helper" 755
    sudo /usr/bin/cmp -s "$runner_plist_staging" "$runner_service_plist" \
        || die "installed release runner agent differs from the staged contract"
    sudo /usr/bin/cmp -s "$runner_bootstrap_plist_staging" "$runner_bootstrap_plist" \
        || die "installed release runner bootstrap daemon differs from the staged contract"
    sudo /usr/bin/cmp -s "$runner_bootstrap_helper_source" "$runner_bootstrap_helper" \
        || die "installed release runner bootstrap helper differs from repository source"
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

stop_runner_candidate_services() {
    local helper_target="system/$runner_bootstrap_label"
    local runner_target="user/$runner_uid/$runner_service_label"
    # Stop the root helper first so it cannot recreate the user agent while the
    # candidate is being removed or a legacy listener is being restored.
    if sudo /bin/launchctl print "$helper_target" >/dev/null 2>&1; then
        sudo /bin/launchctl bootout "$helper_target" || return 1
    fi
    sudo /bin/launchctl print "$helper_target" >/dev/null 2>&1 && return 1
    if sudo /bin/launchctl print "$runner_target" >/dev/null 2>&1; then
        sudo /bin/launchctl bootout "$runner_target" || return 1
    fi
    sudo /bin/launchctl print "$runner_target" >/dev/null 2>&1 && return 1
    return 0
}

remove_runner_service_files() {
    stop_runner_candidate_services || return 1
    sudo /bin/rm -f \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper" \
        || return 1
    for removed_path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper"; do
        if sudo /bin/test -e "$removed_path" || sudo /bin/test -L "$removed_path"; then
            return 1
        fi
    done
}

start_runner_service_files() {
    validate_installed_runner_service_files
    sudo /bin/launchctl bootstrap system "$runner_bootstrap_plist" \
        || sudo /bin/launchctl print "system/$runner_bootstrap_label" >/dev/null 2>&1 \
        || return 1
    sudo /bin/launchctl kickstart -k "system/$runner_bootstrap_label" \
        || return 1
    for ((service_poll = 1; service_poll <= 30; service_poll++)); do
        if sudo /bin/launchctl print "user/$runner_uid/$runner_service_label" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    sudo /bin/launchctl print "user/$runner_uid/$runner_service_label" >/dev/null 2>&1 \
        || return 1
    ensure_runner_user_domain || return 1
    verify_runner_domain_security_session || return 1
}

runner_listener_pid() {
    sudo /usr/bin/pgrep -u "$runner_uid" \
        -f "^$runner_dir/bin/Runner.Listener run" 2>/dev/null \
        | /usr/bin/head -1
}

wait_for_all_runner_listeners_exit() {
    for ((listener_poll = 1; listener_poll <= 30; listener_poll++)); do
        if [[ -z "$(runner_listener_pid || true)" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_listener_exit() {
    local previous_pid="$1"
    [[ -n "$previous_pid" ]] || return 0
    for ((listener_poll = 1; listener_poll <= 30; listener_poll++)); do
        if ! sudo /bin/kill -0 "$previous_pid" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_new_runner_listener() {
    local previous_pid="$1" listener_pid=""
    for ((listener_poll = 1; listener_poll <= 30; listener_poll++)); do
        listener_pid="$(runner_listener_pid || true)"
        if [[ -n "$listener_pid" && "$listener_pid" != "$previous_pid" ]]; then
            return 0
        fi
        sleep 1
    done
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
        [[ -z "$runner_summary" ]] || return 0
        sleep 1
    done
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
            return 0
        fi
        sleep 1
    done
    return 1
}

fence_remote_runner() {
    read_remote_runner_observation || return 1
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
            (( idle_observations >= 2 )) && return 0
        else
            idle_observations=0
        fi
        sleep 1
    done
    # No launchd state has changed yet. Best-effort reopening is safe even if a
    # job won the narrow pre-fence race; failure leaves scheduling closed.
    restore_remote_runner_label >/dev/null 2>&1 || true
    return 1
}

restore_remote_runner_label() {
    read_remote_runner_observation || return 1
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
}

acquire_bootstrap_lock() {
    sudo /usr/bin/shlock -f "$runner_bootstrap_lock" -p "$$" \
        || return 1
    bootstrap_lock_held=true
}

rollback_to_legacy_service() {
    stop_runner_candidate_services || return 1
    if sudo /bin/launchctl print "system/$runner_service_label" >/dev/null 2>&1; then
        sudo /bin/launchctl bootout "system/$runner_service_label" || return 1
    fi
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
    start_runner_service_files || return 1
    [[ -n "$(runner_listener_pid || true)" ]] || return 1
    if [[ -n "$repair_runner_id" ]]; then
        wait_for_remote_runner_status online
    else
        wait_for_runner_online
    fi
}

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
    || die "the iOS release runner requires an Apple-silicon Mac"
"$gh_executable" auth status >/dev/null \
    || die "authenticate GitHub CLI before bootstrapping"
repository="$("$gh_executable" repo view --json nameWithOwner --jq .nameWithOwner)"
[[ -n "$repository" ]] || die "could not resolve the current GitHub repository"
"$gh_executable" api "repos/$repository/environments/ios-testflight" >/dev/null \
    || die "create the ios-testflight GitHub environment before bootstrapping"
runner_registration_started=false
bootstrap_complete=false
runner_plist_staging=""
runner_bootstrap_plist_staging=""
archive=""
bootstrap_lock_held=false
repair_migration_active=false
repair_runner_id=""
repair_previous_listener_pid=""
remote_runner_busy=""
remote_runner_release_labeled=""
remote_runner_status=""
existing_runner_directory_mode=""
existing_runner_directory_state=""

cleanup_bootstrap() {
    local exit_status=$?
    local cleanup_incomplete=false
    local removal_token="" remaining_runner_id="" runner_id=""
    trap - EXIT
    set +e
    if [[ -n "$archive" ]]; then
        /bin/rm -f "$archive"
    fi
    if [[ -n "$runner_plist_staging" ]]; then
        /bin/rm -f "$runner_plist_staging"
    fi
    if [[ -n "$runner_bootstrap_plist_staging" ]]; then
        /bin/rm -f "$runner_bootstrap_plist_staging"
    fi
    if (( exit_status != 0 )) && [[ "$repair_migration_active" == "true" ]]; then
        if rollback_to_legacy_service; then
            echo "Restored the legacy release runner after the failed service migration." >&2
        else
            cleanup_incomplete=true
            echo "error: release runner migration and rollback both failed; its scheduling label remains fenced" >&2
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
            echo "error: incomplete runner bootstrap rollback; follow the rotation runbook before retrying" >&2
        else
            echo "Rolled back the incomplete GitHub runner registration and launchd service." >&2
        fi
    fi
    if [[ "$cleanup_incomplete" == "true" ]]; then
        if [[ "$bootstrap_lock_held" == "true" ]]; then
            sudo /bin/rm -f "$runner_bootstrap_lock"
        fi
        exit 1
    fi
    if [[ "$bootstrap_lock_held" == "true" ]]; then
        sudo /bin/rm -f "$runner_bootstrap_lock"
    fi
    exit "$exit_status"
}
trap cleanup_bootstrap EXIT

acquire_bootstrap_lock \
    || die "another release runner bootstrap or service repair is already active"

if [[ "$bootstrap_mode" == "install" ]]; then
    archive="$(mktemp -t tron-actions-runner.XXXXXX.tar.gz)"
    curl --fail --location --silent --show-error "$TRON_RELEASE_RUNNER_URL" --output "$archive"
    actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual_sha" == "$TRON_RELEASE_RUNNER_SHA256" ]] \
        || die "GitHub runner archive checksum mismatch"
fi

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
if runner_can_access_invoking_home; then
    sudo /bin/chmod +a "$runner_home_acl" "$invoking_home"
fi
if runner_can_access_invoking_home; then
    die "release runner account can still access the invoking user's home"
fi

if [[ "$bootstrap_mode" == "--repair-service" ]]; then
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
    [[ "$remote_runner_busy" == "false" ]] \
        || die "release runner is busy; wait for the active job before repairing its service"
    normalize_existing_runner_directory_mode

    stage_runner_service_files
    candidate_path_count=0
    for candidate_path in \
        "$runner_service_plist" \
        "$runner_bootstrap_plist" \
        "$runner_bootstrap_helper"; do
        if sudo /bin/test -e "$candidate_path" || sudo /bin/test -L "$candidate_path"; then
            candidate_path_count=$((candidate_path_count + 1))
        fi
    done
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
    [[ "$runner_service_state" != "invalid" ]] \
        || die "release runner repair found an ambiguous or incomplete service topology"

    if [[ "$runner_service_state" == "current" ]]; then
        sudo /bin/launchctl print "system/$runner_service_label" >/dev/null 2>&1 \
            && die "legacy release runner is loaded without its immutable plist"
        [[ "$candidate_path_count" == "3" ]] \
            || die "release runner repair found neither a complete legacy nor Background service"
        validate_installed_runner_service_files
        prepare_runner_security_context
        validate_existing_background_service \
            || die "existing Background release runner service is not healthy"
        restore_remote_runner_label \
            || die "Background release runner is healthy but its scheduling label could not be restored"
        bootstrap_complete=true
        echo "$runner_summary"
        echo "Release runner already uses the verified Background service topology."
        exit 0
    fi

    fence_remote_runner \
        || die "release runner could not be fenced idle for service repair"
    repair_migration_active=true
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
    if sudo /bin/launchctl print "system/$runner_service_label" >/dev/null 2>&1; then
        sudo /bin/launchctl bootout "system/$runner_service_label" \
            || die "could not stop the legacy release runner listener"
    fi
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
        || die "Background release runner did not create a new listener"
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
    echo "$runner_summary"
    echo "Release runner migrated transactionally to its Background user domain."
    exit 0
fi

prepare_runner_security_context
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
    "$runner_bootstrap_helper"; do
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
    || die "Background release runner did not create its listener"
wait_for_runner_online \
    || die "release runner did not become online with its dedicated label"
sudo /usr/bin/pmset -c sleep 0
sudo /usr/bin/pmset -a tcpkeepalive 1
bootstrap_complete=true
echo "$runner_summary"
echo "Release runner installed. Confirm ios-testflight environment secrets before enabling delivery."
