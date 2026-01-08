#!/usr/bin/env bash
set -euo pipefail

backend="parakeet-mlx"
model=""
cleanup_mode="${TRON_TRANSCRIBE_CLEANUP_MODE:-basic}"
language="${TRON_TRANSCRIBE_LANGUAGE:-en}"
device="${TRON_TRANSCRIBE_DEVICE:-mlx}"
compute_type="${TRON_TRANSCRIBE_COMPUTE_TYPE:-mlx}"
max_duration="${TRON_TRANSCRIBE_MAX_DURATION_S:-120}"

usage() {
  cat <<'EOF'
Usage: write-config.sh [--backend parakeet-mlx|mlx-whisper|faster-whisper] [--model MODEL]

Environment overrides:
  TRON_TRANSCRIBE_CONFIG       Config path (default: ~/.tron/transcribe/config.json)
  TRON_TRANSCRIBE_CLEANUP_MODE Cleanup mode (default: basic)
  TRON_TRANSCRIBE_LANGUAGE     Language (default: en)
  TRON_TRANSCRIBE_DEVICE       Device (default: mlx)
  TRON_TRANSCRIBE_COMPUTE_TYPE Compute type (default: mlx)
  TRON_TRANSCRIBE_MAX_DURATION_S Max duration seconds (default: 120)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      backend="${2:-}"
      shift 2
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$backend" in
  parakeet-mlx)
    default_model="mlx-community/parakeet-tdt-0.6b-v3"
    ;;
  mlx-whisper)
    default_model="mlx-community/whisper-large-v3-turbo"
    ;;
  faster-whisper)
    default_model="large-v3"
    device="${TRON_TRANSCRIBE_DEVICE:-cpu}"
    compute_type="${TRON_TRANSCRIBE_COMPUTE_TYPE:-int8}"
    ;;
  *)
    echo "Unsupported backend: $backend" >&2
    usage
    exit 1
    ;;
esac

if [[ -z "$model" ]]; then
  model="$default_model"
fi

base_dir="${TRON_TRANSCRIBE_BASE_DIR:-$HOME/.tron/transcribe}"
config_path="${TRON_TRANSCRIBE_CONFIG:-$base_dir/config.json}"
config_dir="$(dirname "$config_path")"

mkdir -p "$config_dir"

cat >"$config_path" <<EOF
{
  "backend": "$backend",
  "model_name": "$model",
  "device": "$device",
  "compute_type": "$compute_type",
  "language": "$language",
  "max_duration_s": $max_duration,
  "cleanup_mode": "$cleanup_mode"
}
EOF

echo "Wrote transcription config to $config_path"
