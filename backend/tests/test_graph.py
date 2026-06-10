"""Tests for P3-01: LangGraph state machine."""

from __future__ import annotations

import pytest

from app.agents.graph import (
    AgentState,
    agent_graph,
    build_graph,
    compile_graph,
    render_graph_mermaid,
)


@pytest.fixture(autouse=True)
def _stub_researcher_tools(monkeypatch):
    """Keep routing tests offline — the P3-02 researcher node does real I/O.

    These tests assert routing/topology only, so the data tools are stubbed to
    return nothing. Researcher behaviour itself is covered by test_researcher.
    """

    async def _empty(*args, **kwargs):
        return []

    async def _none(*args, **kwargs):
        return None

    monkeypatch.setattr("app.agents.researcher.get_company_filings", _empty)
    monkeypatch.setattr("app.agents.researcher.get_daily_prices", _empty)
    monkeypatch.setattr("app.agents.researcher.get_company_news", _empty)
    # The fundamental route additionally fetches XBRL facts + the overview.
    monkeypatch.setattr("app.agents.researcher.ticker_to_cik", _none)
    monkeypatch.setattr("app.agents.researcher.get_financial_statements", _none)
    monkeypatch.setattr("app.agents.researcher.get_company_overview", _none)


def _run(analysis_type: str | None) -> AgentState:
    state: AgentState = {"query": "Is it healthy?", "ticker": "AAPL"}
    if analysis_type is not None:
        state["analysis_type"] = analysis_type
    return agent_graph.invoke(state)


# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------


def test_graph_compiles_without_error():
    """build_graph().compile() must succeed."""
    assert compile_graph() is not None
    assert build_graph() is not None


def test_module_level_graph_is_compiled():
    """The reusable agent_graph is compiled and invokable."""
    result = agent_graph.invoke({"query": "q", "ticker": "AAPL"})
    assert "path" in result


def test_user_id_is_threaded_to_nodes():
    """V7-05: user_id is declared in AgentState, so a node can read it and it
    survives in state. (LangGraph drops keys not declared in the typed state,
    which is why the declaration matters.)"""
    from langgraph.graph import END, START, StateGraph

    seen: dict[str, str] = {}

    def _reader(state: AgentState) -> dict:
        seen["user_id"] = state.get("user_id", "<missing>")
        return {}

    graph = StateGraph(AgentState)
    graph.add_node("reader", _reader)
    graph.add_edge(START, "reader")
    graph.add_edge("reader", END)
    compiled = graph.compile()

    result = compiled.invoke(
        {"query": "q", "ticker": "AAPL", "user_id": "user-123"}
    )

    assert seen["user_id"] == "user-123"  # the node actually saw it
    assert result.get("user_id") == "user-123"  # and it persisted in state


# ---------------------------------------------------------------------------
# Routing paths
# ---------------------------------------------------------------------------


def test_fundamental_path():
    """Fundamental: router -> researcher -> analyst -> risk_critic."""
    result = _run("fundamental")
    assert result["route"] == "fundamental_analysis"
    assert result["path"] == ["router", "researcher", "analyst", "risk_critic"]


def test_technical_path():
    """Technical analysis also runs the Analyst node."""
    result = _run("technical")
    assert result["route"] == "technical_analysis"
    assert result["path"] == ["router", "researcher", "analyst", "risk_critic"]


def test_general_path_skips_analyst():
    """General: router -> researcher -> general -> risk_critic (no analyst)."""
    result = _run("general")
    assert result["route"] == "general_research"
    assert result["path"] == ["router", "researcher", "general", "risk_critic"]
    assert "analyst" not in result["path"]


# ---------------------------------------------------------------------------
# Unknown / missing type defaults to general_research
# ---------------------------------------------------------------------------


def test_unknown_type_defaults_to_general_research():
    result = _run("astrology")
    assert result["route"] == "general_research"
    assert result["path"] == ["router", "researcher", "general", "risk_critic"]


def test_missing_type_defaults_to_general_research():
    result = _run(None)
    assert result["route"] == "general_research"
    assert result["path"] == ["router", "researcher", "general", "risk_critic"]


# ---------------------------------------------------------------------------
# Router classifies the query text (the design doc's "Router classifies query
# type") — the requested analysis_type is a hint unless the user overrode it.
# ---------------------------------------------------------------------------


def _run_query(query: str, analysis_type: str, **extra) -> AgentState:
    state: AgentState = {
        "query": query,
        "ticker": "NVDA",
        "analysis_type": analysis_type,
        **extra,
    }
    return agent_graph.invoke(state)


def test_earnings_question_routes_to_fundamental_despite_requested_type():
    """The reported bug: an earnings question must not run as technical."""
    for requested in ("technical", "general"):
        result = _run_query("How were NVDA's latest earnings?", requested)
        assert result["route"] == "fundamental_analysis", requested
        assert "analyst" in result["path"]


def test_quarter_and_revenue_phrasings_route_to_fundamental():
    assert _run_query("What happened in the latest quarter?", "technical")[
        "route"
    ] == "fundamental_analysis"
    assert _run_query("Is revenue still growing?", "general")[
        "route"
    ] == "fundamental_analysis"


def test_technical_question_routes_to_technical_despite_requested_type():
    result = _run_query("Is the RSI overbought right now?", "general")
    assert result["route"] == "technical_analysis"


def test_user_override_is_respected_over_query_text():
    """An explicit user pick is never second-guessed by the Router."""
    result = _run_query(
        "How were NVDA's latest earnings?", "technical", type_overridden=True
    )
    assert result["route"] == "technical_analysis"


def test_inconclusive_query_falls_back_to_requested_type():
    result = _run_query("Tell me about this company", "technical")
    assert result["route"] == "technical_analysis"


def test_mixed_cue_tie_falls_back_to_requested_type():
    # One fundamental cue ("earnings") + one technical cue ("rsi") → tie.
    result = _run_query("Compare earnings with the RSI signal", "general")
    assert result["route"] == "general_research"


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------


def test_graph_visualization_renders():
    """A Mermaid diagram is available for debugging."""
    mermaid = render_graph_mermaid()
    for node in ("router", "researcher", "analyst", "risk_critic"):
        assert node in mermaid
