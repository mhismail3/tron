from __future__ import annotations

import json
import re
import urllib.request
from typing import Any, Optional

from .config import TranscribeConfig


_WHITESPACE_RE = re.compile(r"\s+")
_SPACE_BEFORE_PUNCT_RE = re.compile(r"\s+([,.;:!?])")
_JSON_BLOCK_RE = re.compile(r"\{.*\}", re.DOTALL)
_PREAMBLE_RE = re.compile(
    r"^(here(?:'| i)?s|cleaned(?:-up)? transcription|clean transcription|cleaned transcript)\b",
    re.IGNORECASE,
)


def basic_cleanup(text: str) -> str:
    cleaned = text.strip()
    cleaned = _WHITESPACE_RE.sub(" ", cleaned)
    cleaned = _SPACE_BEFORE_PUNCT_RE.sub(r"\1", cleaned)
    return cleaned


def llm_cleanup(text: str, config: TranscribeConfig) -> str:
    base_url = config.cleanup_llm_base_url.rstrip("/")
    url = f"{base_url}/chat/completions"

    system_prompt = (
        "You are a transcription cleanup assistant. "
        "Fix obvious punctuation and capitalization, remove filler words when safe, "
        "and keep the meaning unchanged. Preserve line breaks if present. "
        "Return ONLY a JSON object with a single key 'text' whose value is the cleaned transcript. "
        "Do not include any other words, labels, markdown, or quotes."
    )

    payload: dict[str, Any] = {
        "model": config.cleanup_llm_model,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text},
        ],
    }

    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method="POST")
    request.add_header("Content-Type", "application/json")
    if config.cleanup_llm_api_key:
        request.add_header("Authorization", f"Bearer {config.cleanup_llm_api_key}")

    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read().decode("utf-8")
        parsed = json.loads(raw)

    choices = parsed.get("choices")
    if not choices:
        raise RuntimeError("LLM cleanup returned no choices")

    message = choices[0].get("message") if isinstance(choices[0], dict) else None
    content = message.get("content") if isinstance(message, dict) else None
    if not content:
        raise RuntimeError("LLM cleanup returned empty content")

    cleaned = str(content).strip()
    extracted = _extract_json_text(cleaned)
    if extracted is not None:
        return extracted
    return _strip_llm_wrapper(cleaned)


def apply_cleanup(text: str, config: TranscribeConfig, mode: Optional[str] = None) -> str:
    selected = (mode or config.cleanup_mode or "basic").strip().lower()
    if selected == "none":
        return text
    if selected == "basic":
        return basic_cleanup(text)
    if selected == "llm":
        return llm_cleanup(text, config)
    raise ValueError(f"Unknown cleanup mode: {selected}")


def _extract_json_text(content: str) -> Optional[str]:
    for candidate in (content, _JSON_BLOCK_RE.search(content).group(0) if _JSON_BLOCK_RE.search(content) else None):
        if not candidate:
            continue
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and "text" in parsed:
            value = parsed.get("text")
            if value is None:
                return ""
            return str(value).strip()
    return None


def _strip_llm_wrapper(content: str) -> str:
    cleaned = content.strip()
    lines = cleaned.splitlines()
    removed_preamble = False
    while lines:
        head = lines[0].strip()
        if not head:
            lines.pop(0)
            removed_preamble = True
            continue
        if _PREAMBLE_RE.match(head):
            lines.pop(0)
            removed_preamble = True
            continue
        break
    cleaned = "\n".join(lines).strip() if lines else ""
    if removed_preamble and len(cleaned) >= 2 and cleaned[0] == cleaned[-1] and cleaned[0] in ("\"", "'"):
        inner = cleaned[1:-1].strip()
        if cleaned[0] not in inner:
            cleaned = inner
    return cleaned
