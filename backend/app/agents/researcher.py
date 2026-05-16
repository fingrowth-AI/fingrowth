"""Researcher agent.

P3-01 ships a stub so the graph compiles and routing can be exercised
end to end.  The full implementation — gathering filings, news and price
data with source attribution — lands in P3-02.
"""

from __future__ import annotations

from typing import Any


def researcher_node(state: dict[str, Any]) -> dict[str, Any]:
    """Gather research for the query (stub: P3-02 implements the real logic)."""
    return {"path": ["researcher"], "research": {}}
