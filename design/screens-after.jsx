// AFTER screens — "Refined OLED" direction. Dark green-tinted neutrals, structured cards.
const FG = {
  bg: "#0A0D0B",
  card: "#13181520",
  cardSolid: "#141A16",
  inset: "#1D2420",
  line: "rgba(255,255,255,0.07)",
  green: "#34D87B",
  greenDim: "rgba(52,216,123,0.13)",
  amber: "#E9A23B",
  amberDim: "rgba(233,162,59,0.14)",
  red: "#FF6259",
  t1: "#F2F5F3",
  t2: "#94A29B",
  t3: "#5F6B65",
};

const afCard = { background: FG.cardSolid, border: `1px solid ${FG.line}`, borderRadius: 18, margin: "0 16px 12px" };

function AfSectionLabel({ children, style }) {
  return <div style={{ fontSize: 12, fontWeight: 600, letterSpacing: 0.9, color: FG.t3, textTransform: "uppercase", ...style }}>{children}</div>;
}

/* tiny confidence dot+label — subtle but always visible */
function AfConfidence({ level = "Low" }) {
  const map = { Low: FG.amber, Medium: FG.green, High: FG.green };
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12.5, fontWeight: 600, color: FG.t2 }}>
      <span style={{ width: 7, height: 7, borderRadius: 4, background: map[level] }}></span>
      {level} confidence
    </div>
  );
}

/* ---------- AFTER · Research compose ---------- */
function AfterResearch() {
  return (
    <FgPhone bg={FG.bg} time="9:41">
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
        {/* header */}
        <div style={{ padding: "14px 20px 14px" }}>
          <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between" }}>
            <div style={{ fontSize: 32, fontWeight: 800, letterSpacing: -0.5, color: FG.t1 }}>Research</div>
            <div style={{ display: "flex", alignItems: "center", gap: 5, color: FG.t2, fontSize: 12, fontWeight: 600 }}>
              <span style={{ color: FG.green }}>{FgIcon.lock(12)}</span> Private by design
            </div>
          </div>
          <div style={{ fontSize: 14.5, color: FG.t2, marginTop: 3 }}>Ask anything about a stock — answers stay research-only.</div>
        </div>

        {/* query card */}
        <div style={{ ...afCard, padding: 16 }}>
          <div style={{ fontSize: 19, lineHeight: 1.4, color: FG.t1, fontWeight: 500, minHeight: 56 }}>
            What's the latest news on TSLA?<span className="af-caret"></span>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 14 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 6, background: FG.greenDim, color: FG.green, borderRadius: 9, padding: "6px 10px", fontSize: 13.5, fontWeight: 700 }}>
              TSLA <span style={{ fontSize: 12.5, color: FG.t2, fontWeight: 500 }}>Tesla, Inc.</span>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 4, color: FG.t3, fontSize: 13, fontWeight: 600 }}>{FgIcon.plus(13)} Ticker</div>
          </div>
          <div style={{ height: 1, background: FG.line, margin: "14px -16px" }}></div>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <div style={{ display: "flex", flex: 1, background: FG.inset, borderRadius: 10, padding: 2 }}>
              {["Fundamental", "Technical", "General"].map((m) => (
                <div key={m} style={{ flex: 1, textAlign: "center", padding: "8px 0", fontSize: 13, fontWeight: m === "General" ? 700 : 500, color: m === "General" ? FG.t1 : FG.t2, background: m === "General" ? "#39433D" : "transparent", borderRadius: 8, position: "relative" }}>
                  {m}
                  {m === "General" && <span style={{ position: "absolute", top: -7, right: -4, background: FG.green, color: "#06210F", fontSize: 9, fontWeight: 800, borderRadius: 6, padding: "2px 5px", letterSpacing: 0.3 }}>AUTO</span>}
                </div>
              ))}
            </div>
          </div>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8, background: FG.green, borderRadius: 13, padding: "14px 0", color: "#05230F", fontSize: 16.5, fontWeight: 700, marginTop: 14 }}>
            {FgIcon.sparkle(15)} Run analysis
          </div>
        </div>

        {/* recent */}
        <div style={{ padding: "8px 20px 6px", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <AfSectionLabel>Recent</AfSectionLabel>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: FG.green }}>See all</div>
        </div>
        <div style={{ ...afCard, padding: "2px 16px" }}>
          {[
            ["TSLA", "Is the robotaxi rollout priced in?", "Today"],
            ["AAPL", "Is AAPL overbought right now?", "Jun 3"],
            ["NOW", "General overview of this company", "Jun 3"],
          ].map(([tk, q, d], i) => (
            <div key={tk + i} style={{ display: "flex", alignItems: "center", gap: 12, padding: "13px 0", borderTop: i ? `1px solid ${FG.line}` : "none" }}>
              <div style={{ width: 42, height: 30, borderRadius: 8, background: FG.inset, color: FG.t1, fontSize: 11.5, fontWeight: 800, display: "flex", alignItems: "center", justifyContent: "center", letterSpacing: 0.3 }}>{tk}</div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14.5, color: FG.t1, fontWeight: 500, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{q}</div>
                <div style={{ fontSize: 12, color: FG.t3, marginTop: 1 }}>{d}</div>
              </div>
              <span style={{ color: FG.t3 }}>{FgIcon.chevR(13)}</span>
            </div>
          ))}
        </div>
        <div style={{ flex: 1 }}></div>
      </div>
      <FgTabBarAfter active="Research"></FgTabBarAfter>
      <FgHomeBar></FgHomeBar>
    </FgPhone>
  );
}

