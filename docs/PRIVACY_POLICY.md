# FinGrowth Privacy Policy

**Effective date: July 3, 2026**

FinGrowth ("FinGrowth," "we," "us," or "our") is a privacy-preserving
investment **research** application. This Privacy Policy explains what
information the app processes, what does and does not leave your device, and the
choices and rights you have. It is written to reflect how the app actually
works.

FinGrowth is a research tool, not a financial advisor, and it does not generate
buy or sell recommendations. See our Terms of Service for details on that.

## Summary (the short version)

- **Your portfolio never leaves your device in raw form.** Brokerage CSV
  imports are parsed entirely on your device by an on-device AI model (Gemma).
  Your holdings, account numbers, and account-holder name are stored only on
  your device.
- **The cloud sees only anonymized, rewritten questions** and, when relevant, a
  **generalized portfolio profile** made of coarse buckets and category labels —
  never your exact balances, cost basis, or individual holdings.
- **You can see exactly what was shared.** Every request that leaves your device
  is recorded in an on-device Privacy Audit Log you can inspect in the Privacy
  tab.
- **We do not sell your data, show ads, or use third-party trackers.**
- **You can delete your account and its server-side history at any time**,
  directly in the app.

## 1. Data processed on your device (and kept there)

The following are processed **on your device only** and are never transmitted to
our servers or any third party in raw form:

- **Brokerage CSV imports.** When you import a positions or transactions export,
  the file is parsed on-device. From it we build two on-device records:
  - a **Private Ledger** containing the full detail — account name, source
    brokerage, and, when present in your file, your **account number** and
    **account-holder name**, plus per-lot ticker, quantity, cost basis, purchase
    date, and account type; and
  - a **Shareable Profile**, an anonymized summary consisting of coarse value
    bands, sector-weight categories, position-size buckets, and a
    diversification-based risk score.
  The Private Ledger is stored only on your device and is never serialized for
  any network request.
- **The raw text of your questions**, before on-device rewriting.
- **The Privacy Audit Log**, described in Section 4.
- **On-device AI processing.** The Gemma model runs entirely on your device for
  parsing imports and rewriting queries. Enabling it downloads the model once;
  the model does not send your data anywhere.

Your on-device data is stored using the operating system's protected storage and
is removed when you delete the app.

## 2. Data sent to our servers

When you ask a research question that requires cloud analysis, only the
following may be transmitted:

- **A rewritten, anonymized version of your question.** Your question is
  rewritten **on your device before anything is sent** to remove personal
  framing and identifiers. The cloud receives the rewritten text, not your
  original wording.
- **A generalized portfolio profile — only when relevant to the question.**
  A general market question is sent with no portfolio context at all. When
  context is included, it consists of coarse categories and labels: sector-weight
  categories, a largest-position bucket, a diversification label, and — only if
  you opt into the "Detailed" sharing level — a generalized value band and a
  risk *orientation* label (such as "conservative," "balanced," or "aggressive").
  Your exact dollar amounts, exact risk score, cost basis, and individual
  holdings are never sent.
- **A public ticker symbol**, where your question is about a specific security. A
  ticker symbol is public market data, not personal information.

On our servers we store, associated with an opaque account identifier:

- an **opaque Apple user identifier** (the stable "subject" identifier from Sign
  in with Apple) — we do **not** store your name or email address;
- a **one-way hash (SHA-256) of the sanitized question**, the ticker, the
  analysis type, and the generalized portfolio profile described above;
- the **analysis output** produced by our research agents (analysis text,
  technical indicators, and a semantic embedding of that output); and
- for the simulated paper-trading feature, your **virtual (simulated) cash
  balance** and simulated orders.

We never receive your real holdings, account numbers, account-holder name, exact
balances, or the raw text of your questions.

## 3. Sign in with Apple

