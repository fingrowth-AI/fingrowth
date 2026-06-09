// Shared chrome + primitives for Fingrowth redesign artboards
const { useState } = React;

/* ---------- Icons (inline SVG, stroke = currentColor) ---------- */
const FgIcon = {
  search: (s = 18) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
      <circle cx="11" cy="11" r="7"></circle><path d="M16.5 16.5 21 21"></path>
    </svg>
  ),
  chart: (s = 18) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 17l5-5 4 3 6-7"></path><path d="M15 8h3v3"></path>
    </svg>
  ),
  lock: (s = 18) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
      <rect x="5" y="11" width="14" height="9" rx="2.5"></rect><path d="M8 11V8a4 4 0 0 1 8 0v3"></path>
    </svg>
  ),
  gear: (s = 18) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="3.2"></circle>
      <path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.5-2.4 1a7 7 0 0 0-2-1.2L14 3h-4l-.5 2.6a7 7 0 0 0-2 1.2l-2.4-1-2 3.5 2 1.5A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.5 2.4-1a7 7 0 0 0 2 1.2L10 21h4l.5-2.6a7 7 0 0 0 2-1.2l2.4 1 2-3.5-2-1.5c.1-.4.1-.8.1-1.2Z"></path>
    </svg>
  ),
  shield: (s = 16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3l7 3v5c0 4.5-3 8.5-7 10-4-1.5-7-5.5-7-10V6l7-3Z"></path><path d="M9.5 12l2 2 3.5-3.5"></path>
    </svg>
  ),
  check: (s = 14) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 12.5l4.5 4.5L19 7"></path>
    </svg>
  ),
  chevR: (s = 14) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="M9 5l7 7-7 7"></path>
    </svg>
  ),
  chevD: (s = 14) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 9l7 7 7-7"></path>
    </svg>
  ),
  arrowR: (s = 16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 12h15"></path><path d="M13 6l6 6-6 6"></path>
    </svg>
  ),
  play: (s = 16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="currentColor">
      <path d="M7 4.8v14.4c0 .8.9 1.3 1.6.9l11-7.2c.6-.4.6-1.4 0-1.8l-11-7.2c-.7-.4-1.6.1-1.6.9Z"></path>
    </svg>
  ),
  plus: (s = 18) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
      <path d="M12 5v14M5 12h14"></path>
    </svg>
  ),
  refresh: (s = 18) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M20 12a8 8 0 1 1-2.3-5.6"></path><path d="M20 3v4h-4"></path>
    </svg>
  ),
  sparkle: (s = 14) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3Z"></path>
    </svg>
  ),
  clock: (s = 13) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
      <circle cx="12" cy="12" r="8.5"></circle><path d="M12 7.5V12l3 2"></path>
    </svg>
  ),
  doc: (s = 14) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round">
      <path d="M7 3h7l4 4v14H7z"></path><path d="M14 3v4h4"></path>
    </svg>
  ),
  news: (s = 14) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3.5" y="5" width="17" height="15" rx="2"></rect><path d="M7.5 9.5h9M7.5 13h9M7.5 16.5h5"></path>
    </svg>
  ),
  link: (s = 13) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
      <path d="M10 14a5 5 0 0 0 7.1 0l2.4-2.4a5 5 0 0 0-7.1-7.1L11 5.9"></path>
      <path d="M14 10a5 5 0 0 0-7.1 0l-2.4 2.4a5 5 0 0 0 7.1 7.1L13 18.1"></path>
    </svg>
  ),
  flask: (s = 14) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round">
      <path d="M10 3v6l-5.5 9a2 2 0 0 0 1.7 3h11.6a2 2 0 0 0 1.7-3L14 9V3"></path><path d="M8 3h8"></path><path d="M7.5 15h9"></path>
    </svg>
  ),
};

