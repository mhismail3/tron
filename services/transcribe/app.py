from __future__ import annotations

import asyncio
import shutil
import threading
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from .engine import describe_config, get_config, transcribe_file, _load_model, _MODEL_CACHE

# Module-level warmup state with thread-safe access
_warmup_state: dict[str, Any] = {
    "started": False,
    "completed": False,
    "error": None,
    "started_at": None,
    "completed_at": None,
    "failed_at": None,
    "elapsed_ms": None,
}
_warmup_lock = threading.Lock()
_startup_time = time.monotonic()


def get_warmup_state() -> dict[str, Any]:
    """Get a copy of the current warmup state (thread-safe)."""
    with _warmup_lock:
        return _warmup_state.copy()


def reset_warmup_state() -> None:
    """Reset warmup state to initial values (for testing)."""
    with _warmup_lock:
        _warmup_state.update({
            "started": False,
            "completed": False,
            "error": None,
            "started_at": None,
            "completed_at": None,
            "failed_at": None,
            "elapsed_ms": None,
        })


def set_warmup_completed() -> None:
    """Mark warmup as completed (for testing)."""
    with _warmup_lock:
        _warmup_state.update({
            "started": True,
            "completed": True,
            "error": None,
        })


def set_warmup_error(error: str) -> None:
    """Mark warmup as failed with an error (for testing)."""
    with _warmup_lock:
        _warmup_state.update({
            "started": True,
            "completed": False,
            "error": error,
        })


