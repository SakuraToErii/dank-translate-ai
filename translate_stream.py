#!/usr/bin/env python3
"""Small OpenAI-compatible streaming client for Dank Translate AI.

The QML daemon writes one JSON request to stdin. This helper emits NDJSON events:
{"type":"delta","text":"..."}, {"type":"done"}, or
{"type":"error","message":"..."}.
"""

from __future__ import annotations

import json
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Iterable


MAX_ERROR_BODY = 4_000
MAX_RESPONSE_BODY = 16 * 1024 * 1024
MAX_SSE_LINE = 4 * 1024 * 1024
MAX_INPUT_CHARS = 100_000
_UI_LANGUAGE = "en"


def tr(en: str, zh: str) -> str:
    return zh if _UI_LANGUAGE == "zh" else en


class ConfigError(ValueError):
    pass


@dataclass
class ApiResponseError(Exception):
    status: int
    body: str

    def __str__(self) -> str:
        detail = self.body.strip() or "empty response body"
        return f"HTTP {self.status}: {detail[:MAX_ERROR_BODY]}"


def emit(event_type: str, **payload: Any) -> None:
    event = {"type": event_type, **payload}
    print(json.dumps(event, ensure_ascii=False, separators=(",", ":")), flush=True)


def build_url(base_url: str, endpoint: str) -> str:
    endpoint = endpoint.strip()
    if endpoint.startswith(("http://", "https://")):
        url = endpoint
    else:
        base_url = base_url.strip()
        if not base_url:
            raise ConfigError(tr("Set a Base URL.", "请填写 Base URL。"))
        url = base_url.rstrip("/") + "/" + endpoint.lstrip("/")

    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ConfigError(tr("Invalid HTTP(S) URL.", "HTTP(S) 地址无效。"))
    return url


def render_prompt(prompt: str, target_lang: str) -> str:
    return prompt.replace("${target_lang}", target_lang)


def _content_to_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
        return "".join(parts)
    return ""


def extract_choice_content(data: dict[str, Any]) -> str:
    choices = data.get("choices")
    if isinstance(choices, list) and choices:
        choice = choices[0]
        if isinstance(choice, dict):
            delta = choice.get("delta")
            if isinstance(delta, dict):
                text = _content_to_text(delta.get("content"))
                if text:
                    return text
            message = choice.get("message")
            if isinstance(message, dict):
                text = _content_to_text(message.get("content"))
                if text:
                    return text
            text = _content_to_text(choice.get("text"))
            if text:
                return text

    for key in ("output_text", "response", "text"):
        text = _content_to_text(data.get(key))
        if text:
            return text
    return ""


def extract_api_error(data: dict[str, Any]) -> str:
    error = data.get("error")
    if isinstance(error, str):
        return error
    if isinstance(error, dict):
        message = error.get("message") or error.get("detail") or error.get("type")
        if message:
            return str(message)
        return json.dumps(error, ensure_ascii=False)
    return ""


def _iter_sse_payloads(response: Any) -> Iterable[str]:
    while True:
        raw_line = response.readline(MAX_SSE_LINE + 1)
        if not raw_line:
            return
        if len(raw_line) > MAX_SSE_LINE:
            raise RuntimeError(tr("SSE line exceeds 4 MiB.", "SSE 单行超过 4 MiB。"))
        line = raw_line.decode("utf-8", errors="replace").strip()
        if not line or line.startswith(":") or line.startswith("event:"):
            continue
        if line.startswith("data:"):
            yield line[5:].strip()
        else:
            yield line


def _parse_json(text: str) -> dict[str, Any]:
    value = json.loads(text)
    if not isinstance(value, dict):
        raise ValueError("API response is not a JSON object")
    return value


