# FinGrowth Privacy Architecture

This document describes how FinGrowth keeps personal and financial data on the
user's device while still letting cloud agents perform market research. It
reflects what the code actually does; file references point at the source of
truth.

## Goals

- Raw portfolio holdings, account identifiers, and account-holder identity
  **never leave the device**.
- Cloud agents receive only an **anonymized, rewritten query** plus, when
  relevant, a **generalized portfolio profile** (buckets and coarse labels — no
  exact figures, no ticker-level holdings unless the user explicitly names a
  ticker in their question).
- Every outbound cloud request is recorded in a **device-only Privacy Audit
  Log** so the user can inspect exactly what was shared.

## Two-model design

The privacy boundary is drawn at CSV import. A single brokerage export is
parsed on-device (heuristic parser today, Gemma-powered for non-standard
headers) into two parallel SwiftData models:

### `PrivateLedger` (device-only)
`ios/FinGrowth/Models/PrivateLedger.swift`

Holds the full fidelity of the import and all identity fields:

- `accountName`, `sourceBrokerage`, `rawCSVDigest`
- `accountNumber`, `accountHolder` — extracted identity PII, stored **only**
  here
- `holdings: [LedgerHolding]` — per-lot `ticker`, `quantity`, `costBasis`,
  `purchaseDate`, `accountType`

`PrivateLedger` is a persistence model only. It is **never** serialized to JSON
for a network call, and it has no `Codable`/wire representation. Cloud DTOs are
separate plain structs (`GeneralizedProfile`, `PortfolioProfile`) that hold no
reference to the ledger.

### `ShareableProfile` (anonymized, still device-side)
`ios/FinGrowth/Models/ShareableProfile.swift`

The redacted surface derived from the ledger at import:

- `totalValueBucket` — a coarse value band, never an exact dollar amount
- `sectorWeightsJSON` — aggregate weights by sector category (no tickers)
- `positionSizeBucketsJSON` — per-holding size buckets (e.g. `"concentrated"`,
  `"large"`, `"moderate"`)
- `riskScore` — a diversification-derived 0…1 score

Even `ShareableProfile` is not sent verbatim. It is further reduced at request
time (see below).

## Three-tier PII classification

`ios/FinGrowth/Services/PIIExtractor.swift` (`PrivacyTier`) classifies every
detected field into one of three tiers that govern how far it may travel:

| Tier | Name                  | Handling                                             |
|------|-----------------------|------------------------------------------------------|
| 1    | Identity              | Never leaves the device (walled into `PrivateLedger`)|
| 2    | Portfolio detail      | Shared only when relevant to the query               |
| 3    | Sensitive financial   | Bucketed/generalized unless the user opts in         |

The policy is encoded as `PrivacyTier.isDisclosed(at:)`:

- **Tier 1 (identity)** — account holder name, account number: disclosed at *no*
  privacy level, ever.
- **Tier 2 (portfolio specific)** — ticker + share count named in a question:
  available to the query pipeline, query-scoped by the rewriter.
- **Tier 3 (sensitive financial)** — cost basis, exact total value, account
  type: disclosed only when the user selects the `.detailed` sharing level, and
  even then only as a coarse bucket, never an exact figure.

## Request-time flow (what actually leaves the device)

`ios/FinGrowth/Views/ResearchView.swift` orchestrates this per query, and
`ios/FinGrowth/Services/APIClient.swift` performs the transmission:

1. **Intent routing** (`IntentRouter`, deterministic). A portfolio-only
   question is classified `.localOnly` and **no cloud request is made** — the
   user is pointed at the on-device Portfolio tab.
2. **On-device query rewrite** (`QueryRewriter`, Gemma with a deterministic
   fallback). The raw question is rewritten *before anything leaves the device*
   so PII (dollar amounts framed as personal, brokerage names, holdings phrased
   as "my") is stripped. The cloud receives `rewritten.rewrittenText`, never the
   raw text.
3. **Generalized portfolio context** (`DifferentialPrivacy.scopedContext`).
   Attached **only** for a `.hybrid` intent with an existing profile. A pure
   market question (`.cloudAnalysis`) ships with *no* profile. The context is a
   `GeneralizedProfile` (sector categories, largest-position bucket,
   diversification label; risk/value only at `.detailed`).
4. **Wire projection** (`ResearchView.wireProfile`). Even the `GeneralizedProfile`
   is reduced to `PortfolioProfile` for the wire: the numeric `riskScore` is
   bucketed to a `riskOrientation` label (`conservative`/`balanced`/`aggressive`)
   so the raw score never crosses the network.
5. **Audit before send** (`PrivacyAuditLog.record`). Exactly one `AuditEntry` is
   written *before* transmission. If the audit write fails, the request is
   aborted — the invariant is "every cloud call corresponds to exactly one audit
   entry," so an unlogged request must not leave the device.

The Bearer token on each request comes from the signed-in session
(`SessionStore`), falling back to a placeholder before Sign in with Apple.

## Privacy Audit Log (device-only)

`ios/FinGrowth/Models/AuditEntry.swift` +
`ios/FinGrowth/Services/PrivacyAuditLog.swift`. One SwiftData row per outbound
call, storing the original query, the rewritten query actually sent, the
substitutions and why, the generalization level, detected PII categories, and a
confidence score. It is **never transmitted** — it exists purely so the Privacy
tab (`ios/FinGrowth/Views/PrivacyView.swift`) can show the user, side by side,
what they asked versus what was sent.

## Server-side storage

`backend/app/models/database.py`. The backend stores only anonymized context,
keyed by an opaque user id:

- `User`: an opaque UUID + `apple_sub` (the stable Sign in with Apple subject
  identifier). No name, no email.
- `AnalysisSession`: `query_hash` (SHA-256 of the sanitized query), `ticker`,
  `analysis_type`, `portfolio_context` (the generalized JSONB profile — never
  raw holdings).
- `AnalysisResult` / `VectorEmbedding`: the agent pipeline's output and its
  embedding — analysis text, not user PII.
- `VirtualBalance`: per-user paper-trading virtual cash (simulated).

All per-user rows carry `ON DELETE CASCADE` from `users`, so deleting the user
row removes every downstream analysis session, result, embedding, and balance.

## Account deletion

`DELETE /api/v1/users/me` (Bearer session token) deletes the server-side user
and, by cascade, all of its analysis history. In the app,
`AuthCoordinator.deleteAccount()` calls it, then clears the local session and
purges server-derived local caches (`ResearchHistoryEntry`, `PaperTradeRecord`).
Device-only data (`PrivateLedger`, `ShareableProfile`, the Privacy Audit Log) is
left in place — it never left the device and is erased when the user deletes the
app.
