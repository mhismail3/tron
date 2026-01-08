from __future__ import annotations

import argparse
import json
from pathlib import Path

from .engine import transcribe_file


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe an audio file with faster-whisper.")
    parser.add_argument("audio", type=Path, help="Path to audio file")
    parser.add_argument("--language", default=None, help="Language code (default: config)")
    parser.add_argument("--task", default=None, help="transcribe or translate")
    parser.add_argument("--prompt", default=None, help="Initial prompt")
    parser.add_argument("--cleanup", default=None, help="none, basic, or llm")
    parser.add_argument("--segments", action="store_true", help="Include segments in output")
    parser.add_argument("--json", action="store_true", help="Print JSON output")

    args = parser.parse_args()

    result = transcribe_file(
        args.audio,
        language=args.language,
        task=args.task,
        prompt=args.prompt,
        cleanup_mode=args.cleanup,
        return_segments=args.segments,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(result["text"])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
