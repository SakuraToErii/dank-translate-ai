#!/usr/bin/env python3
"""Read a bounded plain-text Wayland selection for Dank Translate AI."""

from __future__ import annotations

import codecs
import math
import re
import subprocess
import sys
from collections import Counter
from typing import BinaryIO, Iterable


DEFAULT_MAX_CHARS = 100_000
MAX_MIME_OUTPUT = 64 * 1024
TEXT_MIME_CANDIDATES = (
    "text/plain;charset=utf-8",
    "utf8_string",
    "text/plain",
    "text",
    "string",
)
SENSITIVE_MIME_MARKERS = (
    "password",
    "secret",
    "credential",
    "keepass",
    "bitwarden",
    "1password",
)
SENSITIVE_LABEL_RE = re.compile(
    r'''(?ix)
    ["']?
    (?:password|passwd|pwd|passphrase|secret|client[_-]?secret|api[_-]?key|
       access[_-]?token|refresh[_-]?token|auth[_-]?token|authorization|
       private[_-]?key|mnemonic|seed[_-]?phrase|recovery[_-]?phrase)
    ["']?\s*[:=]\s*["']?([^\s"',;}]{1,})
    '''
)
KNOWN_SECRET_PATTERNS = (
    re.compile(r"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----"),
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"\bsk-(?:proj-|live-|test-)?[A-Za-z0-9_-]{16,}\b"),
    re.compile(r"\b(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    re.compile(r"\b(?:sk|rk)_live_[A-Za-z0-9]{12,}\b"),
    re.compile(r"(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis)://[^\s:/]+:[^\s/@]+@"),
    re.compile(r"(?i)[?&](?:token|api[_-]?key|access[_-]?token|auth)=[^\s&#]{8,}"),
    re.compile(r"(?i)\b(?:seed|mnemonic|recovery)\s+(?:phrase|words?)\s*[:=]"),
)
COMMON_PASSWORD_RE = re.compile(
    r"(?i)^(?:password|passw0rd|p@ssw0rd|qwerty|letmein|welcome|admin|iloveyou|abc123|hunter2|dragon|monkey|football|baseball|master|sunshine|princess|starwars)[!@#$%^&*()_+\-=0-9]*$"
)


def choose_text_mime(mime_types: Iterable[str]) -> str | None:
    available = {mime.strip().lower(): mime.strip() for mime in mime_types if mime.strip()}
    for candidate in TEXT_MIME_CANDIDATES:
        if candidate in available:
            return available[candidate]
    return None


def read_limited_text(stream: BinaryIO, max_chars: int) -> str | None:
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    parts: list[str] = []
    char_count = 0

    while True:
        chunk = stream.read(8192)
        if not chunk:
            break
        text = decoder.decode(chunk)
        char_count += len(text)
        if char_count > max_chars:
            return None
        parts.append(text)

    tail = decoder.decode(b"", final=True)
    if char_count + len(tail) > max_chars:
        return None
    parts.append(tail)
    return "".join(parts)


def looks_like_file_list(text: str, mime_types: Iterable[str]) -> bool:
    lowered_types = {mime.strip().lower() for mime in mime_types}
    advertises_files = bool(
        {"text/uri-list", "x-special/gnome-copied-files"} & lowered_types
    )
    if not advertises_files:
        return False
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return bool(lines) and all(
        line.startswith("file://") or line in {"copy", "cut"} for line in lines
    )


def has_sensitive_mime(mime_types: Iterable[str]) -> bool:
    for mime in mime_types:
        lowered = mime.strip().lower()
        if any(marker in lowered for marker in SENSITIVE_MIME_MARKERS):
            return True
    return False


def shannon_entropy(value: str) -> float:
    if not value:
        return 0.0
    length = len(value)
    return -sum(
        (count / length) * math.log2(count / length)
        for count in Counter(value).values()
    )


def looks_like_standalone_secret(text: str) -> bool:
    token = text.strip().strip('"\'')
    if not token or len(token) > 512:
        return False
    compact_numeric = re.sub(r"[\s-]", "", token)
    if re.fullmatch(r"[\d\s-]+", token) and 4 <= len(compact_numeric) <= 12:
        return True
    if any(char.isspace() for char in token):
        return False
    if re.fullmatch(r"https?://[^\s]+", token, flags=re.IGNORECASE):
        return False
    if re.fullmatch(r"\d{4,12}", token):
        return True
    if COMMON_PASSWORD_RE.fullmatch(token):
        return True
    if token.isalpha():
        return False
    if re.fullmatch(r"[A-Fa-f0-9]{32,}", token):
        return True

    has_lower = any(char.islower() for char in token)
    has_upper = any(char.isupper() for char in token)
    has_digit = any(char.isdigit() for char in token)
    has_symbol = any(not char.isalnum() for char in token)
    categories = sum((has_lower, has_upper, has_digit, has_symbol))
    entropy = shannon_entropy(token)
    if (
        6 <= len(token) <= 128
        and token.isalnum()
        and has_digit
        and (has_lower or has_upper)
        and entropy >= 2.5
    ):
        return True
    if len(token) >= 8 and has_digit and categories == 4 and entropy >= 2.8:
        return True
    if len(token) >= 12 and has_digit and categories >= 3 and entropy >= 3.0:
        return True
    if len(token) >= 20 and has_digit and categories >= 2 and entropy >= 3.6:
        return True
    return len(token) >= 24 and has_digit and entropy >= 4.0


def looks_sensitive(text: str, mime_types: Iterable[str] = ()) -> bool:
    if has_sensitive_mime(mime_types):
        return True
    if SENSITIVE_LABEL_RE.search(text):
        return True
    if any(pattern.search(text) for pattern in KNOWN_SECRET_PATTERNS):
        return True
    return looks_like_standalone_secret(text)


def list_mime_types(primary: bool) -> list[str]:
    command = ["wl-paste"]
    if primary:
        command.append("--primary")
    command.append("--list-types")
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0 or len(result.stdout) > MAX_MIME_OUTPUT:
        return []
    return result.stdout.decode("utf-8", errors="replace").splitlines()


def capture(primary: bool, max_chars: int, protect_sensitive: bool = False) -> int:
    mime_types = list_mime_types(primary)
    if protect_sensitive and has_sensitive_mime(mime_types):
        return 6
    mime = choose_text_mime(mime_types)
    if not mime:
        return 2

    command = ["wl-paste"]
    if primary:
        command.append("--primary")
    command.extend(["--no-newline", "--type", mime])

    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return 5
    try:
        if process.stdout is None:
            return 5
        text = read_limited_text(process.stdout, max_chars)
        if text is None:
            process.terminate()
            return 3
        return_code = process.wait(timeout=3)
        if return_code != 0 or not text.strip():
            return 4
        if looks_like_file_list(text, mime_types):
            return 2
        if protect_sensitive and looks_sensitive(text, mime_types):
            return 6
        sys.stdout.write(text)
        sys.stdout.flush()
        return 0
    except subprocess.TimeoutExpired:
        process.kill()
        return 5
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        if process.stdout is not None:
            process.stdout.close()


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "primary"
    try:
        max_chars = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_CHARS
    except ValueError:
        max_chars = DEFAULT_MAX_CHARS
    max_chars = max(1, min(max_chars, DEFAULT_MAX_CHARS))
    protect_sensitive = len(sys.argv) > 3 and sys.argv[3] == "protect-sensitive"
    return capture(mode == "primary", max_chars, protect_sensitive)


if __name__ == "__main__":
    raise SystemExit(main())
