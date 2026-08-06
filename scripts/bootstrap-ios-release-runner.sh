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

die() {
    echo "error: $*" >&2
    exit 1
}

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
    || die "the iOS release runner requires an Apple-silicon Mac"
command -v gh >/dev/null || die "GitHub CLI is required"
gh auth status >/dev/null || die "authenticate GitHub CLI before bootstrapping"
repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[[ -n "$repository" ]] || die "could not resolve the current GitHub repository"
gh api "repos/$repository/environments/ios-testflight" >/dev/null \
    || die "create the ios-testflight GitHub environment before bootstrapping"
archive="$(mktemp -t tron-actions-runner.XXXXXX.tar.gz)"
trap '/bin/rm -f "$archive"' EXIT
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
    sudo dscl . create "/Users/$runner_user" IsHidden 1
fi

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

# `sysadminctl` records an explicitly assigned home but does not necessarily
# create it. Repair that normal interrupted-bootstrap state without weakening
# path ownership or following a pre-existing symlink.
[[ ! -L "$runner_home" ]] || die "release runner home must not be a symlink"
[[ ! -e "$runner_home" || -d "$runner_home" ]] \
    || die "release runner home exists but is not a directory"
sudo install -d -m 700 -o "$runner_user" -g staff "$runner_home"
[[ -d "$runner_home" && ! -L "$runner_home" ]] \
    || die "release runner home was not created safely"
[[ "$(stat -f '%Su' "$runner_home")" == "$runner_user" ]] \
    || die "release runner home has the wrong owner"
[[ "$(stat -f '%Lp' "$runner_home")" == "700" ]] \
    || die "release runner home must have mode 0700"

# The release workflow snapshots and restores a baseline keychain before using
# its ephemeral signing keychain. A service account has no login keychain until
# one is created explicitly.
runner_library="$runner_home/Library"
runner_keychains="$runner_library/Keychains"
[[ ! -L "$runner_library" && ! -L "$runner_keychains" ]] \
    || die "release runner Library paths must not be symlinks"
sudo install -d -m 700 -o "$runner_user" -g staff \
    "$runner_library" "$runner_keychains"
baseline_keychain="$runner_keychains/tron-runner-baseline.keychain-db"
[[ ! -L "$baseline_keychain" ]] \
    || die "release runner baseline keychain must not be a symlink"
if [[ ! -e "$baseline_keychain" ]]; then
    baseline_password="$(openssl rand -hex 32)"
    sudo -H -u "$runner_user" security create-keychain \
        -p "$baseline_password" "$baseline_keychain"
    sudo -H -u "$runner_user" security list-keychains -d user -s "$baseline_keychain"
    sudo -H -u "$runner_user" security default-keychain -d user -s "$baseline_keychain"
    unset baseline_password
fi

invoking_home="$(dscl . -read "/Users/${SUDO_USER:-$USER}" NFSHomeDirectory | awk '{print $2}')"
if [[ -n "$invoking_home" ]] && sudo -H -u "$runner_user" test -r "$invoking_home"; then
    die "release runner account can read the invoking user's home; tighten home permissions first"
fi

[[ ! -e "$runner_dir/.runner" ]] \
    || die "a runner is already configured at $runner_dir; rotate it through the documented runbook"
sudo install -d -m 700 -o "$runner_user" -g staff "$runner_dir"
# `mktemp` intentionally creates the verified archive as mode 0600. Extract it
# as root, then hand the checksum-trusted files to the isolated service account.
sudo tar -xzf "$archive" -C "$runner_dir"
sudo chown -R "$runner_user":staff "$runner_dir"
registration_token="$(gh api --method POST "repos/$repository/actions/runners/registration-token" --jq .token)"
[[ -n "$registration_token" ]] || die "could not obtain a repository runner token"
sudo -H -u "$runner_user" "$runner_dir/config.sh" \
    --url "https://github.com/$repository" \
    --token "$registration_token" \
    --name "$runner_name" \
    --labels "$runner_label" \
    --work "_work" \
    --unattended \
    --disableupdate
unset registration_token

sudo "$runner_dir/svc.sh" install "$runner_user"
sudo "$runner_dir/svc.sh" start
sudo pmset -c sleep 0
sudo pmset -a tcpkeepalive 1

sudo -H -u "$runner_user" env \
    DEVELOPER_DIR="$TRON_RELEASE_IOS_DEVELOPER_DIR" \
    xcodebuild -checkFirstLaunchStatus >/dev/null \
    || die "the release account cannot use the pinned Xcode installation"

gh api "repos/$repository/actions/runners" \
    --jq ".runners[] | select(.name == \"$runner_name\") | {status, busy, labels: [.labels[].name]}"
echo "Release runner installed. Confirm ios-testflight environment secrets before enabling delivery."
