// Sektor5 admin PIN: shared by every control page (include with <script src="/s5auth.js">).
//
// Anyone can look. Changing anything is admin-only, enforced by each service (a POST without the
// admin cookie gets 401). This script shows VIEW ONLY / ADMIN, asks for the PIN when a change is
// refused, and retries the change once unlocked. The cookie lasts 5 years, per browser and host.
//
// It also sets up the shared top bar (.s5bar, logo in .s5home, which opens the System view from
// /s5system.js) and wires links to the other control pages (<a data-port="8090" data-path="/">, e.g. the top
// bar): greyed out for viewers, and for admins greyed out only if that page can't be reached from
// here (the public link publishes just the dashboard; the rest need the LAN or Tailscale).
(() => {
  "use strict";
  // Start from the last known state so the page draws right first time (no re-greying after load).
  let last = {};
  try { last = JSON.parse(localStorage.getItem("s5auth") || "{}"); } catch (e) { /* private mode */ }
  const S5 = (window.S5AUTH = { enabled: !!last.enabled, admin: last.admin !== false, ready: false });
  const rawFetch = window.fetch.bind(window);

  // The top bar (.s5bar) is identical on every page: same height, logo and page links in the same
  // place, nothing wraps. Page-specific bits in the bar, and the page below it, fade in. Added here,
  // in <head>, so it applies before the first paint.
  // System fonts: the brain is often offline at a gig, so nothing is fetched from the web.
  const FONT = `"Inter", -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, system-ui, sans-serif`;
  const barCss = `
  html { scrollbar-gutter: stable; }
  :root { --s5bar: 48px; }   /* top bar height: things pinned under it use this */
  .s5bar { box-sizing: border-box; position: sticky; top: 0; z-index: 40; display: flex; flex-wrap: nowrap; align-items: center; gap: 20px;
    height: var(--s5bar); min-height: var(--s5bar); max-height: var(--s5bar); margin: 0; padding: 0 24px; background: var(--bg, #0c0c0e); border: 0; border-bottom: 1px solid var(--line, #26262b);
    font: 500 14px/1 ${FONT}; letter-spacing: -.005em; text-transform: none; backdrop-filter: none;
    overflow-x: auto; overflow-y: hidden; scrollbar-width: none; }
  .s5bar::-webkit-scrollbar { display: none; }
  .s5bar > * { flex-shrink: 0; }
  .s5bar > .s5home { flex: 0 0 96px; width: 96px; height: 100%; margin: 0; padding: 0; display: flex; align-items: center; position: relative;
    cursor: pointer; user-select: none; font-size: 14px; line-height: 1; }
  .s5bar > .s5home .s5logo { display: flex; align-items: center; line-height: 1; }
  .s5bar > nav.pages { align-self: stretch; height: 100%; display: flex; gap: 2px; margin: 0; padding: 0; }
  .s5bar > nav.pages { align-items: center; gap: 2px; }
  .s5bar > nav.pages a { display: flex; align-items: center; height: 32px; padding: 0 12px; margin: 0; font: 500 13px/1 ${FONT}; letter-spacing: -.005em;
    text-transform: none; color: var(--na1a1aa, #a1a1aa); text-decoration: none; border: 0; border-radius: 8px;
    transition: color .15s, background .15s, opacity .2s; }
  .s5bar > nav.pages a:hover { color: var(--nfafafa, #fafafa); background: var(--n1c1c20, #1c1c20); }
  .s5bar > nav.pages a.here { color: var(--n09090b, #09090b); background: var(--nfafafa, #fafafa); }
  .s5bar > nav.pages a.s5live { gap: 7px; margin-left: 8px; border: 1px solid var(--n3a3a41, #3a3a41); color: var(--nfafafa, #fafafa); }
  .s5bar > nav.pages a.s5live i { width: 6px; height: 6px; border-radius: 50%; background: #ff5a1f; box-shadow: 0 0 0 3px rgba(255,90,31,.2); }
  .s5bar > nav.pages a.s5live:hover { border-color: #ff5a1f; }
  html.s5-fontwait .s5bar > nav.pages { visibility: hidden; }
  .s5bar > :not(.s5home):not(nav.pages):not(.s5who) { animation: s5in .45s ease; }
  .s5bar ~ :not(.s5tabs) { animation: s5in .35s ease; }   /* no fill: nothing lingers (stacking) once faded */
  /* Viewer / admin: a lock at the right end of the bar (stays in view if the bar scrolls sideways). */
  .s5bar > .s5who { margin-left: auto; position: sticky; right: 0; flex: none; width: 28px; height: 28px; padding: 0; display: none;
    align-items: center; justify-content: center; cursor: pointer; background: var(--bg, #0c0c0e); color: var(--na1a1aa, #a1a1aa); border: 1px solid var(--n3a3a41, #3a3a41); border-radius: 8px; }
  html.s5-viewer .s5bar > .s5who, html.s5-admin .s5bar > .s5who { display: flex; }
  html.s5-viewer .s5bar > .s5who { color: #ff5a1f; border-color: rgba(255,90,31,.55); }
  html.s5-admin .s5bar > .s5who { color: #7ccf8a; border-color: rgba(124,207,138,.55); }
  .s5who svg { width: 14px; height: 14px; }
  .s5bar > .s5right { margin-left: auto; display: flex; gap: 6px; align-items: center; flex: none; position: sticky; right: 36px; background: var(--bg, #0c0c0e); }
  .s5bar > .s5right + .s5who { margin-left: 8px; }
  .s5mode { flex: none; width: 28px; height: 28px; padding: 0; display: flex; align-items: center; justify-content: center; cursor: pointer;
    background: transparent; color: var(--na1a1aa, #a1a1aa); border: 1px solid var(--n3a3a41, #3a3a41); border-radius: 8px; }
  .s5mode:hover { color: var(--nfafafa, #fafafa); }
  .s5mode svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; }
  /* Section tabs under a page's display (S5AUTH.sectionTabs): only the chosen section shows. */
  .s5sect { display: flex; gap: 2px; overflow-x: auto; scrollbar-width: none; padding: 6px 12px; background: var(--bg, #0c0c0e); border-top: 1px solid var(--line, #26262b); border-bottom: 1px solid var(--line, #26262b); }
  .s5sect::-webkit-scrollbar { display: none; }
  .s5sect button { flex: 1 0 auto; margin: 0; height: 34px; padding: 0 14px; background: transparent !important; border: 0 !important; border-radius: 8px !important;
    color: var(--na1a1aa, #a1a1aa) !important; cursor: pointer; white-space: nowrap; font: 500 13px/1 ${FONT} !important; letter-spacing: -.005em !important; text-transform: none !important; transition: color .15s, background .15s; }
  .s5sect button:hover { color: var(--nfafafa, #fafafa) !important; background: var(--n1c1c20, #1c1c20) !important; }
  .s5sect button[aria-selected="true"] { color: var(--nfafafa, #fafafa) !important; background: var(--n1f1f23, #1f1f23) !important; box-shadow: inset 0 0 0 1px var(--n3a3a41, #3a3a41); }
  .s5-hide { display: none !important; }
  /* Phones: the page links move to a tab bar at the bottom (Decks in the middle). */
  .s5tabs { display: none; }
  @media (max-width: 760px) {
    .s5bar { padding: 0 12px; gap: 10px; }
    .s5bar > nav.pages, .s5bar #self, .s5bar .keys { display: none; }
    .s5tabs { display: grid; grid-template-columns: repeat(6, 1fr); position: fixed; left: 0; right: 0; bottom: 0; z-index: 45;
      height: calc(60px + env(safe-area-inset-bottom)); padding: 0 0 env(safe-area-inset-bottom); background: color-mix(in srgb, var(--bg, #0c0c0e) 94%, transparent); border-top: 1px solid var(--line, #26262b);
      backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px); }
    .s5tabs a { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 5px; color: var(--na1a1aa, #a1a1aa);
      text-decoration: none; font: 500 10px/1 ${FONT}; letter-spacing: .04em; -webkit-tap-highlight-color: transparent; }
    .s5tabs a svg { width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
    .s5tabs a.mid svg { width: 26px; height: 26px; }
    .s5tabs a.here { color: var(--nfafafa, #fafafa); } .s5tabs a.here svg { stroke: #ff5a1f; }
    body { padding-bottom: calc(64px + env(safe-area-inset-bottom)) !important; }
  }
  @keyframes s5in { from { opacity: 0; } to { opacity: 1; } }`;
  S5.barCss = barCss;   // the System view (s5system.js) reuses it inside its shadow root
  const barStyle = document.createElement("style");
  barStyle.textContent = barCss;
  document.head.appendChild(barStyle);
  document.documentElement.classList.toggle("s5-viewer", S5.enabled && !S5.admin);
  document.documentElement.classList.toggle("s5-admin", S5.enabled && S5.admin);
  // Page links are drawn in Montserrat: wait for it (cached after the first page) so they don't
  // shift when it swaps in. Offline, fall back to the system font after a moment.

  // Appearance: dark (default), light, or match the device. One setting for the whole app, the same
  // one Focus (/show.html) uses, remembered per browser.
  const MODES = ["dark", "light", "auto"];
  const mode = () => { const m = localStorage.getItem("s5theme"); return MODES.includes(m) ? m : "dark"; };
  function applyMode() {
    const m = mode(), light = m === "light" || (m === "auto" && matchMedia("(prefers-color-scheme: light)").matches);
    document.documentElement.dataset.theme = light ? "light" : "dark";
    let meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = light ? "#f4f4f5" : "#0c0c0e";
    paintMode();
  }
  function paintMode() {
    const b = document.querySelector(".s5mode"); if (!b) return;
    const m = mode(), next = MODES[(MODES.indexOf(m) + 1) % 3];
    b.innerHTML = { dark: '<svg viewBox="0 0 24 24"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>',
                    light: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
                    auto: '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/></svg>' }[m];
    b.title = `Appearance: ${{ dark: "dark", light: "light", auto: "matches the device" }[m]}. Click for ${{ dark: "dark", light: "light", auto: "match the device" }[next]}.`;
    b.setAttribute("aria-label", b.title);
  }
  applyMode();
  addEventListener("storage", e => { if (e.key === "s5theme") applyMode(); });
  matchMedia("(prefers-color-scheme: light)").addEventListener?.("change", applyMode);
  function modeButton() {
    const bar = document.querySelector(".s5bar");
    if (!bar || bar.querySelector(".s5mode") || document.documentElement.hasAttribute("data-s5-own-theme")) return;
    let right = bar.querySelector(".s5right");
    if (!right) { right = el("span", { class: "s5right" }); bar.insertBefore(right, bar.querySelector(".s5who")); }
    const b = el("button", { class: "s5mode", type: "button" });
    b.onclick = () => { localStorage.setItem("s5theme", MODES[(MODES.indexOf(mode()) + 1) % 3]); applyMode(); };
    right.appendChild(b); paintMode();
  }

  // The theme: one design system over every page's own styles (see docs/design.md). Last in <head>,
  // so it wins over the page's blocks; moved there again once the page has parsed, in case a page
  // adds styles after this script.
  // A page with a design system of its own (Focus, /show.html) opts out with <html data-s5-own-theme>;
  // it still gets the shared components (the fader).
  const theme = document.createElement("style");
  theme.id = "s5theme";
  theme.textContent = (document.documentElement.hasAttribute("data-s5-own-theme") ? "" : themeCss()) + faderCss();
  document.head.appendChild(theme);
  document.addEventListener("DOMContentLoaded", () => document.head.appendChild(theme));
  let quietUntil = 0, pending = null;

  function faderCss() { return `
  /* The intensity fader (VJ.fader, on the Visuals page, the Launchpad and Focus). */
  .s5fader { position: relative; height: 48px; border-radius: 12px; overflow: hidden; background: var(--well, var(--card, #08080a)); border: 1px solid var(--line, var(--border, #26262b));
    touch-action: none; cursor: ew-resize; user-select: none; -webkit-user-select: none; }
  .s5fader .f { position: absolute; inset: 0 auto 0 0; width: 50%;
    background: linear-gradient(90deg, rgba(255,90,31,.25), rgba(255,90,31,calc(.55 + .35 * var(--pulse, 0))));
    box-shadow: inset -2px 0 0 #ff5a1f; transition: width .06s linear; }
  .s5fader.drag .f { transition: none; }
  .s5fader .t { position: absolute; inset: 0; display: flex; align-items: center; justify-content: space-between; padding: 0 14px;
    font: 500 13px ${FONT}; color: var(--text, #fafafa); pointer-events: none; }
  .s5fader .t b { font-weight: 600; font-variant-numeric: tabular-nums; }
  .s5fader:focus-visible { outline: 2px solid #ff5a1f; outline-offset: 2px; }
  @media (max-width: 760px) { .s5fader { height: 56px; } }
  /* The bar number, as a beat counter's first beat (VJ.barCounter): dim between downbeats, orange on
     the 1. Tap it to change what it counts to. */
  .s5barn { flex: none; min-width: 22px; height: 18px; padding: 0 5px; margin: 0; border: 0; border-radius: 99px; background: rgba(255,255,255,.12);
    color: rgba(255,255,255,.62); font: 700 11px/18px ${FONT}; font-variant-numeric: tabular-nums; text-align: center; cursor: pointer; white-space: nowrap;
    transition: background .05s, color .05s; }
  .s5barn.on { background: #ff5a1f; color: #fff; }
  html[data-theme=light] .s5barn:not(.pvbeat .s5barn):not(.on) { background: rgba(0,0,0,.08); color: #52525b; }
  /* The audio monitor (VJ.waveStrip): its own dark panel stacked under a preview, never on it. */
  .s5wavebox { position: relative; display: none; flex-direction: column; height: 84px; margin-top: 6px; background: #08080a; border: 1px solid #26262b;
    border-radius: 10px; overflow: hidden; user-select: none; -webkit-user-select: none; }
  html.s5wave-on .s5wavebox { display: flex; }
  .s5wavebox .hd { flex: none; display: flex; align-items: center; justify-content: space-between; gap: 8px; height: 26px; padding: 0 4px 0 10px;
    border-bottom: 1px solid #1c1c20; }
  .s5wavebox .tag { font: 600 11px/1 ${FONT}; color: #a1a1aa; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .s5wavebox .tag i { font-style: normal; font-weight: 400; color: #6b6b74; }
  .s5wavebox .s5wv { position: relative; flex: 1; min-height: 0; }
  .s5wavebox canvas { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
  .s5wavebox .zoom { flex: none; display: flex; align-items: center; gap: 2px; }
  .s5wavebox .zoom b { font: 500 11px/1 ${FONT}; color: #a1a1aa; min-width: 46px; text-align: center; font-variant-numeric: tabular-nums; }
  .s5wavebox .zoom button { width: 24px; height: 20px; min-width: 0; min-height: 0; padding: 0; border: 0; background: transparent; color: #fafafa;
    font: 600 15px/1 ${FONT}; cursor: pointer; border-radius: 5px; }
  .s5wavebox .zoom button:hover { background: #26262b; }
  @media (max-width: 760px) { .s5wavebox { height: 88px; } .s5wavebox .hd { height: 34px; } .s5wavebox .tag i { display: none; }
    .s5wavebox .zoom button { width: 34px; height: 30px; } }
  `; }
  function darkVars() { return lightVars().replace(/--n([0-9a-f]{6}):#[0-9a-f]{6}/g, "--n$1:#$1"); }
  function lightVars() { return "--n050507:#fafafb; --n060608:#fafafb; --n07070c:#fafafb; --n08080a:#fafafb; --n09090b:#f4f4f5; --n0a0a0c:#f4f4f5; --n0b0c13:#f4f4f5; --n0c0c0e:#f4f4f5; --n0c0d14:#f4f4f5; --n111114:#ffffff; --n131315:#ffffff; --n131316:#ffffff; --n141416:#ffffff; --n171719:#ffffff; --n17171a:#ffffff; --n18181a:#ececf0; --n18181c:#ececf0; --n19191b:#ececf0; --n1b1b1d:#ececf0; --n1c1c20:#ececf0; --n1d1d1f:#ececf0; --n1f1f23:#ececf0; --n222224:#ececf0; --n262628:#e4e4e8; --n26262b:#e4e4e8; --n2c2c2e:#e4e4e8; --n33312a:#d4d4d8; --n3a3a3c:#d4d4d8; --n3a3a41:#d4d4d8; --n4d4d4f:#a1a1a5; --n525254:#a1a1a5; --n52525b:#a1a1a5; --n646464:#a1a1a5; --n686868:#a1a1a5; --n6b6b74:#a1a1a5; --n808080:#626266; --na1a1a1:#626266; --na1a1aa:#626266; --nc4c4c4:#3f3f43; --nd2d2d2:#3f3f43; --nd8d8d8:#09090d; --nfafafa:#09090d;"; }
  function themeCss() { return `
  :root:root { --bg: #0c0c0e; --panel: #131316; --card: #131316; --well: #08080a; --line: #26262b; --line2: #3a3a41;
    --text: #fafafa; --dim: #a1a1aa; --faint: #6b6b74; --hover: #1c1c20;
    --accent: #ff5a1f; --acc: #ff5a1f; --pink: #ff5a1f; --cyan: #ff5a1f; --violet: #d4d4d8;
    --good: #4ade80; --warn: #fbbf24; --bad: #ef4444; --font: ${FONT}; color-scheme: dark; }
  html, body { background: var(--bg) !important; }
  html body { font-family: var(--font) !important; letter-spacing: -.005em; -webkit-font-smoothing: antialiased; font-feature-settings: "cv11", "ss01"; }
  /* Sentence case everywhere, no shouting labels: what's written is what's shown. */
  html body *:not(svg):not(svg *):not(canvas) { text-transform: none !important; }
  /* Tracking was for uppercase labels; in sentence case it just looks spaced out. */
  html body *:not(svg):not(svg *):not(canvas) { letter-spacing: normal !important; }
  html body .s5bar .s5logo, html body .s5home * { letter-spacing: normal; }
  html body h2, html body h3, html body th, html body legend { font-weight: 600 !important; }
  html body :is(h2, h3) { color: var(--dim); }
  /* Controls: soft corners, one height scale, a quiet hover, orange only when on. */
  html body button, html body select, html body textarea,
  html body input:not([type=range]):not([type=checkbox]):not([type=radio]):not([type=color]) {
    border-radius: 8px !important; font-family: var(--font) !important; transition: background-color .12s, border-color .12s, color .12s, box-shadow .12s; }
  html body button { font-weight: 500 !important; border-color: var(--line2); }
  html body button:not(.on):not([aria-pressed=true]):not(:disabled):hover { border-color: #52525b !important; }
  html body button:active:not(:disabled) { transform: translateY(.5px); }
  html body button.on, html body button[aria-pressed=true] { background-color: var(--accent); border-color: var(--accent) !important; color: #fff; }
  html body select, html body textarea,
  html body input:not([type=range]):not([type=checkbox]):not([type=radio]):not([type=color]):not([type=button]):not([type=submit]) {
    background-color: var(--well) !important; border: 1px solid var(--line2) !important; color: var(--text) !important; }
  /* Page frame, the same on every page: the display and its section tabs run edge to edge; the chosen
     section sits in one centred column (--s5col) straight on the page, no box or border round it. */
  :root { --s5col: 1280px; }
  html body main.tabbed > section[data-title], html body .wrap.tabbed > .card:not(.span), html body .panel.tabbed {
    width: 100%; max-width: var(--s5col) !important; margin-left: auto; margin-right: auto; justify-self: center;
    background: transparent !important; border: 0 !important; box-shadow: none !important; }
  html body main.tabbed > section[data-title] { padding: 24px !important; }
  html body .wrap.tabbed > .card:not(.span) { padding: 24px !important; }
  html body .panel.tabbed > .card { background: transparent !important; border-left: 0 !important; border-right: 0 !important; }
  @media (max-width: 760px) { html body main.tabbed > section[data-title], html body .wrap.tabbed > .card:not(.span) { padding: 16px 12px !important; } }
  /* Dropdowns: one clean chevron, with room (the browser's own sits jammed against the edge). */
  html body select:not([multiple]) { -webkit-appearance: none; appearance: none; padding-right: 34px !important; background-repeat: no-repeat !important;
    background-position: right 12px center !important; background-size: 12px 12px !important;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M2.5 4.5 6 8l3.5-3.5' fill='none' stroke='%23a1a1aa' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important; }
  html[data-theme=light] body select:not([multiple]) {
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M2.5 4.5 6 8l3.5-3.5' fill='none' stroke='%2352525b' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important; }
  html body select:focus, html body textarea:focus, html body input:focus { outline: none; border-color: #52525b !important; box-shadow: 0 0 0 3px rgba(255,90,31,.18); }
  html body :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  html body input[type=range] { accent-color: var(--accent); }
  html body ::placeholder { color: var(--faint); }
  /* Status tags and pills: small rounded chips. */
  html body .pill, html body .tag, html body .badge, html body .chip { border-radius: 6px !important; }
  /* Pictures (previews, canvases, the 3D view) stay square: they're a projector's frame. */
  /* Thin, quiet scrollbars. */
  html body * { scrollbar-width: thin; scrollbar-color: #3a3a41 transparent; }
  html body ::-webkit-scrollbar { width: 8px; height: 8px; } html body ::-webkit-scrollbar-thumb { background: #3a3a41; border-radius: 8px; }
  html body ::-webkit-scrollbar-track { background: transparent; }
  html body ::selection { background: rgba(255,90,31,.35); }
  /* Light mode (the sun / moon in the top bar). Every grey in the pages is a --nRRGGBB variable
     (dark by default); here they're mirrored onto a light zinc scale, roles kept: page, panels,
     hover, lines, outlines, faint, dim, text. The displays (previews, waveforms, the stage, the
     fixture strips) are canvases and stay dark, like Focus's pictures: they're what the room sees. */
  html[data-theme=light]:root:root { ${lightVars()} --inv: 0,0,0;
    --bg: #f4f4f5; --panel: #ffffff; --card: #ffffff; --well: #fafafb; --line: #e4e4e7; --line2: #d4d4d8;
    --text: #09090b; --dim: #52525b; --faint: #a1a1aa; --hover: #f0f0f2; --good: #16a34a; --warn: #b45309; --bad: #dc2626; color-scheme: light; }
  html[data-theme=light] body button:not(.on):not([aria-pressed=true]):not(:disabled):hover { border-color: #a1a1aa !important; }
  html[data-theme=light] body * { scrollbar-color: #d4d4d8 transparent; }
  /* Controls that sit on a display (the stage's read-out, the deck lanes' buttons) keep the dark
     values, or they'd be dark on dark. */
  html[data-theme=light] :is(#hud, .lanectl) { ${darkVars()} --text: #fafafa; --dim: #c4c4c4; --line2: #3a3a3c; --line: #262628; }
  html[data-theme=light] body ::-webkit-scrollbar-thumb { background: #d4d4d8; }
  html body a:not([class]) { color: var(--accent); text-underline-offset: 2px; }
  @media (hover: none) { html body button:not(.on):hover { border-color: var(--line2) !important; } }
  /* Phones: nothing smaller than 40 px to hit with a thumb in a dark room. Not the deck lanes'
     overlay buttons, which are laid out to the waveform's height. */
  @media (max-width: 760px) {
    html body button:not(.lanectl button):not(.s5sect button):not(.s5wavebox button):not(.s5barn), html body select, html body a.padlink,
    html body input:not([type=range]):not([type=checkbox]):not([type=radio]):not([type=color]) { min-height: 40px; }
    html body button:not(.lanectl button):not(.s5sect button):not(.s5wavebox button):not(.s5barn) { min-width: 40px; }
    html body .s5bar .s5mode, html body .s5bar .s5spk, html body .s5bar .s5who { width: 36px; height: 36px; min-height: 36px; min-width: 36px; }
    html body .s5sect button { height: 40px; }
    html body input[type=range] { min-height: 40px; }
  }
  `; }

  const css = `
  .s5who.s5a-float { position: fixed; top: 12px; right: 12px; z-index: 9998; width: 38px; height: 38px; padding: 0; display: flex;
    align-items: center; justify-content: center; cursor: pointer; background: rgba(30,30,30,.92); border: 1px solid #555; }
  .s5who.s5a-float svg { width: 18px; height: 18px; }
  .s5who.s5a-slot { width: 36px; height: 36px; padding: 0; display: flex; align-items: center; justify-content: center; cursor: pointer;
    border-radius: 12px; background: var(--card, #131316); border: 1px solid var(--border, #26262b); }
  .s5who.s5a-slot svg { width: 16px; height: 16px; }
  .s5a-back { position: fixed; inset: 0; z-index: 9999; background: rgba(0,0,0,.6); display: flex; align-items: center; justify-content: center; }
  .s5a-box { width: min(92vw, 340px); background: var(--panel, #2b2b2b); border: 1px solid var(--line, #3e3e3e); padding: 26px;
    font: 400 14px/1.45 var(--font, system-ui, sans-serif); color: var(--text, #f2f2f2); }
  .s5a-box h3 { margin: 0 0 6px; font-weight: 500; font-size: 12px; letter-spacing: .16em; text-transform: uppercase; color: var(--dim, #9a9a9a); }
  .s5a-box p { margin: 0 0 16px; color: var(--dim, #9a9a9a); font-size: 13px; }
  .s5a-box input { width: 100%; box-sizing: border-box; font: 300 30px/1.2 var(--font, system-ui, sans-serif); letter-spacing: .3em; text-align: center;
    background: var(--well, #1f1f1f); color: var(--text, #f2f2f2); border: 1px solid var(--line2, #555); padding: 10px; outline: none; }
  .s5a-box input:focus { border-color: var(--accent, #ff5a1f); }
  .s5a-err { min-height: 18px; margin: 10px 0 0; color: var(--bad, #ef5b5b); font-size: 12px; }
  .s5a-row { display: flex; gap: 8px; margin-top: 14px; }
  .s5a-row button { flex: 1; font: 600 11px/1 var(--font, system-ui, sans-serif); letter-spacing: .14em; text-transform: uppercase; padding: 11px;
    cursor: pointer; background: transparent; color: var(--text, #f2f2f2); border: 1px solid var(--line2, #555); }
  a.s5-off { opacity: .32; cursor: not-allowed; }
  .s5a-row button.go { background: var(--accent, #ff5a1f); border-color: var(--accent, #ff5a1f); color: #111; }`;

  function el(tag, attrs = {}, html = "") {
    const e = document.createElement(tag);
    Object.entries(attrs).forEach(([k, v]) => e.setAttribute(k, v));
    e.innerHTML = html;
    return e;
  }

  // Another control page on this host. On the rig's network each service has its own port. Over
  // HTTPS (Tailscale, and the public link, which can only publish one port) every page goes through
  // the dashboard's address instead, by path: /lighting/, /projection/, /visuals/ (deckdash
  // Proxy.java). A page loaded under one of those paths sends its own /api/... requests there too.
  const PREFIX = { 8090: "/lighting", 8100: "/projection", 8110: "/visuals" };
  S5.base = Object.values(PREFIX).find(p => location.pathname === p || location.pathname.startsWith(p + "/")) || "";
  const viaPaths = location.protocol === "https:" || !!S5.base;
  S5.url = (port, path = "/") => {
    if (!viaPaths) return `${location.protocol}//${location.hostname}:${port}${path}`;
    const port0 = location.port ? ":" + location.port : "";
    return `${location.protocol}//${location.hostname}${port0}${PREFIX[+port] || ""}${path}`;
  };
  // Root paths ("/api/...") from a page under a prefix go through that prefix.
  const routed = u => (S5.base && typeof u === "string" && u[0] === "/" && u[1] !== "/" && !u.startsWith(S5.base + "/")) ? S5.base + u : u;
  S5.routed = routed;
  if (S5.base && window.EventSource) {
    const ES = window.EventSource;
    window.EventSource = class extends ES { constructor(u, o) { super(routed(String(u)), o); } };
  }
  const reach = {};   // port -> Promise<boolean>
  function reachable(port) {
    if (S5.url(port, "") === location.origin) return Promise.resolve(true);
    return (reach[port] ||= rawFetch(S5.url(port, "/s5auth.js"), { mode: "no-cors", cache: "no-store", signal: AbortSignal.timeout ? AbortSignal.timeout(5000) : undefined })
      .then(() => true, () => false));
  }
  const ICON = {
    lock: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
    unlock: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 7.7-1.5"/>',
    Decks: '<circle cx="7.5" cy="12" r="4.5"/><circle cx="16.5" cy="12" r="4.5"/><circle cx="7.5" cy="12" r=".8"/><circle cx="16.5" cy="12" r=".8"/>',
    Lighting: '<path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.8.8 1 1.7 1 2.5h6c0-.8.2-1.7 1-2.5A6 6 0 0 0 12 3z"/>',
    Projection: '<rect x="2" y="8" width="20" height="10" rx="2"/><circle cx="8" cy="13" r="3"/><path d="M14 11h5M14 14h3M6 18v2M18 18v2"/>',
    Visuals: '<path d="M2 12c2.5-6 4.5-6 6.5 0s4.5 6 7 0 4-6 6.5 0"/><path d="M2 17c2.5-3 4.5-3 6.5 0s4.5 3 7 0 4-3 6.5 0" opacity=".5"/>',
    Stage: '<path d="M3 4h18M7 4v3M17 4v3"/><path d="M7 7 4 20M7 7l4 13M17 7l-4 13M17 7l3 13" opacity=".6"/><path d="M3 20h18"/>',
    Focus: '<circle cx="12" cy="12" r="3"/><path d="M7.8 7.8a6 6 0 0 0 0 8.4M16.2 7.8a6 6 0 0 1 0 8.4M5 5a10 10 0 0 0 0 14M19 5a10 10 0 0 1 0 14"/>',
  };
  // The app has two modes: these full pages (setup and detail) and Focus (/show.html on the visuals
  // service), the simple view for running the night. Every page's top bar links to Focus. (It was
  // called Live, which clashed with the Sim / Live switch: Live there means the real decks.)
  const LIVE = [8110, "/show.html"];
  // Section tabs: one tab per section of a page's controls, in `mount` (under the display); only the
  // chosen section shows. Follows sections that come and go (e.g. a sketch's groups), and remembers
  // the choice per page. Returns { select(title) }.
  S5.sectionTabs = ({ panel, items, title, mount, first = false }) => {
    const key = "s5sect:" + location.pathname, tabs = el("nav", { class: "s5sect", role: "tablist" });
    if (first) mount.prepend(tabs); else mount.appendChild(tabs);
    let current = localStorage.getItem(key), sig = "";
    const esc = t => t.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
    function build() {
      const list = items(), names = list.map(title);
      if (!list.length) return;
      if (!names.includes(current)) current = names[0];
      const now = names.join("|") + "#" + current;
      if (now !== sig) {
        sig = now;
        tabs.innerHTML = names.map(n => `<button type="button" role="tab" data-t="${esc(n)}" aria-selected="${n === current}">${esc(n)}</button>`).join("");
      }
      list.forEach((sec, i) => sec.classList.toggle("s5-hide", names[i] !== current));
    }
    tabs.addEventListener("click", e => {
      const b = e.target.closest("button[data-t]");
      if (!b) return;
      api.select(b.dataset.t);
      b.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "smooth" });
    });
    new MutationObserver(recs => { if (recs.some(r => !tabs.contains(r.target))) build(); }).observe(panel, { childList: true, subtree: true });
    const api = { select(t) { current = t; localStorage.setItem(key, t); build(); } };
    build();
    return api;
  };
  const svg = (name, extra = "") => `<svg viewBox="0 0 24 24" aria-hidden="true" ${extra}>${ICON[name]}</svg>`;
  S5.icon = svg;
  // Phones: a tab bar with the same links as the top bar.
  function tabs() {
    const top = document.querySelector(".s5bar nav.pages");
    if (!top || document.querySelector(".s5tabs")) return;
    const here = (top.querySelector("a.here") || {}).textContent;
    const nav = el("nav", { class: "s5tabs", "aria-label": "Pages" });
    // The same order as Focus's tab bar (Decks · Lights · Visuals · Mapping · Stage), then Focus.
    nav.innerHTML = [["Decks", 8080, "/"], ["Lighting", 8090, "/"], ["Visuals", 8110, "/"], ["Projection", 8100, "/edit"], ["Stage", 8100, "/stage.html"], ["Focus", ...LIVE]]
      .map(([n, port, path]) => `<a data-port="${port}" data-path="${path}" class="${n === here ? "here" : ""}">${svg(n)}<span>${n}</span></a>`).join("");
    document.body.appendChild(nav);
  }
  function liveLink() {
    const top = document.querySelector(".s5bar nav.pages");
    if (!top || top.querySelector(".s5live")) return;
    top.appendChild(el("a", { class: "s5live", "data-port": LIVE[0], "data-path": LIVE[1], title: "Focus: the simple view for running the night" }, "<i></i>Focus"));
  }
  function links() {
    liveLink();
    modeButton();
    tabs();
    document.querySelectorAll("a[data-port]").forEach(a => {
      a.href = S5.url(a.dataset.port, a.dataset.path || "/");
      if (a.classList.contains("here")) return;
      const off = why => { a.classList.toggle("s5-off", !!why); a.toggleAttribute("aria-disabled", !!why); a.title = why || a.dataset.title || ""; };
      if (a.dataset.title === undefined) a.dataset.title = a.title || "";
      if (S5.enabled && !S5.admin) return off("Admin only. Unlock with the PIN (the lock, top right) to open this page.");
      off("");
      reachable(a.dataset.port).then(ok => { if (ok || !S5.admin) return; off("Not reachable from here. Use the rig's Wi-Fi or Tailscale."); });
    });
  }
  // Inside the simulation's sound player (/shell, s5shell.html): tell it which page this is, keep the
  // page links in the player (so the sound keeps playing), and pass taps up (they let sound start).
  S5.inShell = window.parent !== window && window.name === "s5shell";
  S5.shellUrl = target => S5.url(8080, "/shell") + "#" + encodeURIComponent(target || location.href);
  if (S5.inShell) {
    const hello = () => parent.postMessage({ s5: "here", url: location.href, title: document.title }, "*");
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", hello); else hello();
    addEventListener("pointerdown", () => parent.postMessage({ s5: "gesture" }, "*"), true);
    document.addEventListener("click", e => {
      const a = e.target.closest && e.target.closest("a[href]");
      if (!a || e.defaultPrevented || a.target === "_blank" || e.metaKey || e.ctrlKey) return;
      e.preventDefault();
      parent.postMessage({ s5: "nav", url: a.href }, "*");
    });
  }
  document.addEventListener("click", e => {
    const a = e.target.closest && e.target.closest("a.s5-off");
    if (a) { e.preventDefault(); if (S5.enabled && !S5.admin) prompt("That page is admin only. Enter the PIN."); }
  }, true);

  let badge;
  function render() {
    document.documentElement.classList.toggle("s5-viewer", S5.enabled && !S5.admin);
    document.documentElement.classList.toggle("s5-admin", S5.enabled && S5.admin);
    if (!badge) return links();
    badge.innerHTML = svg(S5.admin ? "unlock" : "lock", 'fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"');
    badge.title = S5.admin ? "Admin: unlocked on this browser. Click to lock it again." : "View only. Click to unlock with the admin PIN.";
    badge.setAttribute("aria-label", badge.title);
    badge.style.display = S5.enabled ? "" : "none";
    if (badge.classList.contains("s5a-float") || badge.classList.contains("s5a-slot")) badge.style.color = S5.admin ? "#7ccf8a" : "#ff5a1f";
    links();
  }

  async function status() {
    try {
      const r = await rawFetch("/api/auth", { cache: "no-store", credentials: "same-origin" });
      if (r.ok) {
        Object.assign(S5, await r.json());
        try { localStorage.setItem("s5auth", JSON.stringify({ enabled: S5.enabled, admin: S5.admin })); } catch (e) { /* private mode */ }
      }
    } catch (e) { /* offline: keep last known */ }
    S5.ready = true;
    render();
    window.dispatchEvent(new CustomEvent("s5auth", { detail: { ...S5 } }));
  }

  function prompt(reason) {
    if (pending) return pending;
    pending = new Promise(resolve => {
      const back = el("div", { class: "s5a-back" }, `
        <form class="s5a-box" autocomplete="off">
          <h3>Admin PIN</h3>
          <p>${reason || "Enter the PIN to control the rig. This browser stays unlocked."}</p>
          <input type="password" inputmode="numeric" autocomplete="off" aria-label="PIN" maxlength="32">
          <div class="s5a-err"></div>
          <div class="s5a-row"><button type="button" class="no">Cancel</button><button type="submit" class="go">Unlock</button></div>
        </form>`);
      const form = back.querySelector("form"), input = back.querySelector("input"), err = back.querySelector(".s5a-err");
      const done = ok => { back.remove(); pending = null; if (!ok) quietUntil = Date.now() + 10000; resolve(ok); };
      back.querySelector(".no").onclick = () => done(false);
      back.addEventListener("click", e => { if (e.target === back) done(false); });
      back.addEventListener("keydown", e => { if (e.key === "Escape") done(false); });
      form.onsubmit = async e => {
        e.preventDefault();
        err.textContent = "Checking…";
        try {
          const r = await rawFetch("/api/auth", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" },
                                                  body: JSON.stringify({ pin: input.value }) });
          const d = await r.json().catch(() => ({}));
          if (r.ok && d.admin) { S5.admin = true; render(); done(true); return; }
          err.textContent = r.status === 429 ? `Too many attempts. Try again in ${Math.ceil((d.retry_s || 600) / 60)} min.` : "Wrong PIN.";
          input.value = ""; input.focus();
        } catch (e2) { err.textContent = "Can't reach the brain."; }
      };
      document.body.appendChild(back);
      setTimeout(() => input.focus(), 30);
    });
    return pending;
  }

  // Changes (non-GET) need admin: ask for the PIN first if we know we're view-only, and again on 401.
  window.fetch = async (input, init = {}) => {
    if (typeof input === "string") input = routed(input);
    const method = String(init.method || (input instanceof Request ? input.method : "GET")).toUpperCase();
    const url = String(input instanceof Request ? input.url : input);
    if (method === "GET" || method === "HEAD" || url.includes("/api/auth") || url.includes("/api/screen")) return rawFetch(input, init);
    const refused = () => new Response(JSON.stringify({ error: "view only" }), { status: 401, headers: { "Content-Type": "application/json" } });
    if (S5.enabled && !S5.admin) {
      if (Date.now() < quietUntil || !(await prompt())) return refused();
    }
    let r = await rawFetch(input, init);
    if (r.status === 401) {
      S5.admin = false; render();
      if (Date.now() >= quietUntil && (await prompt("That needs admin. Enter the PIN."))) r = await rawFetch(input, init);
    }
    return r;
  };

  function mount() {
    const style = el("style"); style.textContent = css; document.head.appendChild(style);
    // The lock sits at the right end of the top bar; pages without one get it floating top right.
    const bar = document.querySelector(".s5bar"), slot = document.querySelector("[data-s5lock]");
    badge = el("button", { class: bar ? "s5who" : slot ? "s5who s5a-slot" : "s5who s5a-float", type: "button" });
    badge.style.display = "none";
    badge.onclick = async () => {
      if (!S5.admin) return prompt();
      if (!confirm("Lock this browser? You'll need the PIN again to control the rig.")) return;
      await rawFetch("/api/auth/logout", { method: "POST", credentials: "same-origin" }).catch(() => {});
      status();
    };
    (bar || slot || document.body).appendChild(badge);
    render();
    status();
    setInterval(status, 60000);
  }
  if (document.body) mount(); else document.addEventListener("DOMContentLoaded", mount);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", links);

  // The System view (click the logo) lives on the dashboard; every page loads it from there.
  function loadSystem() {
    if (!document.querySelector(".s5bar .s5home") || window.S5SYS) return;
    const sc = document.createElement("script");
    sc.src = S5.url(8080, "/s5system.js");
    sc.async = true;
    document.head.appendChild(sc);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", loadSystem); else loadSystem();
})();
