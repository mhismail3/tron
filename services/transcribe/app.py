from __future__ import annotations

import asyncio
import shutil
import uuid
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from .engine import describe_config, get_config, transcribe_file
from .config import ensure_dirs

app = FastAPI(title="Tron Transcribe")
_config = get_config()
ensure_dirs(_config)
_semaphore = asyncio.Semaphore(1)


@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "backend": _config.backend,
        "model": _config.model_name,
        "device": _config.device,
        "compute_type": _config.compute_type,
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


@app.post("/transcribe/faster")
async def transcribe_faster(
    audio: UploadFile = File(...),
    language: Optional[str] = Form(default=None),
    task: Optional[str] = Form(default=None),
    prompt: Optional[str] = Form(default=None),
    cleanup_mode: Optional[str] = Form(default=None),
    return_segments: bool = Form(default=False),
) -> JSONResponse:
    return await _handle_transcribe(
        audio=audio,
        backend="parakeet-mlx",
        model_name="mlx-community/parakeet-tdt-0.6b-v3",
        device="mlx",
        compute_type="mlx",
        language=language,
        task=task,
        prompt=prompt,
        cleanup_mode=cleanup_mode,
        return_segments=return_segments,
    )


@app.post("/transcribe/better")
async def transcribe_better(
    audio: UploadFile = File(...),
    language: Optional[str] = Form(default=None),
    task: Optional[str] = Form(default=None),
    prompt: Optional[str] = Form(default=None),
    cleanup_mode: Optional[str] = Form(default=None),
    return_segments: bool = Form(default=False),
) -> JSONResponse:
    return await _handle_transcribe(
        audio=audio,
        backend="faster-whisper",
        model_name="large-v3",
        device="cpu",
        compute_type="int8",
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