FinGrowth uses **Sign in with Apple** for authentication. During sign-in the app
requests name and email scope from Apple; however, the app uses **only** the
identity token to authenticate you and does **not** transmit or store your name
or email. Our servers store only the opaque Apple subject identifier and issue a
session token, which is stored securely in your device Keychain. If you use
Apple's "Hide My Email" feature, that choice is fully preserved because we do not
use your email at all.

## 4. The Privacy Audit Log

Every request that leaves your device is recorded in an on-device Privacy Audit
Log. Each entry records your original question, the rewritten question that was
actually sent, what was changed and why, the generalization level applied to any
shared portfolio context, and the categories of personal information that were
detected and removed. This log is stored only on your device and is never
transmitted. You can review it at any time in the app's Privacy tab. If the app
cannot record an audit entry, the corresponding request is **not sent**.

## 5. Third-party market data and services

FinGrowth's research agents query third-party market-data and brokerage-sandbox
services to gather public information. These services receive market queries
(for example, a ticker symbol); they do **not** receive your personal
information, holdings, identity, or the raw text of your questions:

- **SEC EDGAR** — public company filings.
- **Alpha Vantage** — market prices and fundamentals.
- **Finnhub** — market data.
- **Alpaca (paper trading)** — a simulated brokerage sandbox used for
  paper-trading only; no real orders and no real money are involved.

We do not use advertising networks or third-party analytics/tracking SDKs, and
we do not share your information with data brokers.

## 6. How we use information

We use the limited server-side information described in Section 2 solely to:

- perform the market research you request and return results to your device;
- deduplicate and cache analysis for performance (via the sanitized query hash
  and semantic embeddings); and
- operate the simulated paper-trading feature.

We do **not** use your information for advertising, profiling for third parties,
or sale.

## 7. Data retention

- **On-device data** (Private Ledger, Shareable Profile, question text, Privacy
  Audit Log) remains on your device until you delete it in the app or delete the
  app.
- **Server-side data** (the opaque identifier, sanitized query hashes,
  generalized profiles, analysis outputs, embeddings, and simulated balances) is
  retained while your account exists and is deleted when you delete your account
  (see Section 8). There is no separate automatic expiry; deletion is the
  mechanism for removal.

## 8. Your rights and choices

- **Delete your account.** You can permanently delete your account and all
  associated server-side analysis history directly in the app, under
  Settings → Account → **Delete Account**. This is immediate and cannot be
  undone; on your device it deletes all downstream server-linked records
  (via cascading deletion). Your on-device-only data remains private on your
  device and is removed when you delete the app.
- **Control what is shared.** The "Shared portfolio detail" setting
  (Minimal / Moderate / Detailed) controls how much generalized context may
  leave your device. Regardless of the level, your raw holdings and identity
  never leave the device.
- **Disable cloud sharing per question.** Portfolio-only questions are answered
  entirely on-device with no cloud request.
- **Inspect disclosures.** Use the Privacy Audit Log to review every outbound
  request.
- **Access and portability.** Because the meaningful copy of your portfolio data
  lives on your device, you already hold it; server-side we hold only anonymized
  context tied to an opaque identifier.

Depending on where you live, you may have additional rights under laws such as
the GDPR or CCPA/CPRA (access, correction, deletion, and objection). To exercise
any right that is not already available in the app, contact us using the details
below.

## 9. Children's privacy

FinGrowth is not directed to children under 13 (or the minimum age required in
your jurisdiction), and we do not knowingly collect information from them.

## 10. Security

Session tokens are stored in the device Keychain. On-device data uses the
operating system's file-protection features. Traffic between the app and our
servers is transmitted over encrypted connections.

## 11. Changes to this policy

We may update this Privacy Policy from time to time. When we do, we will revise
the "Effective date" above and, where appropriate, provide additional notice in
the app.

## 12. Contact

Questions about this Privacy Policy or your data:

**FinGrowth Privacy**
Email: privacy@fingrowth.example  *(replace with your production contact)*

---

*FinGrowth is a research tool and does not provide investment advice or
recommendations. See the Terms of Service for details.*
