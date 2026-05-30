**AI Investment Strategist**

**Design Document v3.0 — Usefulness & Multi-User Pivot**

Layered changes on the completed v2.1 build

Version 3.0 | May 2026 | Status: Planning

# **Table of Contents**

# **1\. Context and Goals**

The v2.1 build is complete: all six phases shipped, the end-to-end pipeline runs, and the privacy architecture works as specified. But shipping revealed the real problem. The app produces data, not decisions. A user asks “is this stock going up or down” and receives a table of indicators plus a paragraph that restates those same numbers. The one thing that makes the app unique — that it knows your portfolio — is invisible in the output. And the privacy layer is so aggressive it discards the very specifics that would make cloud analysis useful.

This document specifies the v3.0 pivot. It is not a from-scratch rebuild; it is a set of changes layered on the working v2.1 system. Three goals drive every change below:

* **Usefulness:** turn raw indicator output into plain-language interpretation that answers the question the user actually asked.

* **Differentiation:** make portfolio awareness visible — the output should be about the user’s actual holdings, which no generic stock tool can do.

* **Multi-user:** add authentication and map each user to their own trades within the shared Alpaca paper account, so the app is more than a single-person tool.

*Each change is written as a card: current behavior, desired behavior, and testable acceptance criteria. Cards are grouped into phases ordered by dependency — trust fixes and data-model groundwork first, because everything else builds on them.*

## **1.1 What is explicitly NOT changing**

To keep scope honest, the following v2.1 decisions stand and are out of scope for v3.0:

* The deterministic math layer (RSI, MACD, Bollinger, Sharpe) stays exactly as is. It is correct and trusted. Interpretation is layered on top; the numbers are never recomputed by an LLM.

* The dual-compute topology (on-device Gemma \+ cloud agents) is unchanged. The privacy boundary stays at the device.

* The product framing remains “research tool, not advisor.” Nothing below introduces buy/sell recommendations.

* Paper trading remains simulation-only via Alpaca’s paper endpoint. No live trading, ever.

## **1.2 Revised threat model (the key conceptual shift)**

The v2.1 privacy design treated all portfolio specifics as PII and generalized them away. This was wrong on two counts: it cost analytical usefulness, and it protected almost nothing. The corrected threat model:

**The threat is the cloud learning who you are, not the cloud learning what you own.** A portfolio of “500 AAPL, 200 MSFT” describes a portfolio, not a person — millions of people could hold it. A name or account number describes a person. v3.0 protects identity rigorously and shares investment specifics freely, scoped to the query.

# **2\. Three-Tier Data Classification**

This replaces the binary “scrub everything” model. Every field the parser extracts is assigned a tier. The tier determines whether it can leave the device.

| Tier | Examples | Handling |
| :---- | :---- | :---- |
| Tier 1 — Identity | Account numbers, holder names, SSN fragments, email | Never transmitted. Hard wall. Stays in PrivateLedger. |
| Tier 2 — Portfolio specifics | Ticker symbols, share counts, sector weights, indicator values | Transmitted freely, scoped to the query. Describes a portfolio, not a person. |
| Tier 3 — Sensitive financials | Total portfolio value, cost basis, account types | User’s choice via privacy level setting. Default: bucketed, not exact. |

*The reframe makes the privacy story stronger because it is now coherent and honest: “we protect your identity, not your investment choices.” That is a clearer claim than “we generalize everything,” and it is the claim that actually matches a sound threat model.*

# **3\. Phased Change Plan**

Six phases. Phases 7 and 8 are sequenced first because they fix trust and lay the data-model and privacy groundwork everything else depends on. Phases 9–11 deliver the usefulness and differentiation work. Phase 12 is the feedback loop and polish.

## **3.1 Phase 7: Trust Fixes and Data Foundation**

*Goal: the app stops looking broken, and the schema becomes multi-user-ready. No user-visible features yet — this is the foundation the pivot stands on. Do this first.*

