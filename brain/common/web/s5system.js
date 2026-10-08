// Sektor5 System view: brain health, opened by clicking the logo on any control page.
//
// Served by deckdash (/s5system.js) and loaded by /s5auth.js on every page, so there's one copy.
// Data comes from the dashboard's /api/system (sampled every 2 s by deckdash). It also puts a health
// dot beside the logo. The view's top bar is a copy of the shared bar (.s5bar) with the page's own
// logo, so the logo doesn't move.
(() => {
  "use strict";
  if (window.S5SYS) return;
  const API = window.S5AUTH && S5AUTH.url ? S5AUTH.url(8080, "").replace(/\/$/, "") : "";
  const css = `
  #sys { position: fixed; inset: 0; z-index: 9990; background: var(--bg); overflow: auto; display: none; color: var(--text);
    font: 400 14px/1.45 var(--font); letter-spacing: .01em; text-align: left;
    --bg: #0c0c0e; --panel: #131315; --line: #262628; --line2: #3a3a3c; --text: #fafafa; --dim: #a1a1a1; --accent: #ff5a1f; --accent2: #ff5a1f;
    --good: #7ccf8a; --warn: #f2b84b; --bad: #ef5b5b; --well: #08080a;
    --font: "Inter", -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, system-ui, sans-serif; }
  #sys *, #sys *::before { box-sizing: border-box; }
  .s5logo { display: flex; align-items: center; line-height: 1; } .s5logo .s5word { color: #fafafa; display: block; flex: none; }
  .s5logo .s5five { fill: #ff5a1f; }
  #simpop { position: fixed; top: calc(var(--s5bar, 48px) + 8px); right: 12px; z-index: 9992; width: min(340px, calc(100vw - 24px)); display: none; padding: 20px;
    background: #131315; border: 1px solid #3a3a3c; color: #fafafa; font: 400 13px/1.45 "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    box-shadow: 0 12px 40px rgba(0,0,0,.5); animation: s5in .2s ease; }
  #simpop.open { display: block; }
  #simpop h4 { margin: 0 0 6px; font: 600 11px/1 "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; letter-spacing: .16em; text-transform: uppercase; color: #f2b84b; }
  #simpop.offer h4 { color: #a1a1a1; }
  #simpop p { margin: 0 0 14px; color: #a1a1a1; }
  #simpop .row { display: flex; gap: 10px; align-items: center; margin-top: 10px; }
  #simpop button { flex: none; font: 600 11px/1 "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; letter-spacing: .12em; text-transform: uppercase;
    padding: 11px 12px; cursor: pointer; background: transparent; color: #fafafa; border: 1px solid #3a3a3c; }
  #simpop button.wide { flex: 1; }
  #simpop button:hover { border-color: #ff5a1f; }
  #simpop button.go { background: #ff5a1f; border-color: #ff5a1f; color: #050507; }
  #simpop button:disabled { opacity: .5; cursor: wait; }
  #simpop input[type=range] { flex: 1; min-width: 0; accent-color: #ff5a1f; }
  #sys.open { animation: s5in .25s ease; }
  #sys.open { display: block; }
    #sys .sys-title { animation: s5in .3s ease; font-weight: 500; font-size: 13px; letter-spacing: .16em; text-transform: uppercase; color: var(--text);
                    padding-left: 20px; border-left: 1px solid var(--line); line-height: 28px; }
  #sys .sys-top .sp { flex: 1; }
  #sys .sys-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); border-left: 1px solid var(--line);
                   max-width: 1680px; margin: 0 auto; }
  #sys .card { border-right: 1px solid var(--line); border-bottom: 1px solid var(--line); padding: 22px 28px; min-height: 160px; }
  #sys .card h2 { margin: 0 0 16px; font-weight: 500; font-size: 12px; letter-spacing: .16em; text-transform: uppercase; color: var(--dim); }
  #sys .card h2 i { font-style: normal; color: var(--accent); margin-right: 6px; }
  #sys .big { font-weight: 300; font-size: 44px; line-height: 1; font-variant-numeric: tabular-nums; }
  #sys .big small { font-size: 16px; color: var(--dim); margin-left: 4px; }
  #sys .kv { display: flex; justify-content: space-between; gap: 12px; padding: 5px 0; border-bottom: 1px solid var(--line); font-size: 13px; }
  #sys .kv:last-child { border-bottom: 0; }
  #sys .kv span { color: var(--dim); } #sys .kv b { font-weight: 500; text-align: right; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
  #sys .bar { height: 6px; background: var(--well); margin: 10px 0 14px; position: relative; }
  #sys .bar div { position: absolute; left: 0; top: 0; bottom: 0; background: var(--good); transition: width .4s; }
  #sys .cores { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; margin-bottom: 12px; }
  #sys .cores div { background: var(--well); height: 42px; position: relative; }
  #sys .cores div i { position: absolute; left: 0; right: 0; bottom: 0; background: var(--accent); opacity: .8; transition: height .4s; }
  #sys .cores div span { position: absolute; left: 6px; top: 4px; font-size: 11px; color: var(--dim); }
  #sys .ok { color: var(--good); } #sys .warn { color: var(--warn); } #sys .bad { color: var(--bad); }
  #sys table { width: 100%; border-collapse: collapse; font-size: 13px; }
  #sys th { text-align: left; font-weight: 500; font-size: 11px; letter-spacing: .12em; text-transform: uppercase; color: var(--dim);
            padding: 0 6px 8px 0; border-bottom: 1px solid var(--line); }
  #sys td { padding: 7px 6px 7px 0; border-bottom: 1px solid var(--line); font-variant-numeric: tabular-nums; vertical-align: top; }
  #sys td:nth-child(n+3) { white-space: nowrap; }
  #sys .flags { display: flex; flex-wrap: wrap; gap: 6px; }
  #sys .flag { font-size: 11px; font-weight: 600; letter-spacing: .08em; padding: 3px 8px; border: 1px solid var(--line2); color: var(--dim); }
  #sys .flag.bad { border-color: var(--bad); color: var(--bad); } #sys .flag.warn { border-color: var(--warn); color: var(--warn); }
  #sys .flag.ok { border-color: var(--good); color: var(--good); }
  #sys .muted { color: var(--dim); font-size: 12px; }
  #sys .acts { display: flex; gap: 8px; margin-top: 16px; }
  #sys .acts button { flex: 1; font: 600 11px/1 var(--font); letter-spacing: .14em; text-transform: uppercase; padding: 11px 8px; cursor: pointer;
    background: transparent; color: var(--text); border: 1px solid var(--line2); }
  #sys .acts button:hover { border-color: var(--accent); }
  #sys .acts button:disabled { opacity: .4; cursor: wait; }
  #sys a { color: var(--accent2); }`;
  const dotCss = `
  .s5bar > .s5right { margin-left: auto; display: flex; gap: 6px; align-items: center; flex: none; position: sticky; right: 36px; background: var(--bg, #0c0c0e); }
  .s5bar > .s5right + .s5who { margin-left: 8px; }
  .s5right > .s5sim { flex: none; display: none; align-items: center; gap: 7px; height: 28px; padding: 0 10px; cursor: pointer; border-radius: 8px; background: var(--bg, #0c0c0e); color: var(--na1a1a1, #a1a1a1); border: 1px solid var(--n3a3a3c, #3a3a3c);
    font: 600 11px/1 "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; letter-spacing: .14em; text-transform: uppercase; }
  .s5right > .s5sim.on, .s5right > .s5sim.live, .s5right > .s5sim.none, .s5right > .s5sim.offline { display: flex; }
  .s5right > .s5sim.on { color: #f2b84b; border-color: #f2b84b; }
  .s5right > .s5sim.live { color: #7ccf8a; border-color: #7ccf8a; }
  .s5right > .s5spk { flex: none; width: 28px; height: 28px; padding: 0; display: grid; place-items: center; cursor: pointer; border-radius: 8px; background: var(--bg, #0c0c0e); color: var(--na1a1a1, #a1a1a1); border: 1px solid var(--n3a3a3c, #3a3a3c); }
  .s5right > .s5spk svg { width: 16px; height: 16px; }
  .s5right > .s5spk.on { color: #f2b84b; border-color: #f2b84b; }
  .s5right > .s5spk.wait { color: #f2b84b; border-color: #f2b84b; animation: s5pulse 1s ease-in-out infinite; }
  .s5right > .s5sim.offline { color: #ef5b5b; border-color: #ef5b5b; }
  .s5right > .s5sim i { width: 7px; height: 7px; border-radius: 50%; background: currentColor; }
  .s5right > .s5sim.on i { animation: s5pulse 1.2s ease-in-out infinite; }
  .s5bar #conn, .herobar #conn { display: none !important; }   /* the status pill (right) says it all */
  @keyframes s5pulse { 50% { opacity: .35; } }
  .s5home .hdot { position: absolute; left: 88px; top: 50%; width: 7px; height: 7px; margin-top: -3.5px; border-radius: 50%; background: var(--n3a3a3c, #3a3a3c);
    opacity: 0; transition: opacity .4s, background .4s; }
  .s5home .hdot.ok, .s5home .hdot.warn, .s5home .hdot.bad { opacity: 1; }
  .s5home .hdot.ok { background: #7ccf8a; } .s5home .hdot.warn { background: #f2b84b; } .s5home .hdot.bad { background: #ef5b5b; box-shadow: 0 0 8px #ef5b5b; }`;
  // The view lives in a shadow root so each page's own CSS (h2 counters, .card, button, a…) can't leak in.
  const hostEl = document.createElement("div");
  hostEl.id = "s5sys";
  hostEl.style.cssText = "position: relative; z-index: 9990;";   // above every page's sticky bar
  const root = hostEl.attachShadow({ mode: "open" });
  root.innerHTML = `<style>:host { all: initial; } ${(window.S5AUTH && S5AUTH.barCss) || ""} ${css}</style>` +
    `<div id="sys" aria-hidden="true"><div class="s5bar sys-top"><div class="s5home" id="sysLogo" title="Back to the app"></div>` +
    `<span class="sys-title">System</span><span class="muted" id="sysHost"></span><span class="sp"></span><span class="muted" id="sysAge"></span></div>` +
    `<div class="sys-grid" id="sysGrid"></div></div><div id="simpop" role="dialog" aria-label="Simulation"></div>`;
  document.body.appendChild(hostEl);
  const sysEl = root.getElementById("sys");
  // The health dot sits beside the page's own logo (outside the shadow root).
  const dotStyle = document.createElement("style");
  dotStyle.textContent = dotCss;
  document.head.appendChild(dotStyle);
  const home = document.querySelector(".s5bar .s5home");
  let dot = null;
  if (home) {
    dot = document.createElement("span");
    dot.className = "hdot";
    home.appendChild(dot);
    home.title = "System";
    home.addEventListener("click", () => sysOpen(!sysEl.classList.contains("open")));
    // Same logo, same place: the System bar reuses the page's own.
    const logo = home.querySelector(".s5logo");
    if (logo) root.getElementById("sysLogo").appendChild(logo.cloneNode(true));
  }
  root.getElementById("sysLogo").addEventListener("click", () => sysOpen(false));

  let sysTimer = null, sysLast = null;
  const fmtUp = s => { const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return (d ? d + "d " : "") + (d || h ? h + "h " : "") + m + "m"; };
  const lvl = (v, warn, bad, higherIsWorse = true) => higherIsWorse ? (v >= bad ? "bad" : v >= warn ? "warn" : "ok")
                                                                     : (v <= bad ? "bad" : v <= warn ? "warn" : "ok");
  const kvs = rows => rows.filter(Boolean).map(([k, v, c]) => `<div class="kv"><span>${k}</span><b class="${c || ""}">${v}</b></div>`).join("");
  // Simulation pauses the mixer service on purpose: not a fault.
  const simPaused = (d, s) => s.name === "mixer" && d.sim && d.sim.on;
  function sysHealth(d) {
    const t = d.throttle || {}, worst = [];
    if (d.cpu.temp_c >= 80 || t.under_voltage_now || t.throttled_now || d.disk.free_gb < 1 ||
        (d.services || []).some(s => s.state !== "active" && !simPaused(d, s))) worst.push("bad");
    if (d.cpu.temp_c >= 70 || t.under_voltage_since_boot || t.throttled_since_boot || t.soft_temp_limit_now ||
        d.disk.free_gb < 3 || d.memory.used_mb / d.memory.total_mb > 0.85 || (d.network.wifi.signal_dbm && d.network.wifi.signal_dbm < -75) ||
        (d.services || []).some(s => s.restarts > 0)) worst.push("warn");
    return worst.includes("bad") ? "bad" : worst.includes("warn") ? "warn" : "ok";
  }
  function sysRender(d) {
    root.getElementById("sysHost").textContent = d.host;
    const u = d.cpu.usage || [0], t = d.throttle, m = d.memory, memPct = m.used_mb / m.total_mb * 100;
    const tempC = lvl(d.cpu.temp_c, 70, 80), cpuC = lvl(u[0], 75, 90), memC = lvl(memPct, 75, 90), diskC = lvl(d.disk.free_gb, 3, 1, false);
    // Power and clock problems: only list the ones that have happened (red now, amber earlier since boot).
    const flag = (on, since, label) => on || since ? `<span class="flag ${on ? "bad" : "warn"}">${label}${on ? " NOW" : " SINCE BOOT"}</span>` : "";
    const wifi = d.network.wifi, sig = wifi.signal_dbm, sigC = sig ? lvl(sig, -70, -80, false) : "";
    const card = (n, title, body) => `<section class="card"><h2><i>${String(n).padStart(2, "0")}</i>— ${title}</h2>${body}</section>`;
    const svcRows = (d.services || []).map(s => `<tr><td>${s.name}</td><td class="${s.state === "active" ? "ok" : simPaused(d, s) ? "warn" : "bad"}">${s.state === "active" ? s.sub : simPaused(d, s) ? "paused (sim)" : s.state}</td>
      <td>${s.cpu_pct >= 0 ? s.cpu_pct.toFixed(1) + "%" : "–"}</td><td>${s.mem_mb >= 0 ? Math.round(s.mem_mb) + " MB" : "–"}</td>
      <td class="${s.restarts ? "warn" : ""}">${s.restarts}</td></tr>`).join("");
    const cl = d.clients || { ports: [] };
    const clRows = cl.ports.map(p => `<tr><td>${p.page}<div class="muted">:${p.port}</div></td><td>${p.devices}</td>
      <td class="muted">${p.addresses.length ? p.addresses.map(a => a.startsWith("fe80") ? "IPv6 link-local" : a).join("<br>") : "–"}</td></tr>`).join("");
    root.getElementById("sysGrid").innerHTML = [
      card(1, "Temperature", `<div class="big ${tempC}">${d.cpu.temp_c.toFixed(1)}<small>°C</small></div>
        <div class="bar"><div style="width:${Math.min(100, d.cpu.temp_c / 85 * 100)}%;background:var(--${tempC === "ok" ? "good" : tempC})"></div></div>
        ${(() => { const f = flag(t.under_voltage_now, t.under_voltage_since_boot, "UNDER-VOLTAGE") + flag(t.throttled_now, t.throttled_since_boot, "THROTTLED") +
            flag(t.freq_capped_now, t.freq_capped_since_boot, "FREQ CAP") + flag(t.soft_temp_limit_now, t.soft_temp_limit_since_boot, "TEMP LIMIT");
          return f ? `<div class="flags">${f}</div>` : `<div class="ok" style="font-size:12px">Power and clock speed normal since boot</div>`; })()}`),
      card(2, "CPU", `<div class="big ${cpuC}">${u[0].toFixed(0)}<small>%</small></div><div class="bar"><div style="width:${u[0]}%"></div></div>
        <div class="cores">${u.slice(1).map((c, i) => `<div><i style="height:${c}%"></i><span>${i} · ${c.toFixed(0)}%</span></div>`).join("")}</div>
        ${kvs([["Load (1/5/15 min)", d.cpu.load.split(" ").slice(0, 3).join(" · ")], ["Clock", d.cpu.mhz + " MHz"], ["Uptime", fmtUp(d.uptime_s)]])}`),
      card(3, "Memory", `<div class="big ${memC}">${Math.round(memPct)}<small>%</small></div><div class="bar"><div style="width:${memPct}%"></div></div>
        ${kvs([["Used", `${m.used_mb} / ${m.total_mb} MB`], ["Available", m.available_mb + " MB"], ["Swap used", `${m.swap_used_mb} / ${m.swap_total_mb} MB`, m.swap_used_mb > 100 ? "warn" : ""],
               ["deckdash heap", `${d.deckdash_jvm.heap_used_mb} / ${d.deckdash_jvm.heap_max_mb} MB`]])}`),
      card(4, "Storage", `<div class="big ${diskC}">${d.disk.free_gb}<small>GB free</small></div>
        <div class="bar"><div style="width:${(1 - d.disk.free_gb / d.disk.total_gb) * 100}%"></div></div>
        ${kvs([["Total", d.disk.total_gb + " GB"], ["Set recordings", `${d.disk.recordings_gb} GB · ${d.disk.recordings_files} files`]])}`),
      card(5, "Network", kvs([
        ["Wi-Fi signal", sig ? `${sig} dBm · ${wifi.quality_pct}%` : "–", sigC],
        ...d.network.interfaces.map(i => [i.name === "wlan0" ? "Wi-Fi (fixtures)" : "Ethernet (decks)",
          `${i.up ? "" : "DOWN · "}${i.addresses || "no address"}<div class="muted">↓ ${i.rx_kbps >= 1000 ? (i.rx_kbps / 1000).toFixed(1) + " Mb/s" : i.rx_kbps + " kb/s"} · ↑ ${i.tx_kbps >= 1000 ? (i.tx_kbps / 1000).toFixed(1) + " Mb/s" : i.tx_kbps + " kb/s"}</div>`,
          i.up ? "" : "bad"])])),
      card(6, "Services", `<table><tr><th>Service</th><th>State</th><th>CPU</th><th>Mem</th><th>Restarts</th></tr>${svcRows}</table>`),
      card(7, "Clients", `<div class="big">${cl.devices}<small>devices</small></div>
        <p class="muted">${cl.dashboard_streams} live dashboard stream${cl.dashboard_streams === 1 ? "" : "s"}</p>
        <table><tr><th>Page</th><th>Devices</th><th>From</th></tr>${clRows}</table>`),
      card(8, "Hardware", kvs([
        ["DJ Link devices", d.djlink_devices],
        d.case_fan && ["Case fan (Argon ONE)", d.case_fan.fan_pct ? `${d.case_fan.fan_pct}%` : "off (cool)", Date.now() / 1000 - d.case_fan.ts > 30 ? "warn" : ""],
        ...(d.usb || []).map(x => [x.name, `<span class="muted">${x.id}</span>`]),
        !(d.usb || []).some(x => x.id === "2b73:0013") && ["DJM-450", "not connected", "warn"],
        !(d.usb || []).some(x => x.id === "16c0:05dc") && ["uDMX (par can)", "not connected", "warn"]])),
      card(9, "Tailscale", tsCard(d.tailscale || {})),
    ].join("");
  }
  // Tailscale: the public link (Funnel, dashboard only) and remote access for the team.
  function tsCard(ts) {
    if (!ts.installed) return `<div class="big warn">Not installed</div>`;
    const on = ts.state === "Running", label = { Running: "Connected", Stopped: "Off", NeedsLogin: "Needs login", Starting: "Starting" }[ts.state] || ts.state;
    return `<div class="big ${on ? "ok" : "warn"}">${label}</div>
      ${kvs([
        ["Name", ts.dns_name || "–"],
        ["Address", (ts.ips || [])[0] || "–"],
        ["Tailnet", ts.tailnet || "–"],
        ["Devices online", on ? `${ts.peers_online} of ${ts.peers}` : "–"],
        ["Public link", ts.funnel ? `<a href="${ts.public_url}" target="_blank" rel="noopener">${ts.public_url.replace(/^https:\/\/|\/$/g, "")}</a>` : "off", ts.funnel ? "ok" : ""],
        ["Tailnet-only HTTPS", (ts.https_ports || []).filter(p => p !== 443).map(p => ":" + p).join(" ") || "–"],
        ts.auth_url && ["Log in", `<a href="${ts.auth_url}" target="_blank" rel="noopener">approve this device</a>`, "warn"],
        ["Version", (ts.version || "").split("-")[0]],
      ])}
      <div class="acts">
        ${on ? `<button data-ts='{"funnel":${!ts.funnel}}'>${ts.funnel ? "Turn off public link" : "Turn on public link"}</button>` : ""}
        <button data-ts='{"up":${!on}}'>${on ? "Turn off Tailscale" : "Turn on Tailscale"}</button>
      </div>`;
  }
  root.getElementById("sysGrid").addEventListener("click", async e => {
    const b = e.target.closest("button[data-ts]");
    if (!b) return;
    const req = JSON.parse(b.dataset.ts), viaTs = /\.ts\.net$|^100\./.test(location.hostname);
    if (req.funnel === false && !confirm("Turn off the public link? The dashboard stays available on the tailnet.")) return;
    if (req.up === false && !confirm(viaTs
        ? "You're connected through Tailscale. Turning it off cuts this page off, and the public link goes too. Turn it back on from the rig's Wi-Fi. Continue?"
        : "Turn off Tailscale? Remote access and the public link stop until it's turned back on.")) return;
    b.disabled = true; b.textContent = "Working…";
    try {
      const r = await fetch(API + "/api/system/tailscale", { method: "POST", credentials: "include", headers: { "Content-Type": "text/plain" }, body: JSON.stringify(req) });
      if (r.ok && sysLast) { sysLast.tailscale = await r.json(); sysRender(sysLast); }
    } catch (e2) { /* lost the connection (e.g. Tailscale off while using it) */ }
    sysPoll();
  });
  async function sysPoll() {
    try {
      const d = await (await fetch(API + "/api/system", { cache: "no-store" })).json();
      if (!d.ready) return;
      sysLast = d;
      simRender(d.sim);
      const h = sysHealth(d);
      if (dot) dot.className = "hdot " + h;
      if (dot) dot.title = h === "ok" ? "System healthy" : h === "warn" ? "System: needs a look" : "System: problem";
      if (sysEl.classList.contains("open")) { sysRender(d); root.getElementById("sysAge").textContent = "updated " + new Date(d.ts).toLocaleTimeString(); }
    } catch (e) {
      if (dot) { dot.className = "hdot bad"; dot.title = "Can't reach the dashboard"; }
      pill.className = "s5sim offline"; pill.innerHTML = "Offline"; pill.title = "Can't reach the brain";
    }
  }
  function sysOpen(on) {
    sysEl.classList.toggle("open", on); sysEl.setAttribute("aria-hidden", on ? "false" : "true");
    clearInterval(sysTimer);
    sysTimer = setInterval(sysPoll, on ? 2000 : 10000);
    if (on) { if (sysLast) sysRender(sysLast); sysPoll(); }
  }
  // Simulation mode (deckdash Sim.java). A pill in the top bar, next to the lock: SIM while the
  // synthetic rig runs (the page's LIVE pill hides: it isn't the decks), NO DECKS when none are found.
  // Tapping it opens a small panel: sound and volume, back to real decks / start simulation.
  const pop = root.getElementById("simpop");
  // Sound on/off and volume: cookies, because those are shared by every page on this host (each page
  // has its own port on the rig's network, and localStorage is per port).
  const pref = k => (document.cookie.match(new RegExp("(?:^|; )" + k + "=([^;]*)")) || [])[1] || null;
  const setPref = (k, v) => { document.cookie = `${k}=${encodeURIComponent(v)}; path=/; max-age=31536000; SameSite=Lax`; };
  let simState = null;
  addEventListener("s5sound", () => { if (simState) simRender(simState); if (pop.classList.contains("open")) popRender(); });
  const pill = document.createElement("button");
  pill.type = "button";
  pill.className = "s5sim";
  const bar = document.querySelector(".s5bar");
  // Right-hand group, next to the lock: [speaker] [status pill].
  // (s5auth.js may have made it already, for the appearance button.)
  let right = bar && bar.querySelector(".s5right");
  if (!right) { right = document.createElement("span"); right.className = "s5right"; if (bar) bar.insertBefore(right, bar.querySelector(".s5who")); }
  if (bar) right.prepend(pill);
  // Speaker, left of the pill while the sim runs: sound on/off in one tap. The sound lives in the
  // player (/shell): from a normal page, turning it on moves you into the player.
  const inShell = !!(window.S5AUTH && S5AUTH.inShell);
  let sound = { playing: false, blocked: false };
  const spk = document.createElement("button");
  spk.type = "button"; spk.className = "s5spk";
  const SPK_ON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 9h4l5-4v14l-5-4H4z" fill="currentColor"/><path d="M16 9a4 4 0 0 1 0 6M18.5 6.5a8 8 0 0 1 0 11"/></svg>';
  const SPK_OFF = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 9h4l5-4v14l-5-4H4z" fill="currentColor"/><path d="M16.5 9.5l5 5M21.5 9.5l-5 5"/></svg>';
  function spkRender() {
    const on = inShell && sound.playing, wait = inShell && sound.blocked;
    spk.className = "s5spk" + (on ? " on" : "") + (wait ? " wait" : "");
    spk.innerHTML = on ? SPK_ON : SPK_OFF;
    spk.title = wait ? "Tap anywhere to start the sound" : on ? "Sound on. Tap to mute." : "Sound off. Tap to play the simulation's sound.";
    spk.setAttribute("aria-label", spk.title);
  }
  function setSound(on) {
    setPref("s5sound", on ? "1" : "0");
    if (inShell) parent.postMessage({ s5: "sound", on }, "*");
    else if (on) location.href = S5AUTH.shellUrl(location.href);                 // into the player, this page in it
  }
  spk.addEventListener("click", e => { e.stopPropagation(); setSound(!(inShell && sound.playing)); });
  addEventListener("message", e => { if (e.data && e.data.s5 === "sound") { sound = e.data; spkRender(); if (pop.classList.contains("open")) popRender(); } });
  right.insertBefore(spk, pill);
  spkRender();
  if (inShell) parent.postMessage({ s5: "sound?" }, "*");        // this page loaded after the player's last word
  function simRender(sim) {
    if (!sim) return;
    simState = sim;
    // One status pill: SIM, LIVE (decks on DJ Link) or NO DECKS. Tap it to switch.
    const mode = sim.on ? "on" : sim.djlink && sim.decks > 0 ? "live" : "none";
    document.documentElement.classList.toggle("s5-sim", !!sim.on);
    pill.className = "s5sim " + mode;
    pill.innerHTML = { on: "<i></i>Sim", live: "<i></i>Live", none: "No decks" }[mode];
    spk.style.display = sim.on ? "" : "none";
    pill.title = { on: "Simulation: a synthetic DJ set. Tap for sound or to go back to the real decks.",
                   live: `Live: ${sim.decks} deck${sim.decks === 1 ? "" : "s"} on DJ Link. The simulation is off while real decks are connected.`,
                   none: "No decks found. Tap to run a simulation." }[mode];
    if (pop.classList.contains("open")) popRender();
  }
  function popRender() {
    const sim = simState || {}, playing = inShell && sound.playing, vol = +(pref("s5vol") || 0.8);
    const live = !sim.on && sim.djlink && sim.decks > 0, canSim = sim.available;
    pop.className = "open" + (sim.on ? "" : " offer");
    pop.innerHTML = live
      ? `<h4 style="color:#7ccf8a">Live</h4><p>${sim.decks} deck${sim.decks === 1 ? "" : "s"} on DJ Link: the lights follow the real set. The simulation is only offered with no decks connected.</p>`
      : sim.on
      ? `<h4>Simulation</h4><p>A synthetic DJ set at ${Math.round(sim.bpm || 126)} BPM. The lights, projection and visuals follow it.</p>` +
        `<div class="row"><button data-sim="sound" class="${playing ? "go" : ""}">${playing ? "Sound on" : "Sound off"}</button>` +
        `<input type="range" min="0" max="1" step="0.05" value="${vol}" data-sim="vol" aria-label="Volume"></div>` +
        `<div class="row"><button data-sim="off" class="wide">Back to real decks</button></div>`
      : `<h4>No decks found</h4><p>Run a synthetic DJ set to try the rig. Everything else is real, including the lights.</p>` +
        (canSim ? `<div class="row"><button data-sim="on" class="go wide">Start simulation</button><button data-sim="x">Close</button></div>` : "");
  }
  pill.addEventListener("click", e => {
    e.stopPropagation();
    if (pop.classList.contains("open")) pop.classList.remove("open"); else popRender();
  });
  document.addEventListener("click", e => { if (!e.composedPath().includes(hostEl) && e.target !== pill) pop.classList.remove("open"); });
  addEventListener("keydown", e => { if (e.key === "Escape") pop.classList.remove("open"); });
  // Simulation audio (s5audio.js, from the dashboard): a synth that follows the show, in this browser.
  function loadAudio() {
    if (window.S5AUDIO) return Promise.resolve();
    return new Promise((ok, fail) => { const sc = document.createElement("script"); sc.src = API + "/s5audio.js"; sc.onload = ok; sc.onerror = fail; document.head.appendChild(sc); });
  }
  pop.addEventListener("input", async e => {
    if (e.target.dataset.sim !== "vol") return;
    setPref("s5vol", e.target.value);
    if (inShell) parent.postMessage({ s5: "vol", v: e.target.value }, "*");
  });
  pop.addEventListener("click", async e => {
    const b = e.target.closest("button[data-sim]");
    if (!b) return;
    if (b.dataset.sim === "x") { pop.classList.remove("open"); return; }
    if (b.dataset.confirm && !confirm("Switch to the simulation? The lights, projection and visuals follow it instead of the decks, until you go back.")) return;
    if (b.dataset.sim === "sound") { setSound(!(inShell && sound.playing)); popRender(); return; }
    b.disabled = true; b.textContent = b.dataset.sim === "on" ? "Starting…" : "Stopping…";
    try {
      const r = await fetch(API + "/api/sim", { method: "POST", credentials: "include", headers: { "Content-Type": "text/plain" },
                                                body: JSON.stringify({ on: b.dataset.sim === "on" }) });
      if (r.ok) {                                   // pages reconnect to the new source
        if (inShell && b.dataset.sim === "off") parent.postMessage({ s5: "leave", url: location.href }, "*");   // no sim: out of the player
        else location.reload();
        return;
      }
      const d = await r.json().catch(() => ({}));
      if (r.status !== 401) alert(d.error || "Couldn't switch simulation.");
    } catch (e2) { /* brain unreachable */ }
    popRender();
    sysPoll();
  });

  addEventListener("keydown", e => { if (e.key === "Escape" && sysEl.classList.contains("open")) sysOpen(false); });
  window.S5SYS = { open: () => sysOpen(true), close: () => sysOpen(false) };
  sysOpen(false); sysPoll();
})();
