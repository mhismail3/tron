#!/bin/sh
set -eu

usage() {
  echo "usage: install-native-host.sh --extension-id <32 lowercase a-p characters> --tron-binary <absolute path> [--tron-home <absolute path>]" >&2
  exit 2
}

extension_id=
tron_binary=
tron_home="${TRON_DATA_DIR:-${HOME}/.tron}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --extension-id)
      [ "$#" -ge 2 ] || usage
      extension_id=$2
      shift 2
      ;;
    --tron-binary)
      [ "$#" -ge 2 ] || usage
      tron_binary=$2
      shift 2
      ;;
    --tron-home)
      [ "$#" -ge 2 ] || usage
      tron_home=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

case "$extension_id" in
  [a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p][a-p]) ;;
  *) usage ;;
esac

case "$tron_binary" in
  /*) ;;
  *) usage ;;
esac
case "$tron_home" in
  /*) ;;
  *) usage ;;
esac
[ -x "$tron_binary" ] || {
  echo "tron binary is not executable: $tron_binary" >&2
  exit 1
}

host_root="$tron_home/internal/browser-operator"
socket_path="$tron_home/internal/run/browser-operator.sock"
wrapper_path="$host_root/native-host"
chrome_host_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
manifest_path="$chrome_host_dir/com.tron.browser_operator.json"

mkdir -p "$host_root" "$chrome_host_dir" "$tron_home/internal/run"
chmod 700 "$host_root" "$tron_home/internal/run"

wrapper_tmp=$(mktemp "$host_root/native-host.XXXXXX")
manifest_tmp=$(mktemp "$chrome_host_dir/com.tron.browser_operator.json.XXXXXX")
cleanup() {
  rm -f "$wrapper_tmp" "$manifest_tmp"
}
trap cleanup EXIT HUP INT TERM

{
  printf '%s\n' '#!/bin/sh'
  printf 'exec %s browser-native-host --socket %s\n' \
    "$(printf '%s' "$tron_binary" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")" \
    "$(printf '%s' "$socket_path" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
} > "$wrapper_tmp"
chmod 700 "$wrapper_tmp"

python3 - "$wrapper_path" "$extension_id" > "$manifest_tmp" <<'PY'
import json
import sys

print(
    json.dumps(
        {
            "name": "com.tron.browser_operator",
            "description": "Closed native host for the Tron Browser Operator",
            "path": sys.argv[1],
            "type": "stdio",
            "allowed_origins": [f"chrome-extension://{sys.argv[2]}/"],
        },
        indent=2,
    )
)
PY
chmod 600 "$manifest_tmp"

mv -f "$wrapper_tmp" "$wrapper_path"
mv -f "$manifest_tmp" "$manifest_path"
trap - EXIT HUP INT TERM
echo "Installed com.tron.browser_operator for extension $extension_id."