**\[V7-01\] Fix indicator serialization rendering**

**Current behavior:** The result detail view shows raw object placeholders — BOLLINGER {...} and MACD {...} — instead of the actual band and line values, even though the backend computed them and the summary text references them.

**Desired behavior:** Every indicator renders its real value(s). Nested objects (Bollinger bands, MACD line/signal/histogram) are unpacked into readable sub-rows.

**Acceptance criteria:**

* Bollinger row shows lower / middle / upper values, never {...}

* MACD row shows line, signal, and histogram values, never {...}

* No raw object placeholder string appears anywhere in the result UI

**\[V7-02\] Fix incorrect / stale price data**

**Current behavior:** LATEST\_CLOSE displays values that do not match the real market price (e.g. AAPL at 312.51), undermining trust in the entire result.

**Desired behavior:** Prices reflect the real most-recent close from the data source. Trace whether the bug is a stale cache, a test fixture leaking into production, or a data-source parsing error, and fix at the source.

**Acceptance criteria:**

* Latest close for a known ticker matches the actual most-recent market close within expected data-source lag

* No test fixtures are reachable from the production data path

* A staleness check rejects price data older than a configurable threshold

**\[V7-03\] Data freshness indicators**

**Current behavior:** Results show no indication of when underlying data was fetched, so users cannot tell fresh from stale.

**Desired behavior:** Each result displays a clear “as of” timestamp for its price and news data.

**Acceptance criteria:**

* Result header shows the data timestamp (e.g. “as of close 5/28”)

* Cached data shows its original fetch time, not the time it was served from cache

**\[V7-04\] User table and user\_id columns**

**Current behavior:** No users table exists. analysis\_sessions, analysis\_results, and vector\_embeddings have no user\_id column. The system is implicitly single-user.

**Desired behavior:** Add a users table and a user\_id foreign key to every per-user table. Populate with a hardcoded default user for now; real auth fills it in V8. This is the auth-shaped hole that makes V8 a fill rather than a migration.

**Acceptance criteria:**

* users table exists with id, apple\_sub (nullable for now), created\_at

* user\_id column added to analysis\_sessions, analysis\_results, vector\_embeddings via Alembic migration

* All queries filter by user\_id; default user is used until V8 lands

* alembic upgrade head and downgrade base both run cleanly

**Depends on:** v2.1 P1-03 (database models)

**\[V7-05\] Auth-shaped API contract**

**Current behavior:** API requests carry no user identification and no Authorization header.

**Desired behavior:** Every endpoint accepts an Authorization: Bearer header. The backend resolves it to a user via a single get\_current\_user() function that returns the default user for now. Call sites are written as if auth exists.

**Acceptance criteria:**

* All /api/v1 endpoints accept (and tolerate) a Bearer header

* get\_current\_user() is the single resolution point, returning default user until V8

* iOS APIClient always sends the header, even with a placeholder token

**Depends on:** V7-04

## **3.2 Phase 8: Authentication and Multi-User Trade Mapping**

*Goal: real users, each mapped to their own trades inside the single shared Alpaca paper account. This is the track you flagged as a major priority. It depends on the Phase 7 foundation.*

**\[V8-01\] Sign in with Apple**

**Current behavior:** No authentication. TestFlight access is the only gate.

**Desired behavior:** Add Sign in with Apple on iOS. Verify the Apple-issued identity token server-side, create or look up the user record, and issue your own session token for subsequent requests. No username/password is built — it is a security liability with no payoff here.

Apple-native, one-tap, privacy-respecting (hidden-email relay supported). The right choice for an Apple-facing portfolio project.

Backend verifies the JWT signature against Apple’s public keys, extracts the stable subject identifier (apple\_sub), and maps it to a user row.

**Acceptance criteria:**

* First Sign in with Apple creates a user row keyed by apple\_sub

* Returning sign-in resolves to the same user row

* Backend rejects tokens with invalid signatures or wrong audience

