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
runner_service_plist="/Library/LaunchDaemons/$runner_service_label.plist"

die() {
    echo "error: $*" >&2
    exit 1
}

gh_executable="$(command -v gh || true)"
# This macOS-only bootstrap relies on BSD utility flags. Do not let Homebrew
# coreutils or another interactive-shell PATH change their semantics.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

bootstrap_self_test() {
    local acl_entry acl_listing acl_probe acl_tail
    acl_probe="$(mktemp -d -t tron-runner-acl)"
    trap '/bin/chmod -N "$acl_probe" >/dev/null 2>&1 || true; /bin/rmdir "$acl_probe" >/dev/null 2>&1 || true' EXIT
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
    trap - EXIT
    echo "iOS release runner bootstrap self-test passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
    bootstrap_self_test
    exit 0
fi
(( $# == 0 )) || die "usage: scripts/bootstrap-ios-release-runner.sh [--self-test]"
[[ "$gh_executable" == /* && -x "$gh_executable" ]] \
    || die "GitHub CLI is required"

run_as_runner() (
    # Never hand the service account a current working directory inside the
    # invoking user's otherwise-private home.
    cd /
    exec sudo -H -u "$runner_user" "$@"
)

validate_private_runner_directory() {
    local directory="$1"
    sudo /bin/test -d "$directory" \
        || die "release runner path is not a directory: $directory"
    if sudo /bin/test -L "$directory"; then
        die "release runner path must not be a symlink: $directory"
    fi
    [[ "$(sudo /usr/bin/stat -f '%Su' "$directory")" == "$runner_user" ]] \
        || die "release runner path has the wrong owner: $directory"
    [[ "$(sudo /usr/bin/stat -f '%Lp' "$directory")" == "700" ]] \
        || die "release runner path must have mode 0700: $directory"
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
archive="$(mktemp -t tron-actions-runner.XXXXXX.tar.gz)"

cleanup_bootstrap() {
    local exit_status=$?
    local cleanup_incomplete=false
    local removal_token="" remaining_runner_id="" runner_id=""
    trap - EXIT
    set +e
    /bin/rm -f "$archive"
    if [[ -n "$runner_plist_staging" ]]; then
        /bin/rm -f "$runner_plist_staging"
    fi
    if (( exit_status != 0 )) \
        && [[ "$bootstrap_complete" != "true" && "$runner_registration_started" == "true" ]]; then
        # Registration and service installation form one transaction. Neither
        # remote credentials nor a launchd job may survive a failed bootstrap.
        sudo launchctl bootout "system/$runner_service_label" >/dev/null 2>&1
        sudo /bin/rm -f "$runner_service_plist"
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
        sudo /bin/rm -f \
            "$runner_dir/.runner" \
            "$runner_dir/.credentials" \
            "$runner_dir/.credentials_rsaparams"

        if sudo launchctl print "system/$runner_service_label" >/dev/null 2>&1 \
            || sudo /bin/test -e "$runner_service_plist" \
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
    exit "$exit_status"
}
trap cleanup_bootstrap EXIT

curl --fail --location --silent --show-error "$TRON_RELEASE_RUNNER_URL" --output "$archive"
actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_sha" == "$TRON_RELEASE_RUNNER_SHA256" ]] \
    || die "GitHub runner archive checksum mismatch"

if ! dscl . -read "/Users/$runner_user" >/dev/null 2>&1; then
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
sudo install -d -m 700 -o "$runner_user" -g staff "$runner_home"
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

# The release workflow snapshots and restores a baseline keychain before using
# its ephemeral signing keychain. A service account has no login keychain until
# one is created explicitly. These checks run with privilege because the
# correctly private runner home is intentionally opaque to the invoking user.
runner_library="$runner_home/Library"
runner_keychains="$runner_library/Keychains"
for runner_path in "$runner_library" "$runner_keychains"; do
    if sudo /bin/test -L "$runner_path"; then
        die "release runner Library paths must not be symlinks"
    fi
done
sudo install -d -m 700 -o "$runner_user" -g staff \
    "$runner_library" "$runner_keychains"
validate_private_runner_directory "$runner_library"
validate_private_runner_directory "$runner_keychains"

baseline_keychain="$runner_keychains/tron-runner-baseline.keychain-db"
if sudo /bin/test -L "$baseline_keychain"; then
    die "release runner baseline keychain must not be a symlink"
fi
if ! sudo /bin/test -e "$baseline_keychain"; then
    baseline_password="$(openssl rand -hex 32)"
    run_as_runner security create-keychain \
        -p "$baseline_password" "$baseline_keychain"
    unset baseline_password
fi
sudo /bin/test -f "$baseline_keychain" \
    || die "release runner baseline keychain is not a regular file"
sudo chown "$runner_user":staff "$baseline_keychain"
sudo chmod 600 "$baseline_keychain"

if sudo launchctl print "system/$runner_service_label" >/dev/null 2>&1 \
    || sudo /bin/test -e "$runner_service_plist"; then
    die "release runner launch daemon already exists; use the documented rotation flow"
fi
existing_runner_id="$(
    "$gh_executable" api "repos/$repository/actions/runners" \
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
sudo install -d -m 700 -o "$runner_user" -g staff "$runner_dir"
validate_private_runner_directory "$runner_dir"
# `mktemp` intentionally creates the verified archive as mode 0600. Extract it
# as root, then hand the checksum-trusted files to the isolated service account.
sudo tar -xzf "$archive" -C "$runner_dir"
sudo chown -R "$runner_user":staff "$runner_dir"
for runner_executable in "$runner_dir/config.sh" "$runner_dir/bin/runsvc.sh"; do
    sudo /bin/test -f "$runner_executable" \
        || die "verified runner archive is missing $(basename "$runner_executable")"
    sudo /bin/test -x "$runner_executable" \
        || die "verified runner archive contains a non-executable $(basename "$runner_executable")"
    if sudo /bin/test -L "$runner_executable"; then
        die "verified runner executable must not be a symlink: $runner_executable"
    fi
done
runner_plist_template="$runner_dir/bin/actions.runner.plist.template"
sudo /bin/test -f "$runner_plist_template" \
    || die "verified runner archive is missing its Darwin launchd template"
if sudo /bin/test -L "$runner_plist_template"; then
    die "verified runner launchd template must not be a symlink"
fi
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

# GitHub's Darwin `svc.sh` installs a per-login LaunchAgent and explicitly
# refuses root. This hidden account has no Aqua login session, so install the
# pinned runner's documented `runsvc.sh` entry point as a system-domain daemon
# that drops privileges to the isolated account.
sudo install -m 755 -o "$runner_user" -g staff \
    "$runner_dir/bin/runsvc.sh" "$runner_dir/runsvc.sh"
runner_logs="$runner_home/Library/Logs/$runner_service_label"
sudo install -d -m 700 -o "$runner_user" -g staff "$runner_logs"
validate_private_runner_directory "$runner_logs"

runner_plist_staging="$(mktemp -t tron-ios-release-runner.plist)"
sudo cat "$runner_plist_template" \
    | sed \
        -e "s|{{SvcName}}|$runner_service_label|g" \
        -e "s|{{User}}|$runner_user|g" \
        -e "s|{{RunnerRoot}}|$runner_dir|g" \
        -e "s|{{UserHome}}|$runner_home|g" \
        > "$runner_plist_staging"
/usr/libexec/PlistBuddy -c "Add :GroupName string staff" "$runner_plist_staging"
/usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$runner_plist_staging"
/usr/libexec/PlistBuddy -c "Add :Umask integer 63" "$runner_plist_staging"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:HOME string $runner_home" \
    "$runner_plist_staging"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:PATH string $PATH" \
    "$runner_plist_staging"
plutil -lint "$runner_plist_staging" >/dev/null
! grep -Fq '{{' "$runner_plist_staging" \
    || die "release runner launchd template contains unresolved tokens"
sudo install -m 600 -o root -g wheel "$runner_plist_staging" "$runner_service_plist"
sudo launchctl bootstrap system "$runner_service_plist"
sudo launchctl kickstart -k "system/$runner_service_label"
sudo launchctl print "system/$runner_service_label" >/dev/null \
    || die "release runner launch daemon did not start"
sudo pmset -c sleep 0
sudo pmset -a tcpkeepalive 1

run_as_runner env \
    DEVELOPER_DIR="$TRON_RELEASE_IOS_DEVELOPER_DIR" \
    xcodebuild -checkFirstLaunchStatus >/dev/null \
    || die "the release account cannot use the pinned Xcode installation"

runner_summary=""
for ((runner_poll = 1; runner_poll <= 30; runner_poll++)); do
    runner_summary="$(
        "$gh_executable" api "repos/$repository/actions/runners" \
            --jq ".runners[]
                | select(.name == \"$runner_name\")
                | select(.status == \"online\")
                | select([.labels[].name] | index(\"$runner_label\"))
                | {status, busy, labels: [.labels[].name]}"
    )"
    [[ -z "$runner_summary" ]] || break
    sleep 1
done
[[ -n "$runner_summary" ]] \
    || die "release runner did not become online with its dedicated label"
bootstrap_complete=true
echo "$runner_summary"
echo "Release runner installed. Confirm ios-testflight environment secrets before enabling delivery."
