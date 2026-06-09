// AFTER · Performance screens (filled + empty) — uses FG tokens from screens-after.jsx

/* smooth line path helper */
function fgPath(pts, w, h, min, max) {
  const X = (i) => (i / (pts.length - 1)) * w;
  const Y = (v) => h - ((v - min) / (max - min)) * h;
  let d = `M ${X(0)} ${Y(pts[0])}`;
  for (let i = 1; i < pts.length; i++) {
    const x0 = X(i - 1), y0 = Y(pts[i - 1]), x1 = X(i), y1 = Y(pts[i]);
    const cx = (x0 + x1) / 2;
    d += ` C ${cx} ${y0}, ${cx} ${y1}, ${x1} ${y1}`;
  }
  return d;
}

function FgPerfChart() {
  const w = 329, h = 190;
  const port = [0, 0.4, 0.2, 0.9, 1.4, 1.1, 1.9, 2.6, 2.2, 3.1, 3.6, 3.2, 4.0, 4.32];
  const spy = [0, 0.3, 0.5, 0.4, 0.8, 1.0, 0.9, 1.3, 1.5, 1.4, 1.8, 1.7, 2.0, 2.1];
  const min = -0.4, max = 4.8;
  const Y = (v) => h - ((v - min) / (max - min)) * h;
  const dPort = fgPath(port, w, h, min, max);
  const dSpy = fgPath(spy, w, h, min, max);
  const scrubX = (10 / 13) * w;
  return (
    <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} style={{ display: "block" }}>
      <defs>
        <linearGradient id="fgFill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#34D87B" stopOpacity="0.22"></stop>
          <stop offset="100%" stopColor="#34D87B" stopOpacity="0"></stop>
        </linearGradient>
      </defs>
      {/* zero line */}
      <line x1="0" y1={Y(0)} x2={w} y2={Y(0)} stroke="rgba(255,255,255,0.12)" strokeDasharray="3 5"></line>
      {/* spy */}
      <path d={dSpy} fill="none" stroke="#6E7A73" strokeWidth="2" strokeLinecap="round"></path>
      {/* portfolio fill + line */}
      <path d={`${dPort} L ${w} ${h} L 0 ${h} Z`} fill="url(#fgFill)"></path>
      <path d={dPort} fill="none" stroke="#34D87B" strokeWidth="2.5" strokeLinecap="round"></path>
      {/* scrub */}
      <line x1={scrubX} y1="0" x2={scrubX} y2={h} stroke="rgba(255,255,255,0.18)"></line>
      <circle cx={scrubX} cy={Y(port[10])} r="5.5" fill="#34D87B" stroke="#0A0D0B" strokeWidth="2.5"></circle>
    </svg>
  );
}

/* ---------- AFTER · Performance (filled) ---------- */
function AfterPerfFilled() {
  return (
    <FgPhone bg={FG.bg} time="9:41">
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
        <div style={{ padding: "14px 20px 10px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ fontSize: 32, fontWeight: 800, letterSpacing: -0.5, color: FG.t1 }}>Portfolio</div>
          <div style={{ width: 36, height: 36, borderRadius: 18, background: FG.cardSolid, border: `1px solid ${FG.line}`, color: FG.green, display: "flex", alignItems: "center", justifyContent: "center" }}>{FgIcon.plus(18)}</div>
        </div>

        {/* segmented */}
        <div style={{ display: "flex", background: FG.cardSolid, border: `1px solid ${FG.line}`, borderRadius: 11, margin: "0 16px 12px", padding: 2 }}>
          {["Holdings", "Orders", "Performance"].map((t) => (
            <div key={t} style={{ flex: 1, textAlign: "center", padding: "8px 0", fontSize: 13, fontWeight: t === "Performance" ? 700 : 500, color: t === "Performance" ? FG.t1 : FG.t2, background: t === "Performance" ? "#39433D" : "transparent", borderRadius: 9 }}>{t}</div>
          ))}
        </div>

        {/* hero number */}
        <div style={{ padding: "4px 20px 0" }}>
          <AfSectionLabel>Cumulative return · paper</AfSectionLabel>
          <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginTop: 6 }}>
            <div style={{ fontSize: 40, fontWeight: 800, letterSpacing: -1, color: FG.green, fontVariantNumeric: "tabular-nums" }}>+4.32%</div>
            <div style={{ fontSize: 14, fontWeight: 600, color: FG.t2 }}>since Jun 2</div>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 14, marginTop: 4, fontSize: 13, fontWeight: 600 }}>
            <span style={{ display: "flex", alignItems: "center", gap: 6, color: FG.t2 }}><span style={{ width: 8, height: 8, borderRadius: 4, background: "#6E7A73" }}></span> SPY +2.10%</span>
            <span style={{ color: FG.green }}>▲ Beating by 2.22 pts</span>
          </div>
        </div>

        {/* chart */}
        <div style={{ ...afCard, marginTop: 14, padding: "16px 16px 10px" }}>
          <FgPerfChart></FgPerfChart>
          <div style={{ display: "flex", justifyContent: "space-between", color: FG.t3, fontSize: 11.5, fontWeight: 600, padding: "8px 2px 4px" }}>
            <span>Jun 2</span><span>Jun 5</span><span>Jun 9</span>
          </div>
          <div style={{ display: "flex", gap: 6, paddingTop: 8, borderTop: `1px solid ${FG.line}` }}>
            {["1W", "1M", "3M", "YTD", "All"].map((r) => (
              <div key={r} style={{ flex: 1, textAlign: "center", padding: "7px 0", fontSize: 12.5, fontWeight: 700, color: r === "1W" ? "#05230F" : FG.t2, background: r === "1W" ? FG.green : "transparent", borderRadius: 8 }}>{r}</div>
            ))}
          </div>
        </div>

        {/* supporting stats */}
        <div style={{ display: "flex", gap: 8, margin: "0 16px" }}>
          {[["Best day", "+1.9%", FG.green], ["Worst day", "−0.8%", FG.red], ["Thesis hit-rate", "2 of 3", FG.t1]].map(([k, v, c]) => (
            <div key={k} style={{ flex: 1, background: FG.cardSolid, border: `1px solid ${FG.line}`, borderRadius: 13, padding: "11px 12px" }}>
              <div style={{ fontSize: 11, color: FG.t3, fontWeight: 600 }}>{k}</div>
              <div style={{ fontSize: 16.5, fontWeight: 800, color: c, marginTop: 2, fontVariantNumeric: "tabular-nums" }}>{v}</div>
            </div>
          ))}
        </div>
        <div style={{ flex: 1 }}></div>
      </div>
      <FgTabBarAfter active="Portfolio"></FgTabBarAfter>
      <FgHomeBar></FgHomeBar>
    </FgPhone>
  );
}