* Session token is issued and accepted on subsequent API calls

* Hidden-email relay users authenticate successfully

**Depends on:** V7-04, V7-05

**\[V8-02\] Per-user trade tagging in the shared Alpaca account**

**Current behavior:** All paper trades hit one shared Alpaca account with no way to attribute a trade to a user.

**Desired behavior:** Every paper order carries a client\_order\_id that encodes the user: {user\_id}\_{uuid}. A user’s positions and history are reconstructed by querying Alpaca orders and filtering by their prefix.

**Acceptance criteria:**

* Every order submitted to Alpaca includes a user-prefixed client\_order\_id

* get\_positions() for a user returns only orders matching their prefix

* Two users trading the same ticker never see each other’s positions

* Order history is correctly partitioned by user

**Depends on:** V8-01, v2.1 P2-05 (paper trading client)

**\[V8-03\] Per-user virtual cash and buying-power tracking**

**Current behavior:** The shared Alpaca account has one $100K buying-power pool. Multiple users would silently drain a shared balance, and one user could exhaust it for everyone.

**Desired behavior:** Track each user’s virtual cash balance in your own database, seeded at $100K. Validate every order against the user’s virtual balance before submitting to Alpaca. The shared account becomes an execution venue; per-user accounting lives in your DB.

**Acceptance criteria:**

* Each new user starts with a tracked $100K virtual balance

* An order exceeding a user’s virtual balance is rejected before reaching Alpaca

* One user’s trades never reduce another user’s available balance

* Virtual balance reconciles with the user’s reconstructed position value

**Depends on:** V8-02

**\[V8-04\] Per-user equity curve computation**

**Current behavior:** The performance tracker relied on Alpaca’s account-level portfolio-history endpoint, which returns the whole shared account — useless once multiple users share it.

**Desired behavior:** Compute each user’s equity curve from their own reconstructed trade log and virtual cash, not from Alpaca’s account-level history. Closed trades are preserved in the curve.

**Acceptance criteria:**

* Equity curve reflects only the requesting user’s trades

* Closed (realized) trades remain in the cumulative curve and do not vanish

* Curve can be compared against an SPY benchmark series over the same window

**Depends on:** V8-02, V8-03

**\[V8-05\] Per-user API quota allocation**

**Current behavior:** All users share one Alpha Vantage key (25 calls/day free tier). One active user starves everyone.

**Desired behavior:** Allocate per-user daily quota against the shared key, plus aggressive ticker-level caching so popular tickers are fetched once and reused across users. Surface a clear message when a user hits their allocation.

SPY and other benchmark series are fetched server-side once per day and cached, never per user.

Per-user allocation is configurable; a paid data tier later removes the constraint without code change.

**Acceptance criteria:**

* A single user cannot consume more than their allocated daily quota

* A cache hit for a ticker fetched by any user serves all users with zero additional API calls

* Quota-exhausted users get a clear, non-error message, not a crash

**Depends on:** V8-01, v2.1 P2-02 (market data client)

## **3.3 Phase 9: Privacy Model Revision**

*Goal: stop discarding useful specifics. Implement the three-tier classification so cloud analysis receives the information it needs while identity stays on-device. This unblocks the usefulness work in Phase 10\.*

**\[V9-01\] Three-tier classification in the CSV parser**

**Current behavior:** The Gemma-powered parser extracts PII but the downstream pipeline treats all portfolio specifics as if they were PII, generalizing share counts into vague descriptors.

**Desired behavior:** The parser tags every extracted field with a tier (1 identity, 2 portfolio specific, 3 sensitive financial). Only Tier 1 is hard-walled to the PrivateLedger; Tier 2 is available for query-scoped sharing; Tier 3 honors the user’s privacy-level setting.

**Acceptance criteria:**

* Account numbers and holder names are tagged Tier 1 and never leave the device

* Ticker symbols and share counts are tagged Tier 2 and available to the query pipeline

* Total value and cost basis are tagged Tier 3 and bucketed unless the user opts in