/* ---------- AFTER · Streaming progress ---------- */
function AfterStreaming() {
  const steps = [
    { k: "Research", desc: "244 news items · 10 filings found", state: "done" },
    { k: "Analysis", desc: "Scoring technicals & sentiment…", state: "active" },
    { k: "Review", desc: "Risk gate", state: "todo" },
  ];
  return (
    <FgPhone bg={FG.bg} time="9:41">
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
        <div style={{ padding: "14px 20px 12px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ fontSize: 21, fontWeight: 800, letterSpacing: -0.3, color: FG.t1 }}>Analyzing TSLA</div>
          <div style={{ fontSize: 13.5, fontWeight: 600, color: FG.t2 }}>Cancel</div>
        </div>

        {/* pinned query */}
        <div style={{ ...afCard, padding: "12px 16px", display: "flex", gap: 10, alignItems: "center" }}>
          <span style={{ color: FG.t3 }}>{FgIcon.search(15)}</span>
          <div style={{ fontSize: 14.5, color: FG.t2, fontStyle: "italic", flex: 1 }}>“What's the latest news on TSLA?”</div>
          <div style={{ background: FG.inset, color: FG.t2, fontSize: 11, fontWeight: 700, borderRadius: 6, padding: "3px 7px" }}>GENERAL</div>
        </div>

        {/* progress timeline */}
        <div style={{ ...afCard, padding: "18px 16px 10px" }}>
          {steps.map((s, i) => (
            <div key={s.k} style={{ display: "flex", gap: 14 }}>
              <div style={{ display: "flex", flexDirection: "column", alignItems: "center" }}>
                {s.state === "done" && <span style={{ width: 24, height: 24, borderRadius: 12, background: FG.green, color: "#05230F", display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>{FgIcon.check(12)}</span>}
                {s.state === "active" && <span className="af-spin" style={{ width: 24, height: 24, borderRadius: 12, border: `2.5px solid ${FG.greenDim}`, borderTopColor: FG.green, flexShrink: 0 }}></span>}
                {s.state === "todo" && <span style={{ width: 24, height: 24, borderRadius: 12, border: `2px solid ${FG.line}`, flexShrink: 0 }}></span>}
                {i < steps.length - 1 && <div style={{ width: 2, flex: 1, background: s.state === "done" ? FG.green : FG.line, margin: "4px 0", minHeight: 22, opacity: s.state === "done" ? 0.5 : 1 }}></div>}
              </div>
              <div style={{ paddingBottom: i < steps.length - 1 ? 18 : 8 }}>
                <div style={{ fontSize: 15.5, fontWeight: 700, color: s.state === "todo" ? FG.t3 : FG.t1 }}>{s.k}</div>
                <div style={{ fontSize: 13, color: s.state === "active" ? FG.green : FG.t3, marginTop: 2, fontWeight: s.state === "active" ? 600 : 400 }}>{s.desc}</div>
              </div>
            </div>
          ))}
        </div>

        {/* streaming preview */}
        <div style={{ padding: "8px 20px 6px" }}><AfSectionLabel>Streaming in</AfSectionLabel></div>
        <div style={{ ...afCard, padding: 16 }}>
          <div style={{ fontSize: 15, lineHeight: 1.5, color: FG.t1 }}>
            Coverage is heavy this week — 244 news items and 10 filings. The headline driver is the Austin robotaxi rollout<span className="af-caret"></span>
          </div>
          <div style={{ marginTop: 14, display: "flex", flexDirection: "column", gap: 9 }}>
            <div className="af-shimmer" style={{ height: 11, borderRadius: 6, width: "92%" }}></div>
            <div className="af-shimmer" style={{ height: 11, borderRadius: 6, width: "78%" }}></div>
            <div className="af-shimmer" style={{ height: 11, borderRadius: 6, width: "55%" }}></div>
          </div>
        </div>
        <div style={{ flex: 1 }}></div>
      </div>
      <FgTabBarAfter active="Research"></FgTabBarAfter>
      <FgHomeBar></FgHomeBar>
    </FgPhone>
  );
}

/* ---------- AFTER · Result (structured) ---------- */
function AfterResult() {
  return (
    <FgPhone bg={FG.bg} time="9:41">
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
        {/* result header */}
        <div style={{ padding: "12px 20px 12px", display: "flex", alignItems: "flex-start", justifyContent: "space-between" }}>
          <div>
            <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
              <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: -0.4, color: FG.t1 }}>TSLA</div>
              <div style={{ fontSize: 14, color: FG.t2 }}>Tesla, Inc.</div>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12.5, color: FG.t3, marginTop: 3 }}>{FgIcon.clock(12)} As of close · Jun 8</div>
          </div>
          <div style={{ marginTop: 6 }}><AfConfidence level="Low"></AfConfidence></div>
        </div>

        {/* stat strip */}
        <div style={{ ...afCard, padding: 0, display: "flex" }}>
          {[["244", "News items"], ["10", "Filings"], ["Mixed", "Sentiment"]].map(([v, k], i) => (
            <div key={k} style={{ flex: 1, padding: "13px 0", textAlign: "center", borderLeft: i ? `1px solid ${FG.line}` : "none" }}>
              <div style={{ fontSize: 20, fontWeight: 800, color: FG.t1, fontVariantNumeric: "tabular-nums" }}>{v}</div>
              <div style={{ fontSize: 11.5, color: FG.t3, fontWeight: 600, marginTop: 1 }}>{k}</div>
            </div>
          ))}
        </div>

        {/* headlines */}
        <div style={{ padding: "8px 20px 6px" }}><AfSectionLabel>What's moving TSLA</AfSectionLabel></div>
        <div style={{ ...afCard, padding: "2px 16px" }}>
          {[
            ["Unsupervised robotaxis roll out in Austin metro", "Reuters", "Robotaxi"],
            ["Denmark approves FSD expansion — stock slips", "Benzinga", "FSD"],
            ["Among most-active S&P 500 names on Tuesday", "Yahoo Finance", "Momentum"],
          ].map(([h, src, tag], i) => (
            <div key={i} style={{ padding: "12px 0", borderTop: i ? `1px solid ${FG.line}` : "none", display: "flex", gap: 10 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14.5, fontWeight: 600, color: FG.t1, lineHeight: 1.35 }}>{h}</div>
                <div style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 6 }}>
                  <span style={{ display: "inline-flex", alignItems: "center", gap: 4, fontSize: 11.5, fontWeight: 600, color: FG.t2, background: FG.inset, borderRadius: 6, padding: "3px 7px" }}>{FgIcon.news(11)} {src}</span>
                  <span style={{ fontSize: 11.5, fontWeight: 600, color: FG.green, background: FG.greenDim, borderRadius: 6, padding: "3px 7px" }}>{tag}</span>
                </div>
              </div>
              <span style={{ color: FG.t3, alignSelf: "center" }}>{FgIcon.chevR(13)}</span>
            </div>
          ))}
        </div>

        {/* indicators */}
        <div style={{ padding: "8px 20px 6px" }}><AfSectionLabel>Technicals</AfSectionLabel></div>
        <div style={{ ...afCard, padding: 12, display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
          {[
            ["RSI · 14d", "62", "Neutral", FG.t2],
            ["MACD", "+1.2", "Bullish cross", FG.green],
            ["Bollinger", "Mid", "Inside bands", FG.t2],
            ["20d avg", "$312.40", "Above avg", FG.green],
          ].map(([k, v, note, c]) => (
            <div key={k} style={{ background: FG.inset, borderRadius: 11, padding: "10px 12px" }}>
              <div style={{ fontSize: 11.5, color: FG.t3, fontWeight: 600 }}>{k}</div>
              <div style={{ display: "flex", alignItems: "baseline", gap: 6, marginTop: 3 }}>
                <span style={{ fontSize: 17, fontWeight: 800, color: FG.t1, fontVariantNumeric: "tabular-nums" }}>{v}</span>
                <span style={{ fontSize: 11.5, fontWeight: 600, color: c }}>{note}</span>
              </div>
            </div>
          ))}
        </div>

        {/* risk + context */}
        <div style={{ ...afCard, padding: "11px 16px", display: "flex", alignItems: "center", gap: 10 }}>
          <span style={{ color: FG.green }}>{FgIcon.shield(16)}</span>
          <div style={{ flex: 1, fontSize: 13.5, fontWeight: 700, color: FG.t1 }}>Risk gate · Approved</div>
          <div style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 12, color: FG.t3 }}>{FgIcon.link(12)} Builds on earlier TSLA run</div>
        </div>

        <div style={{ flex: 1 }}></div>

        {/* CTA */}
        <div style={{ padding: "4px 16px 10px" }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8, background: FG.green, borderRadius: 13, padding: "14px 0", color: "#05230F", fontSize: 16.5, fontWeight: 700 }}>
            {FgIcon.flask(15)} Test with paper trade
          </div>
          <div style={{ textAlign: "center", fontSize: 11.5, color: FG.t3, marginTop: 8 }}>Simulated — no real money. Research, not investment advice.</div>
        </div>
      </div>
      <FgTabBarAfter active="Research"></FgTabBarAfter>
      <FgHomeBar></FgHomeBar>
    </FgPhone>
  );
}

Object.assign(window, { FG, afCard, AfSectionLabel, AfConfidence, AfterResearch, AfterStreaming, AfterResult });
