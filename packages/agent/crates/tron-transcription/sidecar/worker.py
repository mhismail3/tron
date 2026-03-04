#!/usr/bin/env python3
"""Parakeet-MLX transcription worker. stdin/stdout JSON-line protocol."""
import json, sys, os, time


def main():
    print(json.dumps({"status": "loading"}), flush=True)
    os.environ.setdefault(
        "HF_HOME", os.path.expanduser("~/.tron/mods/transcribe/models/hf")
    )

    from parakeet_mlx import from_pretrained

    model = from_pretrained("mlx-community/parakeet-tdt-0.6b-v3")
    print(json.dumps({"status": "ready"}), flush=True)
    print("[worker] model loaded", file=sys.stderr, flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            t0 = time.monotonic()
            result = model.transcribe(req["audio_path"])

            text = result.text if hasattr(result, "text") else str(result)
            duration = 0.0
            if hasattr(result, "sentences") and result.sentences:
                last = result.sentences[-1]
                duration = last.end if hasattr(last, "end") else 0.0

            elapsed_ms = int((time.monotonic() - t0) * 1000)
            print(
                f"[worker] transcribed in {elapsed_ms}ms: {text[:80]}",
                file=sys.stderr,
                flush=True,
            )

            resp = {
                "id": req.get("id", ""),
                "text": text.strip(),
                "language": "en",
                "duration_seconds": duration,
            }
        except Exception as e:
            import traceback

            traceback.print_exc(file=sys.stderr)
            resp = {"id": req.get("id", ""), "error": str(e)}

        print(json.dumps(resp), flush=True)


if __name__ == "__main__":
    main()
