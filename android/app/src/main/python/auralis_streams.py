"""Resolve a public web video using the yt-dlp packaged in the Android build."""

import json
import os
from urllib.parse import urlsplit

import yt_dlp


class _SilentLogger:
    def debug(self, message):
        pass

    def warning(self, message):
        pass

    def error(self, message):
        pass


def resolve(url, format_selector, quickjs):
    address = urlsplit(url)
    if address.scheme not in {"http", "https"} or not address.hostname or address.username:
        raise ValueError("Unsupported video URL")
    if not format_selector or len(format_selector) > 2048:
        raise ValueError("Invalid format selector")

    options = {
        "format": format_selector,
        "noplaylist": True,
        "extract_flat": False,
        "socket_timeout": 8,
        "retries": 1,
        "extractor_retries": 1,
        "cachedir": False,
        "quiet": True,
        "no_warnings": True,
        "logger": _SilentLogger(),
        "js_runtimes": {"quickjs": {"path": quickjs}}
        if os.path.isfile(quickjs) and os.access(quickjs, os.X_OK)
        else {},
        "remote_components": set(),
    }
    with yt_dlp.YoutubeDL(options) as resolver:
        data = resolver.extract_info(url, download=False)
    if not data:
        raise ValueError("No playable video found")

    def track(entry):
        return {key: entry.get(key) for key in ("url", "vcodec", "acodec", "http_headers")}

    formats = data.get("requested_formats") or []
    return json.dumps({
        **track(data),
        "title": data.get("title"),
        "requested_formats": [track(entry) for entry in formats[:2]],
    })
