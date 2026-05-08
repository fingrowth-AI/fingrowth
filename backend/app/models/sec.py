"""Domain models for SEC EDGAR data (P2-01).

These mirror the JSON shapes returned by data.sec.gov submissions and XBRL
endpoints, normalized for downstream agents/tools.
"""

from __future__ import annotations

from datetime import date

from pydantic import BaseModel, Field


class Filing(BaseModel):
    """A single SEC filing entry from /submissions/CIK{cik}.json."""

    accession_number: str
    form: str  # e.g. "10-K", "10-Q", "4", "13F-HR"
    filing_date: date
    report_date: date | None = None
    primary_document: str | None = None
    cik: str  # 10-digit zero-padded


class FinancialFact(BaseModel):
    """One reported XBRL fact (concept + value + period)."""

    concept: str  # e.g. "us-gaap:Revenues"
    label: str | None = None
    unit: str  # e.g. "USD", "shares"
    value: float
    period_start: date | None = None
    period_end: date
    form: str  # source form, e.g. "10-K" or "10-Q"
    accession_number: str | None = None


class FinancialData(BaseModel):
    """Aggregated financial facts for a single CIK + form_type filter."""

    cik: str
    entity_name: str | None = None
    form_type: str  # "10-K" or "10-Q"
    facts: list[FinancialFact] = Field(default_factory=list)


class InsiderTrade(BaseModel):
    """Form 4 insider-transaction filing metadata.

    The doc itself (XML) carries transaction details; this struct exposes the
    filing entry so callers can fetch the document on demand.
    """

    accession_number: str
    filing_date: date
    cik: str
    primary_document: str | None = None
