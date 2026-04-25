/* qg dashboard frontend — vanilla JS, polls /api/* every 5s. */

const REFRESH_MS = 5000;
const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- formatting
const fmt = {
  int: (n) => (n == null ? "—" : n.toLocaleString("en-US")),
  short: (n) => {
    if (n == null) return "—";
    if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
    if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, "") + "k";
    return n.toString();
  },
  ts: (s) => (s ? s.replace(/^\d{4}-/, "").replace(":00$", "") : "—"),
  shortSid: (sid) => (sid ? sid.slice(0, 12) : "—"),
};

// ---------------------------------------------------------------- API calls
async function api(path) {
  const r = await fetch(path, { cache: "no-store" });
  if (!r.ok) throw new Error(`${path}: ${r.status}`);
  return r.json();
}

// ---------------------------------------------------------------- renders
function renderSummary(s) {
  $("m-time").textContent     = fmt.short(s.minutes_saved);
  $("m-tokens").textContent   = fmt.short(s.tokens_saved);
  $("m-blocks").textContent   = fmt.int(s.blocks_total);
  $("m-warns").textContent    = fmt.int(s.warns_total);
  $("m-events").textContent   = fmt.int(s.events_total);
  $("m-sessions").textContent = fmt.int(s.sessions_total);
  $("m-first").textContent    = fmt.ts(s.first_seen);
}

function renderViolations(rows) {
  const tbody = document.querySelector("#violations tbody");
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="3" class="empty">no violations yet</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map(r => `
    <tr>
      <td><span class="pill hook">${r.hook}</span></td>
      <td>${r.kind}</td>
      <td class="num">${fmt.int(r.count)}</td>
    </tr>`).join("");
}

function renderSessions(rows) {
  const tbody = document.querySelector("#sessions tbody");
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="4" class="empty">no sessions tracked</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map(r => `
    <tr>
      <td>${fmt.shortSid(r.sid)}</td>
      <td class="num">${fmt.int(r.events)}</td>
      <td class="num">${fmt.int(r.blocks)}</td>
      <td>${fmt.ts(r.last)}</td>
    </tr>`).join("");
}

function renderTimeline(buckets) {
  const wrap = $("timeline");
  if (!buckets.length) {
    wrap.innerHTML = `<div class="empty">no activity in the last 24h</div>`;
    return;
  }
  const maxTotal = Math.max(...buckets.map(b => b.total), 1);
  const HEIGHT = 160;
  wrap.innerHTML = buckets.map(b => {
    const blockH = (b.blocks / maxTotal) * HEIGHT;
    const warnH  = (b.warns  / maxTotal) * HEIGHT;
    return `
      <div class="bucket" title="${b.bucket}: ${b.blocks} blocks, ${b.warns} warns">
        ${b.warns ? `<div class="bar warn"  style="height:${warnH}px"></div>` : ""}
        ${b.blocks ? `<div class="bar block" style="height:${blockH}px"></div>` : ""}
      </div>`;
  }).join("");
}

function renderFeed(rows) {
  const ul = $("feed");
  if (!rows.length) {
    ul.innerHTML = `<li class="empty">no events yet</li>`;
    return;
  }
  ul.innerHTML = rows.map(r => `
    <li class="${r.is_block ? "is-block" : r.is_warn ? "is-warn" : ""}">
      <span class="ts">${r.ts.slice(5)}</span>
      <span class="hook">${r.hook}</span>
      <span class="ev">${r.event}${r.file ? ` <span class="dim">${r.file}</span>` : ""}</span>
    </li>`).join("");
}

// ---------------------------------------------------------------- main loop
async function refresh() {
  try {
    const [s, v, t, ses, rec, h] = await Promise.all([
      api("/api/summary"),
      api("/api/violations"),
      api("/api/timeline"),
      api("/api/sessions"),
      api("/api/recent"),
      api("/api/health"),
    ]);
    renderSummary(s);
    renderViolations(v);
    renderTimeline(t);
    renderSessions(ses);
    renderFeed(rec);

    $("log-path").textContent = h.log;
    $("health-dot").className = "dot ok";
    $("health-text").textContent = "live";
    $("last-update").textContent = "updated " + new Date().toTimeString().slice(0, 8);
  } catch (e) {
    $("health-dot").className = "dot fail";
    $("health-text").textContent = "disconnected";
    console.error(e);
  }
}

refresh();
setInterval(refresh, REFRESH_MS);