def _request(
    url: str,
    headers: dict[str, str],
    payload: dict[str, Any],
    timeout: float,
) -> bool:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")

    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as exc:
        try:
            error_body = exc.read(MAX_ERROR_BODY).decode("utf-8", errors="replace")
        finally:
            exc.close()
        raise ApiResponseError(exc.code, error_body) from exc

    with response:
        content_type = response.headers.get("Content-Type", "").lower()
        streaming = bool(payload.get("stream"))

        if streaming or "text/event-stream" in content_type:
            has_translation = False
            for event_payload in _iter_sse_payloads(response):
                if event_payload == "[DONE]":
                    break
                try:
                    data = _parse_json(event_payload)
                except (json.JSONDecodeError, ValueError):
                    continue
                api_error = extract_api_error(data)
                if api_error:
                    raise RuntimeError(api_error)
                delta = extract_choice_content(data)
                if delta:
                    has_translation = has_translation or bool(delta.strip())
                    emit("delta", text=delta)
            return has_translation

        raw_bytes = response.read(MAX_RESPONSE_BODY + 1)
        if len(raw_bytes) > MAX_RESPONSE_BODY:
            raise RuntimeError(tr("Response exceeds 16 MiB.", "响应超过 16 MiB。"))
        data = _parse_json(raw_bytes.decode("utf-8", errors="replace"))
        api_error = extract_api_error(data)
        if api_error:
            raise RuntimeError(api_error)
        text = extract_choice_content(data)
        if text:
            emit("delta", text=text)
        return bool(text.strip())


def run(config: dict[str, Any]) -> None:
    global _UI_LANGUAGE
    _UI_LANGUAGE = "zh" if str(config.get("ui_language") or "en") == "zh" else "en"

    base_url = str(config.get("base_url") or "")
    endpoint = str(config.get("endpoint") or "/chat/completions")
    api_key = str(config.get("api_key") or "")
    model = str(config.get("model") or "").strip()
    source_text = str(config.get("text") or "").strip()
    target_lang = str(config.get("target_lang") or "Chinese (Simplified)").strip()
    prompt = str(config.get("prompt") or "").strip()
    streaming = bool(config.get("stream", True))

    try:
        timeout = max(5.0, min(float(config.get("timeout") or 120), 600.0))
    except (TypeError, ValueError):
        timeout = 120.0

    if not source_text:
        raise ConfigError(tr("Selection is empty.", "划词内容为空。"))
    if len(source_text) > MAX_INPUT_CHARS:
        raise ConfigError(tr("Text exceeds 100k characters.", "文本超过 10 万字符。"))
    if not prompt:
        raise ConfigError(tr("Prompt is empty.", "提示词为空。"))

    url = build_url(base_url, endpoint)
    headers = {
        "Accept": "text/event-stream, application/json",
        "Content-Type": "application/json",
        "User-Agent": "DankTranslateAI/1.0.0",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    payload: dict[str, Any] = {
        "messages": [
            {"role": "system", "content": render_prompt(prompt, target_lang)},
            {"role": "user", "content": source_text},
        ],
        "stream": streaming,
    }
    if model:
        payload["model"] = model

    emit("meta", url=url, model=model, streaming=streaming)
    try:
        has_translation = _request(url, headers, payload, timeout)
    except ApiResponseError as exc:
        body_lower = exc.body.lower()
        if streaming and exc.status in {400, 422} and "stream" in body_lower:
            payload["stream"] = False
            emit("meta", url=url, model=model, streaming=False, fallback=True)
            has_translation = _request(url, headers, payload, timeout)
        else:
            raise

    if not has_translation:
        raise RuntimeError(tr("Empty translation.", "译文为空。"))
    emit("done")


def main() -> int:
    try:
        raw = sys.stdin.readline()
        if not raw:
            raise ConfigError(tr("Missing request.", "缺少请求。"))
        config = json.loads(raw)
        if not isinstance(config, dict):
            raise ConfigError(tr("Invalid request.", "请求无效。"))
        run(config)
        return 0
    except json.JSONDecodeError as exc:
        emit("error", message=tr(f"Invalid request JSON: {exc}", f"请求 JSON 无效：{exc}"))
    except ConfigError as exc:
        emit("error", message=str(exc))
    except ApiResponseError as exc:
        emit("error", message=str(exc))
    except urllib.error.URLError as exc:
        emit("error", message=tr(f"Connection failed: {exc.reason}", f"连接失败：{exc.reason}"))
    except (TimeoutError, socket.timeout):
        emit("error", message=tr("Request timed out.", "请求超时。"))
    except Exception as exc:  # Keep protocol errors visible in the popup.
        emit("error", message=tr(f"Translation failed: {exc}", f"翻译失败：{exc}"))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