/* ---------- AFTER · Performance (empty state) ---------- */
function AfterPerfEmpty() {
  return (
    <FgPhone bg={FG.bg} time="9:41">
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column" }}>
        <div style={{ padding: "14px 20px 10px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ fontSize: 32, fontWeight: 800, letterSpacing: -0.5, color: FG.t1 }}>Portfolio</div>
          <div style={{ width: 36, height: 36, borderRadius: 18, background: FG.cardSolid, border: `1px solid ${FG.line}`, color: FG.green, display: "flex", alignItems: "center", justifyContent: "center" }}>{FgIcon.plus(18)}</div>
        </div>

        <div style={{ display: "flex", background: FG.cardSolid, border: `1px solid ${FG.line}`, borderRadius: 11, margin: "0 16px 12px", padding: 2 }}>
          {["Holdings", "Orders", "Performance"].map((t) => (
            <div key={t} style={{ flex: 1, textAlign: "center", padding: "8px 0", fontSize: 13, fontWeight: t === "Performance" ? 700 : 500, color: t === "Performance" ? FG.t1 : FG.t2, background: t === "Performance" ? "#39433D" : "transparent", borderRadius: 9 }}>{t}</div>
          ))}
        </div>

        <div style={{ padding: "4px 20px 0" }}>
          <AfSectionLabel>Cumulative return · paper</AfSectionLabel>
          <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginTop: 6 }}>
            <div style={{ fontSize: 40, fontWeight: 800, letterSpacing: -1, color: FG.t3, fontVariantNumeric: "tabular-nums" }}>0.00%</div>
            <div style={{ fontSize: 14, fontWeight: 600, color: FG.t3 }}>no trades yet</div>
          </div>
        </div>

        {/* ghost chart + empty message */}
        <div style={{ ...afCard, marginTop: 14, padding: "16px 16px 16px", position: "relative" }}>
          <svg width="329" height="190" viewBox="0 0 329 190" style={{ display: "block", opacity: 0.5 }}>
            <line x1="0" y1="95" x2="329" y2="95" stroke="rgba(255,255,255,0.12)" strokeDasharray="3 5"></line>
            <path d="M 0 95 C 40 95, 60 70, 100 78 C 150 88, 180 40, 230 52 C 270 60, 300 30, 329 36" fill="none" stroke="rgba(52,216,123,0.18)" strokeWidth="2.5" strokeDasharray="1 7" strokeLinecap="round"></path>
          </svg>
          <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 10, padding: "0 36px", textAlign: "center" }}>
            <div style={{ width: 44, height: 44, borderRadius: 22, background: FG.greenDim, color: FG.green, display: "flex", alignItems: "center", justifyContent: "center" }}>{FgIcon.chart(20)}</div>
            <div style={{ fontSize: 16, fontWeight: 700, color: FG.t1 }}>Your curve starts here</div>
            <div style={{ fontSize: 13, color: FG.t2, lineHeight: 1.45 }}>Place your first paper trade from any research result and we'll track it against SPY.</div>
          </div>
        </div>

        <div style={{ margin: "0 16px" }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8, background: FG.greenDim, border: `1px solid rgba(52,216,123,0.3)`, borderRadius: 13, padding: "13px 0", color: FG.green, fontSize: 15.5, fontWeight: 700 }}>
            {FgIcon.search(15)} Run a research query
          </div>
        </div>
        <div style={{ flex: 1 }}></div>
      </div>
      <FgTabBarAfter active="Portfolio"></FgTabBarAfter>
      <FgHomeBar></FgHomeBar>
    </FgPhone>
  );
}

Object.assign(window, { FgPerfChart, AfterPerfFilled, AfterPerfEmpty });