* The PIIReport lists each field with its assigned tier

**Depends on:** v2.1 P5-03 (CSV privacy parser)

**\[V9-02\] Loosen the Query Rewriter to preserve Tier 2**

**Current behavior:** The Query Rewriter strips and generalizes share counts and tickers (‘500 shares of TSLA’ → ‘concentrated position’), discarding analytical value for negligible privacy gain.

**Desired behavior:** The rewriter removes only Tier 1 identity. Tier 2 specifics relevant to the query are preserved. Tier 3 follows the user setting. The rewriter still scopes to the query — it never dumps the full ledger.

Combination guard: exact share counts plus exact cost basis plus purchase dates, all together, can fingerprint. The rewriter shares specifics relevant to THIS query, not the entire position history every time.

**Acceptance criteria:**

* ‘Should I sell my 500 TSLA shares?’ retains ‘500 shares of TSLA’ in the rewritten query; only identity is stripped

* A query needing no holdings still strips any incidental identity tokens

* The rewriter never emits more than the query-relevant subset of the ledger

* Substitutions list reflects only Tier 1 (and opted-out Tier 3\) removals

**Depends on:** V9-01, v2.1 P5-04 (query rewriter)

**\[V9-03\] Query-scoped portfolio context**

**Current behavior:** Differential Privacy generates one fixed generalized profile regardless of the question.

**Desired behavior:** Portfolio context sent to the cloud is scoped to the query. A question about a single holding sends that holding’s specifics; a portfolio-level question sends sector/concentration context. Identity is never included regardless.

**Acceptance criteria:**

* Single-ticker query sends only that ticker’s relevant specifics plus minimal context

* Portfolio-level query sends sector weights and concentration, not full per-position detail unless needed

* No Tier 1 identity appears in any outbound payload, verified by the audit log

**Depends on:** V9-02, v2.1 P5-05 (differential privacy)

## **3.4 Phase 10: Interpretation Pipeline (the core usefulness fix)**

*Goal: turn the data dump into understandable findings. The model: deterministic functions compute the numbers; the cloud LLM interprets the market data; on-device Gemma personalizes to the user’s holdings. Each layer adds a kind of understanding the previous one could not — math, then meaning, then relevance.*

### **Three-stage refinement**

1. Deterministic layer (backend functions): computes RSI, MACD, Bollinger, Sharpe exactly and reproducibly. Unchanged from v2.1.

2. Cloud interpretation (Claude/GPT): turns numbers into a readable, honest assessment of the stock — what the signals mean together, where they agree or conflict, the honest directional read. Generic to the ticker, uses only public market data.

3. On-device personalization (Gemma): turns the general assessment into what it means for this user’s actual holdings. Needs the PrivateLedger, so it stays on-device.

**\[V10-01\] Rewrite the Analyst narrative to interpret, not restate**

**Current behavior:** The Analyst narrative re-lists the computed values in sentence form (‘RSI(14) is 79.87. MACD line 10.44…’), adding no understanding.

**Desired behavior:** The Analyst prompt is rewritten so the narrative explains what the indicators mean together: agreement or conflict between signals, what ‘overbought’ implies, the honest picture. It interprets the numbers; it never recomputes or contradicts them.

**Acceptance criteria:**

* Narrative explains the meaning of each key signal, not just its value

* Narrative notes when signals conflict (e.g. RSI overbought but MACD still positive)

* Every interpretive claim is anchored to a computed value the user can verify

* Narrative never states a number that differs from the deterministic output

**Depends on:** v2.1 P3-03 (Analyst agent)

**\[V10-02\] Lead with a plain-language answer**

**Current behavior:** Results open with a table of indicators; the synthesis, if any, is buried below.

**Desired behavior:** Results open with a short, readable conclusion that addresses the user’s actual question. Indicators move below as supporting evidence the user can expand to verify.

**Acceptance criteria:**

* Result top is a plain-language assessment, not a table

