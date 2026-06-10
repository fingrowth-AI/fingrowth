"""P3-01: LangGraph state machine for the multi-agent reasoning system.

Four nodes — Router, Researcher, Analyst, Risk Critic — wired into a graph
with three routing paths:

    fundamental_analysis : router -> researcher -> analyst -> risk_critic
    technical_analysis   : router -> researcher -> analyst -> risk_critic
    general_research     : router -> researcher -> general -> risk_critic

The Router classifies the query type; an unknown type falls back to
``general_research``.  The Researcher, Analyst and Risk Critic node bodies are
stubs here — they are fleshed out in P3-02, P3-03 and P3-04 respectively.
"""

from __future__ import annotations

import re
from operator import add
from typing import Annotated, Any, TypedDict

from langgraph.graph import END, START, StateGraph

from app.agents.analyst import analyst_node
from app.agents.general import general_node
from app.agents.researcher import researcher_node
from app.agents.risk_critic import risk_critic_node

# Map the AnalysisQuery.analysis_type input to an internal routing path.
_ROUTE_MAP = {
    "fundamental": "fundamental_analysis",
    "technical": "technical_analysis",
    "general": "general_research",
}
DEFAULT_ROUTE = "general_research"

# Routes that require deterministic technical analysis (the Analyst node).
_ANALYST_ROUTES = ("fundamental_analysis", "technical_analysis")

# ---------------------------------------------------------------------------
# Query-text classification (the design doc's "Router classifies query type")
#
# The request's analysis_type is a *hint*: the iOS picker may carry a stale
# auto-detection or a default, and other clients may not classify at all. The
# Router therefore classifies the query text itself with the same deterministic
# cue vocabulary as the on-device V12-04 classifier, and only falls back to the
# requested type when the text is inconclusive. An explicit user override
# (type_overridden=True) always wins — the user's choice is never second-guessed.
# ---------------------------------------------------------------------------

_FUNDAMENTAL_CUES = (
    "earnings", "revenue", "eps", "quarter", "quarterly", "guidance",
    "valuation", "p/e", "pe ratio", "profit", "profits", "margin", "margins",
    "dividend", "balance sheet", "cash flow", "10-k", "10-q", "filing",
    "filings", "income statement", "net income", "book value", "fundamental",
    "fundamentals", "financials", "moat", "sales", "growth",
)
_TECHNICAL_CUES = (
    "rsi", "macd", "bollinger", "moving average", "sma", "ema", "overbought",
    "oversold", "momentum", "support", "resistance", "trend", "trending",
    "breakout", "technical", "chart", "charts", "candlestick", "death cross",
    "golden cross", "50-day", "200-day", "price action", "volume",
)


def _cue_patterns(cues: tuple[str, ...]) -> tuple[re.Pattern[str], ...]:
    # Word-bounded so short cues ("eps", "sma") don't match inside other words.
    return tuple(
        re.compile(rf"\b{re.escape(cue)}\b", re.IGNORECASE) for cue in cues
    )


_FUNDAMENTAL_PATTERNS = _cue_patterns(_FUNDAMENTAL_CUES)
_TECHNICAL_PATTERNS = _cue_patterns(_TECHNICAL_CUES)


def classify_query_route(query: str) -> str | None:
    """Deterministic route from the query text; None when inconclusive.

    Counts *distinct* cue hits per side; the side with more wins, a tie (or no
    cues at all) is inconclusive. Mirrors the iOS V12-04 classifier so device
    and server agree on the common cases.
    """
    if not query:
        return None
    fundamental = sum(1 for p in _FUNDAMENTAL_PATTERNS if p.search(query))
    technical = sum(1 for p in _TECHNICAL_PATTERNS if p.search(query))
    if fundamental > technical:
        return "fundamental_analysis"
    if technical > fundamental:
        return "technical_analysis"
    return None


class AgentState(TypedDict, total=False):
    """Typed state threaded through the agent graph.

    ``path`` accumulates the ordered list of visited nodes — useful for
    debugging and for asserting routing behaviour in tests.
    """

    # --- inputs ---
    query: str
    ticker: str
    analysis_type: str
    # True when the user explicitly picked the analysis type in the client
    # (V12-04 override); the Router then never reclassifies from the query text.
    type_overridden: bool
    portfolio_profile: dict[str, Any] | None
    # V12-06: the user's recalled prior analyses (PII-free narrative summaries),
    # declared so LangGraph threads them to the Analyst — undeclared keys are
    # dropped. Empty when memory is off or nothing relevant was recalled.
    prior_analyses: list[dict[str, Any]]
    session_id: str
    # Owner of the request (V7-05). Declared so LangGraph threads it through the
    # typed state — undeclared keys are dropped — letting V8 persistence nodes
    # attribute work to the authenticated user. Default user until V8.
    user_id: str
    # --- router output ---
    route: str
    # --- agent outputs ---
    research: dict[str, Any]
    analysis: dict[str, Any]
    risk_review: dict[str, Any]
    # --- debug trace ---
    path: Annotated[list[str], add]


def router_node(state: AgentState) -> dict[str, Any]:
    """Classify the query and select one of three routing paths.

    Priority: an explicit user override > the query text's own signal > the
    requested analysis_type > the general default. This is what makes an
    earnings question route to fundamental analysis even when the client sent
    a stale or defaulted type.
    """
    analysis_type = (state.get("analysis_type") or "").strip().lower()
    requested = _ROUTE_MAP.get(analysis_type, DEFAULT_ROUTE)
    if state.get("type_overridden"):
        return {"route": requested, "path": ["router"]}
    route = classify_query_route(state.get("query", "")) or requested
    return {"route": route, "path": ["router"]}


def _route_after_researcher(state: AgentState) -> str:
    """Fundamental & technical analysis run the Analyst; general runs the
    lightweight general-research narrator. Both then hit the Risk Critic."""
    if state.get("route") in _ANALYST_ROUTES:
        return "analyst"
    return "general"


def build_graph() -> StateGraph:
    """Construct the (uncompiled) agent ``StateGraph``."""
    graph = StateGraph(AgentState)

    graph.add_node("router", router_node)
    graph.add_node("researcher", researcher_node)
    graph.add_node("analyst", analyst_node)
    graph.add_node("general", general_node)
    graph.add_node("risk_critic", risk_critic_node)

    graph.add_edge(START, "router")
    graph.add_edge("router", "researcher")
    graph.add_conditional_edges(
        "researcher",
        _route_after_researcher,
        {"analyst": "analyst", "general": "general"},
    )
    graph.add_edge("analyst", "risk_critic")
    graph.add_edge("general", "risk_critic")
    graph.add_edge("risk_critic", END)

    return graph


def compile_graph():
    """Compile the agent graph into an executable runnable."""
    return build_graph().compile()


# Module-level compiled graph reused by the API layer (P3-05).
agent_graph = compile_graph()


def render_graph_mermaid() -> str:
    """Return a Mermaid diagram of the compiled graph for debugging."""
    return agent_graph.get_graph().draw_mermaid()
