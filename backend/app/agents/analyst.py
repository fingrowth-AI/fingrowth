"""Analyst agent.

P3-01 ships a stub so the graph compiles and routing can be exercised
end to end.  The full implementation — deterministic technical analysis
plus LLM narration — lands in P3-03.
"""

from __future__ import annotations

from typing import Any


def analyst_node(state: dict[str, Any]) -> dict[str, Any]:
    """Analyse the research packet (stub: P3-03 implements the real logic)."""
    return {"path": ["analyst"], "analysis": {}}