* A directional question receives an honest ‘no one can reliably predict, but here is what the signals suggest’ answer, not a number dump

* Indicators remain accessible directly below as expandable evidence

**Depends on:** V10-01

**\[V10-03\] Inline interpretation per indicator**

**Current behavior:** Each indicator shows a raw value (RSI 79.87) with no meaning, and labels are database keys (LATEST\_CLOSE, SMA\_20).

**Desired behavior:** Each indicator carries a plain-language tag (RSI 79.87 → ‘Overbought’) and a tap-to-expand explanation. Labels are humanized.

**Acceptance criteria:**

* RSI, MACD, and Bollinger each show an interpretive tag alongside the value

* Tapping an indicator reveals a one-line plain explanation

* Labels read as ‘Latest close’, ‘20-day average’, ‘RSI (14-day)’ — never raw keys

* Metadata like sample size is de-emphasized or footnoted

**Depends on:** V10-01

**\[V10-04\] Strengthen the Risk Critic for richer interpretation**

**Current behavior:** The Risk Critic guards a thin restating narrative — little room to drift into advice.

**Desired behavior:** As interpretation gets richer it moves closer to the advice line. The Risk Critic prompt is tightened to allow honest interpretation (‘the signals suggest caution’) while still rejecting directive language (‘sell now’).

**Acceptance criteria:**

* Honest, hedged interpretation passes review

* Directive buy/sell language is flagged and rejected

* A future-price prediction is rejected and replaced with a safe default

* Every reviewed output still carries the standard disclaimer

**Depends on:** V10-01, v2.1 P3-04 (Risk Critic)

**\[V10-05\] Visual hierarchy and a small chart**

**Current behavior:** Indicators render as a flat list of equal weight; there is no visualization.

**Desired behavior:** Signals that matter are emphasized; metadata is de-emphasized. A small chart (price versus Bollinger bands, or a sparkline) conveys the picture faster than numbers, matching the Stocks-app aesthetic the app targets.

**Acceptance criteria:**

* Key signals are visually prominent; metadata is subdued

* A price/band or sparkline chart renders using Swift Charts (native, not a third-party lib)

* Chart adapts correctly to dark mode

**Depends on:** V10-02

## **3.5 Phase 11: Portfolio Awareness (the differentiator)**

*Goal: make the output about the user. This is the only thing a generic stock tool cannot do, and it is the entire reason the app exists. It depends on the loosened privacy model (Phase 9\) and the interpretation pipeline (Phase 10).*

**\[V11-01\] Surface on-device recontextualization**

**Current behavior:** The recontextualization machinery (v2.1 P5-08) exists but its output never appears in the result UI. The output is identical whether the user owns the stock or not.

**Desired behavior:** Add a ‘What this means for you’ section that references the user’s real positions, generated on-device by Gemma from the PrivateLedger so specifics never transit the network.

**Acceptance criteria:**

* When the user holds the analyzed ticker, the result references their actual position

* When the user does not hold it, the section is omitted gracefully

* Personalization runs entirely on-device with zero network calls

* The personalized section is additive — it never alters the cloud analysis text

**Depends on:** v2.1 P5-08, V10-02

**\[V11-02\] Concentration and risk awareness**

**Current behavior:** Results ignore how a holding fits the user’s overall portfolio.

**Desired behavior:** When analyzing a held ticker, the result notes position size and concentration and weighs the signal accordingly (e.g. ‘you are 32% in AAPL — this overbought signal matters more given that concentration’).

**Acceptance criteria:**

* Result states the user’s position size as a percentage of portfolio when relevant

* Concentration context adjusts the framing of the signal honestly, without becoming advice

* Computation uses on-device holdings; only generalized concentration may reach the cloud

**Depends on:** V11-01

**\[V11-03\] Portfolio-level analysis view**

**Current behavior:** Every analysis is single-ticker. There is no ‘how is my whole portfolio’ view.

