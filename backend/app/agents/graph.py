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


class AgentState(TypedDict, total=False):
    """Typed state threaded through the agent graph.

    ``path`` accumulates the ordered list of visited nodes — useful for
    debugging and for asserting routing behaviour in tests.
    """

    # --- inputs ---
    query: str
    ticker: str
    analysis_type: str
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
    """Classify the query and select one of three routing paths."""
    analysis_type = (state.get("analysis_type") or "").strip().lower()
    route = _ROUTE_MAP.get(analysis_type, DEFAULT_ROUTE)
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
