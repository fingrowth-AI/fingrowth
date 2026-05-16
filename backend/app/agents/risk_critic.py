"""Risk Critic agent.

P3-01 ships a stub so the graph compiles and routing can be exercised
end to end.  The full implementation — the mandatory guardrail reviewing
every analysis report — lands in P3-04.
"""

from __future__ import annotations

from typing import Any


def risk_critic_node(state: dict[str, Any]) -> dict[str, Any]:
    """Review the analysis (stub: P3-04 implements the real guardrail)."""
    return {"path": ["risk_critic"], "risk_review": {"approved": True, "flags": []}}