def _warmup_model() -> None:
    """Load default model in background thread.

    Thread-safe: only one warmup will run even if called multiple times.
    """
    from .engine import _load_model
    from .config import load_config

    config = load_config()

    # Check if warmup already started (thread-safe)
    with _warmup_lock:
        if _warmup_state["started"]:
            # Warmup already in progress or completed
            return
        _warmup_state["started"] = True
        _warmup_state["started_at"] = datetime.now(timezone.utc).isoformat()

    print(
        f"[warmup] Starting model warmup: backend={config.backend}, "
        f"model={config.model_name}, device={config.device}",
        flush=True,
    )

    try:
        start = time.monotonic()
        _load_model(
            config.backend,
            config.model_name,
            config.device,
            config.compute_type,
            config,
        )
        elapsed_ms = int((time.monotonic() - start) * 1000)

        with _warmup_lock:
            _warmup_state["completed"] = True
            _warmup_state["completed_at"] = datetime.now(timezone.utc).isoformat()
            _warmup_state["elapsed_ms"] = elapsed_ms

        print(
            f"[warmup] Model warmup completed in {elapsed_ms}ms",
            flush=True,
        )
    except Exception as e:
        error_msg = str(e)
        with _warmup_lock:
            _warmup_state["error"] = error_msg
            _warmup_state["failed_at"] = datetime.now(timezone.utc).isoformat()

        print(
            f"[warmup] Model warmup failed: {error_msg}",
            flush=True,
        )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Start model warmup on application startup."""
    global _startup_time
    _startup_time = time.monotonic()

    # Start warmup in background thread
    thread = threading.Thread(target=_warmup_model, daemon=True, name="model-warmup")
    thread.start()

    yield


app = FastAPI(title="Tron Transcribe", lifespan=lifespan)
_config = get_config()

from .config import ensure_dirs
ensure_dirs(_config)

_semaphore = asyncio.Semaphore(1)


@app.get("/health")
async def health() -> dict[str, Any]:
    """Liveness check - always returns 200 if server is running."""
    return {
        "status": "ok",
        "backend": _config.backend,
        "model": _config.model_name,
        "device": _config.device,
        "compute_type": _config.compute_type,
        "warmup": get_warmup_state(),
    }


@app.get("/ready")
async def ready() -> dict[str, Any]:
    """Readiness check - returns 503 until model is loaded."""
    state = get_warmup_state()

    if state["error"]:
        raise HTTPException(status_code=503, detail=f"Warmup failed: {state['error']}")

    if not state["completed"]:
        raise HTTPException(status_code=503, detail="Model not yet loaded")

    return {
        "status": "ready",
        "model_loaded": True,
        "backend": _config.backend,
        "model": _config.model_name,
        "elapsed_ms": state.get("elapsed_ms"),
    }


class WarmupRequest(BaseModel):
    backend: Optional[str] = None


@app.post("/warmup")
async def warmup(request: Optional[WarmupRequest] = None) -> dict[str, Any]:
    """Manually trigger model warmup.

    If warmup is already in progress (from startup), this will wait for
    the existing warmup to complete rather than starting a duplicate.
    The _load_model function uses double-checked locking internally,
    so concurrent calls are safe and won't load the model twice.
    """
    from .engine import _load_model, _MODEL_CACHE
    from .config import load_config

    config = load_config()
    effective_backend = (request.backend if request else None) or config.backend

    model_name = config.model_name
    device = config.device
    compute_type = config.compute_type

    key = (effective_backend, model_name, device, compute_type)

    # Fast path: model already cached
    if key in _MODEL_CACHE:
        return {"status": "ok", "already_loaded": True, "backend": effective_backend}

    # Load model (thread-safe via _MODEL_CACHE_LOCK in engine.py)
    await run_in_threadpool(
        _load_model, effective_backend, model_name, device, compute_type, config
    )

    return {"status": "ok", "already_loaded": False, "backend": effective_backend}


@app.get("/status")
async def status() -> dict[str, Any]:
    """Detailed status endpoint for debugging."""
    from .engine import _MODEL_CACHE
    from .config import load_config

    config = load_config()

    return {
        "warmup": get_warmup_state(),
        "config": {
            "backend": config.backend,
            "model": config.model_name,
            "device": config.device,
            "compute_type": config.compute_type,
        },
        "models_loaded": [
            {"backend": k[0], "model": k[1], "device": k[2], "compute_type": k[3]}
            for k in _MODEL_CACHE.keys()
        ],
        "uptime_seconds": round(time.monotonic() - _startup_time, 2),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/config")
async def config() -> dict[str, Any]:
    return describe_config()


@app.post("/transcribe")
async def transcribe(
    audio: UploadFile = File(...),
    backend: Optional[str] = Form(default=None),
    model_name: Optional[str] = Form(default=None),
    device: Optional[str] = Form(default=None),
    compute_type: Optional[str] = Form(default=None),
    language: Optional[str] = Form(default=None),
    task: Optional[str] = Form(default=None),
    prompt: Optional[str] = Form(default=None),
    cleanup_mode: Optional[str] = Form(default=None),
    return_segments: bool = Form(default=False),
) -> JSONResponse:
    return await _handle_transcribe(
        audio=audio,
        backend=backend,
        model_name=model_name,
        device=device,
        compute_type=compute_type,
        language=language,
        task=task,
        prompt=prompt,
        cleanup_mode=cleanup_mode,
        return_segments=return_segments,
    )


async def _handle_transcribe(
    *,
    audio: UploadFile,
    backend: Optional[str] = None,
    model_name: Optional[str] = None,
    device: Optional[str] = None,
    compute_type: Optional[str] = None,
    language: Optional[str] = None,
    task: Optional[str] = None,
    prompt: Optional[str] = None,
    cleanup_mode: Optional[str] = None,
    return_segments: bool = False,
) -> JSONResponse:
    if audio.filename is None:
        raise HTTPException(status_code=400, detail="Missing filename")

    ensure_dirs(_config)
    suffix = Path(audio.filename).suffix or ".wav"
    tmp_path = _config.tmp_dir / f"{uuid.uuid4().hex}{suffix}"

    try:
        with tmp_path.open("wb") as handle:
            shutil.copyfileobj(audio.file, handle)

        async with _semaphore:
            try:
                result = await run_in_threadpool(
                    transcribe_file,
                    tmp_path,
                    backend=backend,
                    model_name=model_name,
                    device=device,
                    compute_type=compute_type,
                    language=language,
                    task=task,
                    prompt=prompt,
                    cleanup_mode=cleanup_mode,
                    return_segments=return_segments,
                )
            except ValueError as error:
                raise HTTPException(status_code=400, detail=str(error)) from error
            except Exception as error:  # pragma: no cover - unexpected failures
                raise HTTPException(status_code=500, detail=str(error)) from error

        return JSONResponse(result)
    finally:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass


def run() -> None:
    import uvicorn

    uvicorn.run(
        "services.transcribe.app:app",
        host=_config.host,
        port=_config.port,
        reload=False,
    )


if __name__ == "__main__":
    run()
