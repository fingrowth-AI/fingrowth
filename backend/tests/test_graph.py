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

    monkeypatch.setattr("app.agents.researcher.get_company_filings", _empty)
    monkeypatch.setattr("app.agents.researcher.get_daily_prices", _empty)
    monkeypatch.setattr("app.agents.researcher.get_company_news", _empty)


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
    """General: router -> researcher -> risk_critic (no analyst)."""
    result = _run("general")
    assert result["route"] == "general_research"
    assert result["path"] == ["router", "researcher", "risk_critic"]
    assert "analyst" not in result["path"]


# ---------------------------------------------------------------------------
# Unknown / missing type defaults to general_research
# ---------------------------------------------------------------------------


def test_unknown_type_defaults_to_general_research():
    result = _run("astrology")
    assert result["route"] == "general_research"
    assert result["path"] == ["router", "researcher", "risk_critic"]


def test_missing_type_defaults_to_general_research():
    result = _run(None)
    assert result["route"] == "general_research"
    assert result["path"] == ["router", "researcher", "risk_critic"]


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------


def test_graph_visualization_renders():
    """A Mermaid diagram is available for debugging."""
    mermaid = render_graph_mermaid()
    for node in ("router", "researcher", "analyst", "risk_critic"):
        assert node in mermaid