**Desired behavior:** Add a portfolio-level analysis that summarizes diversification, sector concentration, and overall risk — the hybrid path the architecture was built for.

**Acceptance criteria:**

* A portfolio-level query returns diversification and sector-concentration findings

* The analysis uses query-scoped generalized context, never raw identity

* Findings are interpreted in plain language, consistent with Phase 10

**Depends on:** V11-02, V9-03

## **3.6 Phase 12: Feedback Loop and Usability Polish**

*Goal: deliver the product’s original soul — research a thesis, test it, learn from the outcome — and smooth the rough edges that make the app hard to approach.*

**\[V12-01\] Thesis capture on paper trades**

**Current behavior:** Paper trades record a side and quantity but no rationale, so the research-to-outcome loop has no substance.

**Desired behavior:** Placing a paper trade requires a short free-text thesis written by the user. The side is not pre-selected — the user chooses, which keeps the decision theirs and stays on the right side of the advice line.

**Acceptance criteria:**

* Thesis field is required before a paper order can be placed

* Side toggle defaults to unselected; the user must choose

* Thesis text is stored with the order and the linked analysis session\_id

**Depends on:** V8-02

**\[V12-02\] Outcome tracking and personal hit-rate**

**Current behavior:** Closed paper trades show P\&L but nothing about whether the thesis was right.

**Desired behavior:** A deterministic check marks whether the thesis direction matched the outcome within the user’s stated window, building a personal hit-rate over time.

**Acceptance criteria:**

* Closed trade shows a thesis-confirmed / not-confirmed result via a deterministic direction check

* A running hit-rate across the user’s closed theses is displayed

* Outcome labeling is not an LLM judgment

**Depends on:** V12-01, V8-04

**\[V12-03\] Bidirectional analysis–trade linking**

**Current behavior:** The link between a paper trade and the analysis that inspired it is partially specified and not reliably visible.

**Desired behavior:** From any analysis, the user can jump to the paper trade it inspired; from any paper trade, the user can open the original analysis.

**Acceptance criteria:**

* Tapping a paper trade opens its linked analysis

* An analysis that led to a trade shows a link to that trade

* Links survive app restarts (persisted, per user)

**Depends on:** V12-01

**\[V12-04\] Auto-classify analysis type with override**

**Current behavior:** The user manually picks Fundamental / Technical / General; most users do not know the difference.

**Desired behavior:** Gemma’s Intent Router classifies the analysis type on-device from the natural-language query, pre-selects it, and lets the user override.

**Acceptance criteria:**

* Natural-language query is auto-classified into the correct path in the common cases

* The classification is shown and is user-overridable

* Classification runs on-device

**Depends on:** v2.1 P5-07 (intent router)

**\[V12-05\] Onboarding, query help, and empty states**

**Current behavior:** A new user lands cold: no explanation of the privacy model or framing, a blank query box, and empty tabs with no guidance.

**Desired behavior:** First-run onboarding explains the privacy model and research-not-advice framing and walks through portfolio import. The query box offers ticker autocomplete, recent tickers, and example queries. Every tab has a helpful empty state.

**Acceptance criteria:**

* First launch shows onboarding covering privacy, framing, and CSV import

* Query input offers ticker autocomplete and example queries

* Portfolio, Privacy, and Research tabs each show a guiding empty state before data exists

**Depends on:** V11-01

**\[V12-06\] Conversation continuity via existing memory**

**Current behavior:** The pgvector conversation memory (v2.1 P6-01) is built but not used to inform follow-up questions.

**Desired behavior:** Follow-up questions reference prior analyses (‘how does this compare to when I asked last week?’) using the existing embedding store, scoped to the user.

**Acceptance criteria:**

* A follow-up retrieves the user’s relevant prior analyses

* Retrieval is scoped to the requesting user only

* Prior context visibly informs the new response when relevant

**Depends on:** v2.1 P6-01, V7-04

# **4\. Build Order Summary**

