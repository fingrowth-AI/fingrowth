"""Disclaimer + compliance middleware (P6-03).

Guarantees that every AnalysisResponse leaving the API carries the approved
legal disclaimer, regardless of what the pipeline produced. This is the final
compliance gate: even if a future endpoint change drops or empties the
disclaimer, the user never sees a recommendation-shaped payload without it.

The only AnalysisResponse on the wire is the SSE ``final_result`` frame from
the streaming analysis endpoint, so this is a pure-ASGI middleware that rewrites
that one frame in-stream. It is deliberately NOT a BaseHTTPMiddleware: that
buffers the whole response body, which would defeat SSE's incremental delivery.
Frames are forwarded as they complete (at most one partial frame is buffered),
and every non-final_result frame passes through byte-for-byte unchanged.
"""

from __future__ import annotations

import json
from collections.abc import Awaitable, Callable
from typing import Any

from app.models.risk import STANDARD_DISCLAIMER

Message = dict[str, Any]
Send = Callable[[Message], Awaitable[None]]

_FRAME_SEP = "\n\n"


def _enforce_disclaimer(frame: str) -> str:
    """Ensure a ``final_result`` SSE frame's payload has the approved disclaimer.

    Non-final_result frames, and any frame whose data isn't a JSON object, are
    returned unchanged. The rewrite is idempotent: a frame that already carries
    the approved disclaimer is left as-is.
    """
    lines = frame.split("\n")
    event_name: str | None = None
    data_index: int | None = None
    for i, line in enumerate(lines):
        if line.startswith("event:"):
            event_name = line[len("event:") :].strip()
        elif line.startswith("data:"):
            data_index = i

    if event_name != "final_result" or data_index is None:
        return frame

    raw = lines[data_index][len("data:") :].strip()
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return frame  # never break the stream on a malformed frame

    if not isinstance(payload, dict):
        return frame
    if payload.get("disclaimer") == STANDARD_DISCLAIMER:
        return frame  # already compliant

    payload["disclaimer"] = STANDARD_DISCLAIMER
    lines[data_index] = "data: " + json.dumps(payload)
    return "\n".join(lines)


class _StreamRewriter:
    """Per-request ASGI ``send`` wrapper that enforces the disclaimer on
    ``final_result`` frames of an event-stream response."""

    def __init__(self, send: Send) -> None:
        self._send = send
        self._is_event_stream = False
        self._buffer = ""

    async def __call__(self, message: Message) -> None:
        msg_type = message["type"]

        if msg_type == "http.response.start":
            content_type = b""
            for key, value in message.get("headers", []):
                if key.lower() == b"content-type":
                    content_type = value
                    break
            self._is_event_stream = b"text/event-stream" in content_type.lower()
            await self._send(message)
            return

        if msg_type != "http.response.body" or not self._is_event_stream:
            await self._send(message)
            return

        # Event-stream body: accumulate, forward complete frames as they close,
        # keep only the trailing partial frame buffered.
        self._buffer += message.get("body", b"").decode("utf-8", errors="replace")
        more_body = message.get("more_body", False)

        frames = self._buffer.split(_FRAME_SEP)
        self._buffer = frames.pop()  # trailing partial (or "")

        for frame in frames:
            if not frame:
                continue
            out = (_enforce_disclaimer(frame) + _FRAME_SEP).encode("utf-8")
            await self._send({"type": "http.response.body", "body": out, "more_body": True})

        if not more_body:
            tail = self._buffer
            self._buffer = ""
            text = _enforce_disclaimer(tail) if tail.strip() else tail
            await self._send(
                {"type": "http.response.body", "body": text.encode("utf-8"), "more_body": False}
            )


class DisclaimerMiddleware:
    """ASGI middleware enforcing the approved disclaimer on AnalysisResponses."""

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: Message, receive: Callable, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        await self.app(scope, receive, _StreamRewriter(send))