/* ---------- iOS status bar ---------- */
function FgStatusBar({ light = true, time = "9:41" }) {
  const c = light ? "#fff" : "#0B0F0D";
  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "14px 28px 6px 32px", color: c }}>
      <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: 0.2, fontVariantNumeric: "tabular-nums" }}>{time}</div>
      <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
        <svg width="17" height="11" viewBox="0 0 17 11" fill={c}>
          <rect x="0" y="7" width="3" height="4" rx="0.8"></rect>
          <rect x="4.5" y="5" width="3" height="6" rx="0.8"></rect>
          <rect x="9" y="2.5" width="3" height="8.5" rx="0.8"></rect>
          <rect x="13.5" y="0" width="3" height="11" rx="0.8"></rect>
        </svg>
        <svg width="16" height="11" viewBox="0 0 16 11" fill={c}>
          <path d="M8 9.2a1.4 1.4 0 1 1 0 2.8 1.4 1.4 0 0 1 0-2.8ZM8 5.6c1.5 0 2.9.6 3.9 1.6l-1.5 1.5a3.4 3.4 0 0 0-4.8 0L4.1 7.2A5.5 5.5 0 0 1 8 5.6ZM8 2c2.5 0 4.8 1 6.5 2.7L13 6.2A7.1 7.1 0 0 0 8 4.1c-2 0-3.7.8-5 2.1L1.5 4.7A9.2 9.2 0 0 1 8 2Z" transform="translate(0,-2)"></path>
        </svg>
        <svg width="25" height="12" viewBox="0 0 25 12">
          <rect x="0.5" y="0.5" width="21" height="11" rx="3" fill="none" stroke={c} strokeOpacity="0.4"></rect>
          <rect x="2" y="2" width="14" height="8" rx="1.6" fill={c}></rect>
          <path d="M23 4v4c1-.3 1.6-1 1.6-2S24 4.3 23 4Z" fill={c} fillOpacity="0.4"></path>
        </svg>
      </div>
    </div>
  );
}

function FgHomeBar({ light = true }) {
  return (
    <div style={{ display: "flex", justifyContent: "center", padding: "6px 0 8px" }}>
      <div style={{ width: 134, height: 5, borderRadius: 3, background: light ? "rgba(255,255,255,0.85)" : "rgba(0,0,0,0.8)" }}></div>
    </div>
  );
}

/* ---------- Phone shell (393-wide artboard inner) ---------- */
function FgPhone({ children, bg = "#000", light = true, time, className = "" }) {
  return (
    <div className={className} style={{ width: 393, height: "100%", display: "flex", flexDirection: "column", background: bg, fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif", overflow: "hidden", position: "relative" }}>
      <FgStatusBar light={light} time={time}></FgStatusBar>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minHeight: 0 }}>{children}</div>
    </div>
  );
}

/* ---------- BEFORE tab bar (faithful to screenshots) ---------- */
function FgTabBarBefore({ active = "Research" }) {
  const items = [
    { k: "Research", icon: FgIcon.search },
    { k: "Portfolio", icon: FgIcon.chart },
    { k: "Privacy", icon: FgIcon.lock },
    { k: "Settings", icon: FgIcon.gear },
  ];
  return (
    <div style={{ margin: "8px 12px 0", background: "#161616", borderRadius: 32, display: "flex", padding: 6 }}>
      {items.map((it) => {
        const on = it.k === active;
        return (
          <div key={it.k} style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 3, padding: "9px 0", borderRadius: 26, background: on ? "#2A2A2A" : "transparent", color: on ? "#30D158" : "#B5B5B5" }}>
            {it.icon(20)}
            <div style={{ fontSize: 11.5, fontWeight: 500 }}>{it.k}</div>
          </div>
        );
      })}
    </div>
  );
}

/* ---------- AFTER tab bar (refined) ---------- */
function FgTabBarAfter({ active = "Research" }) {
  const items = [
    { k: "Research", icon: FgIcon.search },
    { k: "Portfolio", icon: FgIcon.chart },
    { k: "Privacy", icon: FgIcon.lock },
    { k: "Settings", icon: FgIcon.gear },
  ];
  return (
    <div style={{ borderTop: "1px solid rgba(255,255,255,0.07)", background: "rgba(10,13,11,0.92)", display: "flex", padding: "8px 10px 0" }}>
      {items.map((it) => {
        const on = it.k === active;
        return (
          <div key={it.k} style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 4, padding: "6px 0 2px", color: on ? "#34D87B" : "#6E7A73" }}>
            {it.icon(21)}
            <div style={{ fontSize: 10.5, fontWeight: on ? 600 : 500, letterSpacing: 0.1 }}>{it.k}</div>
          </div>
        );
      })}
    </div>
  );
}

Object.assign(window, { FgIcon, FgStatusBar, FgHomeBar, FgPhone, FgTabBarBefore, FgTabBarAfter });