Exact implementation sequence. Estimates are rough and assume familiarity with the v2.1 codebase.

| \# | ID | Name | Est. hrs |
| :---- | :---- | :---- | :---- |
| 1 | V7-01 | Fix indicator serialization | 1 |
| 2 | V7-02 | Fix stale/incorrect price | 1.5 |
| 3 | V7-03 | Data freshness indicators | 0.5 |
| 4 | V7-04 | User table \+ user\_id columns | 2 |
| 5 | V7-05 | Auth-shaped API contract | 1.5 |
| 6 | V8-01 | Sign in with Apple | 4 |
| 7 | V8-02 | Per-user trade tagging | 2.5 |
| 8 | V8-03 | Virtual cash / buying power | 2.5 |
| 9 | V8-04 | Per-user equity curve | 2 |
| 10 | V8-05 | Per-user quota allocation | 2 |
| 11 | V9-01 | Three-tier classification | 2 |
| 12 | V9-02 | Loosen Query Rewriter | 2 |
| 13 | V9-03 | Query-scoped context | 1.5 |
| 14 | V10-01 | Analyst interprets, not restates | 2 |
| 15 | V10-02 | Lead with plain-language answer | 1.5 |
| 16 | V10-03 | Inline indicator interpretation | 2 |
| 17 | V10-04 | Strengthen Risk Critic | 1.5 |
| 18 | V10-05 | Visual hierarchy \+ chart | 2.5 |
| 19 | V11-01 | Surface recontextualization | 2.5 |
| 20 | V11-02 | Concentration awareness | 2 |
| 21 | V11-03 | Portfolio-level analysis | 3 |
| 22 | V12-01 | Thesis capture | 1.5 |
| 23 | V12-02 | Outcome tracking / hit-rate | 2.5 |
| 24 | V12-03 | Analysis–trade linking | 1.5 |
| 25 | V12-04 | Auto-classify analysis type | 2 |
| 26 | V12-05 | Onboarding \+ empty states | 3 |
| 27 | V12-06 | Conversation continuity | 2 |

**Total: \~56 hours across 27 changes in 6 phases.** Phases 7–8 (trust \+ auth/multi-user) are the unglamorous foundation; Phases 10–11 (interpretation \+ portfolio awareness) are where the app finally becomes useful and distinctive.

# **5\. Priority Guidance**

If the full sequence is too long for the available time, these are the highest-leverage subsets, by goal:

### **Quick wins (do regardless)**

V7-01, V7-02, V10-01, V10-02, V10-03. Mostly bug fixes and prompt/UI changes; together they transform perceived quality for a day or two of work.

### **The strategic core**

V9-01 through V9-03 then V11-01 and V11-02. Loosening privacy unblocks genuinely useful, personalized output — the only thing a generic tool cannot replicate.

### **The flagged priority**

V7-04, V7-05, V8-01 through V8-05. Authentication and per-user trade mapping. Necessary for the app to be more than a personal tool, and the multi-user accounting is engineering that interviews well.

### **Deliberately deferred**

*Watchlists, push notifications, comparison mode, and export/share are intentionally out of scope for v3.0. None of them matter while the core output is still being made useful; adding more for the user to see before the main thing is worth seeing is misplaced effort.*

# **6\. Open Questions to Resolve During Build**

* **Gemma personalization quality.** If on-device interpretation (V11-01) comes out clumsy, fall back to letting the cloud personalize from the generalized profile rather than raw holdings — private enough, better prose. Decide after testing real Gemma output.

* **SPY benchmark source.** Server-side daily fetch and cache (V8-05) versus per-request. Caching is strongly preferred to protect the shared quota.

* **Tier 3 default.** Should total value and cost basis default to bucketed or fully on-device? Leaning bucketed-by-default with an explicit opt-in for exact.

* **Combination fingerprinting threshold.** Exactly how much Tier 2 detail, combined, starts to identify a portfolio? Define a concrete query-scoping rule during V9-02.