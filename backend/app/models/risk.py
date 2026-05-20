"""Domain models for the Risk Critic agent (P3-04).

The Risk Critic returns a :class:`RiskReview` for every :class:`AnalysisReport`
it audits. The review records the compliance decision (``approved``), the
specific violations detected (``flags``), the narrative the critic deems
shareable (``modified_response``), and the standing regulatory ``disclaimer``
that must accompany every research output.

The disclaimer text lives here — not at the API edge — so the guardrail and
the public response cannot drift apart.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

# The disclaimer mandated by section 10.2 of the design doc. The Risk Critic
# attaches this to every review; the API response model re-exports it so the
# wire format and the guardrail decision reference one source of truth.
STANDARD_DISCLAIMER = (
    "This analysis is for informational and research purposes only. "
    "It does not constitute investment advice, a recommendation, or "
    "solicitation to buy or sell any security. Past performance does "
    "not guarantee future results. Consult a qualified financial "
    "advisor before making investment decisions."
)

# Closed set of compliance flag codes. Encoded as a Literal so the rejection
# rules in agents/risk_critic.py can use a plain frozenset membership test
# and a new code added here must be deliberately classified there.
RiskFlagCode = Literal[
    "future_price_claim",
    "buy_sell_recommendation",
    "excessive_confidence",
    "missing_disclaimer",
    "unsupported_numeric_claim",
]


class RiskFlag(BaseModel):
    """A single compliance violation surfaced by the critic.

    ``detail`` carries the offending substring (or, for code-driven flags
    like ``missing_disclaimer``, a short reason) so a human reviewer can
    audit decisions without re-running the model.
    """

    code: RiskFlagCode
    detail: str


class RiskReview(BaseModel):
    """Outcome of the Risk Critic for one :class:`AnalysisReport`.

    ``modified_response`` is the narrative downstream consumers should
    display: on approval it mirrors the analyst's narrative, on rejection it
    is replaced with a safe default. ``disclaimer`` is always populated —
    the "missing disclaimer: appended automatically" acceptance criterion
    is satisfied at the model level, not by remembering to add it in every
    code path.
    """

    approved: bool = True
    flags: list[RiskFlag] = Field(default_factory=list)
    modified_response: str = ""
    disclaimer: str = STANDARD_DISCLAIMER
