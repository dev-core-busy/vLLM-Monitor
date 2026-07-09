#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vllm_dashboard.sh – Web-Dashboard für die gesammelten vLLM-Metriken
===================================================================
Liest die von vllm_collector.sh gefüllte SQLite-DB und stellt die Werte
je Modell über die Zeit grafisch dar (Chart.js). Berechnet aus den
kumulativen Countern die Raten (Tokens/s, Requests/s), aus den Histogrammen
die Durchschnitts-Latenzen und die Prefix-Cache-Hit-Rate.

Bedienung:
  python3 vllm_dashboard.sh                 – Server auf http://127.0.0.1:8899
  python3 vllm_dashboard.sh 8080            – anderer Port (nur lokal)
  python3 vllm_dashboard.sh 8899 0.0.0.0    – im Netzwerk erreichbar (alle Interfaces)
  Alternativ per Umgebungsvariable: VLLM_DASH_BIND=0.0.0.0

  Hinweis: Das Dashboard hat KEINE Authentifizierung. Bei Bindung an 0.0.0.0
  ist es für jeden im Netz sichtbar (nur lesende Metriken). Ggf. per Firewall
  auf vertrauenswürdige Quellen einschränken.

Danach im Browser öffnen. Auto-Refresh alle 15 s.
Nur Python-Standardbibliothek (http.server, sqlite3) – Chart.js via CDN.
"""

import os
import sys
import json
import math
import time
import html
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

__version__ = "0.8.1"

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vllm_metrics.db")
DEFAULT_PORT = 8899

# Untertitel in der Kopfzeile (z.B. Host/Standort); leer = nur "vLLM Monitor"
LABEL = os.environ.get("VLLM_LABEL", "")

# Counter-Spalten -> abgeleitete Raten-Felder (Δwert / Δt)
RATES = {
    "generation_tokens_total": "gen_tps",
    "prompt_tokens_total":     "prompt_tps",
    "requests_success_total":  "req_ps",
}
# Histogramm (sum,count) -> Durchschnitts-Feld (Sekunden), optional Skalierung
AVG_LAT = {
    "ttft":  ("ttft_sum", "ttft_count", "ttft_ms", 1000.0),
    "e2e":   ("e2e_sum",  "e2e_count",  "e2e_s",   1.0),
    "itl":   ("itl_sum",  "itl_count",  "itl_ms",  1000.0),
}


# ---------------------------------------------------------------------------
# Datenaufbereitung
# ---------------------------------------------------------------------------

def _clean(v):
    """None / NaN / Inf -> None (sonst wird das JSON ungültig)."""
    if v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _sanitize(p):
    return {k: (v if k == "t" else _clean(v)) for k, v in p.items()}


def build_series(range_s):
    if not os.path.exists(DB_PATH):
        return {"error": "Keine Datenbank – läuft der Collector?", "models": {}}

    now = int(time.time())
    since = now - range_s
    # Downsampling: pro Reihe ~800 Zielpunkte -> Bucket-Breite in Sekunden
    bucket = max(1, range_s // 800)

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    # Je Zeit-Bucket und Modell den JÜNGSTEN Datenpunkt (bewahrt Counter-
    # Monotonie, damit die Raten korrekt bleiben).
    in_window = conn.execute("""
        SELECT s.* FROM samples s
        JOIN (SELECT model, MAX(ts) AS mts
                FROM samples WHERE ts >= ?
               GROUP BY model, ts / ?) g
          ON s.model = g.model AND s.ts = g.mts
        ORDER BY s.model, s.ts
    """, (since, bucket)).fetchall()
    # Ankerpunkt je Modell direkt VOR dem Fenster – nur zur Delta-Berechnung
    # des ersten sichtbaren Punktes (nicht angezeigt).
    anchors = conn.execute("""
        SELECT s.* FROM samples s
        JOIN (SELECT model, MAX(ts) AS mts
                FROM samples WHERE ts < ? GROUP BY model) a
          ON s.model = a.model AND s.ts = a.mts
    """, (since,)).fetchall()
    conn.close()

    anchor_by_model = {r["model"]: r for r in anchors}
    models = {}
    for r in in_window:
        models.setdefault(r["model"], []).append(r)

    out = {}
    for model, pts in models.items():
        series = []
        prev = anchor_by_model.get(model)   # Seed: Punkt vor dem Fenster
        for r in pts:
            p = {
                "t": r["ts"] * 1000,
                "running": r["requests_running"],
                "waiting": r["requests_waiting"],
                "kv": (_clean(r["kv_cache_usage"]) or 0.0) * 100.0,   # in %
            }
            if prev is not None:
                dt = r["ts"] - prev["ts"]
                if dt > 0:
                    # Raten aus Countern (Counter-Resets -> None)
                    for col, field in RATES.items():
                        d = (r[col] or 0) - (prev[col] or 0)
                        p[field] = round(d / dt, 3) if d >= 0 else None
                    # Cache-Hit-Rate über das Intervall
                    dq = (r["prefix_queries_total"] or 0) - (prev["prefix_queries_total"] or 0)
                    dh = (r["prefix_hits_total"] or 0) - (prev["prefix_hits_total"] or 0)
                    p["hit_rate"] = round(100.0 * dh / dq, 2) if dq > 0 else None
                    # Durchschnitts-Latenzen aus Δsum/Δcount
                    for _k, (scol, ccol, field, scale) in AVG_LAT.items():
                        dc = (r[ccol] or 0) - (prev[ccol] or 0)
                        ds = (r[scol] or 0) - (prev[scol] or 0)
                        p[field] = round(scale * ds / dc, 2) if dc > 0 and ds >= 0 else None
            series.append(_sanitize(p))
            prev = r
        out[model] = series

    return {"now": now * 1000, "range": range_s, "models": out}


# ---------------------------------------------------------------------------
# HTTP-Handler
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # keine Zugriffs-Logs

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/series":
            qs = parse_qs(parsed.query)
            try:
                range_s = int(qs.get("range", ["3600"])[0])
            except ValueError:
                range_s = 3600
            range_s = max(60, min(range_s, 30 * 86400))
            body = json.dumps(build_series(range_s)).encode("utf-8")
            self._send(200, "application/json", body)
        elif parsed.path in ("/", "/index.html"):
            sub = ("– " + html.escape(LABEL)) if LABEL else ""
            page = PAGE.replace("__SUBTITLE__", sub).replace("__VERSION__", __version__)
            self._send(200, "text/html; charset=utf-8", page.encode("utf-8"))
        else:
            self._send(404, "text/plain", b"not found")

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ---------------------------------------------------------------------------
# Frontend (HTML + Chart.js)
# ---------------------------------------------------------------------------

PAGE = r"""<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>vLLM Monitor</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  :root { color-scheme: dark; }
  body { font-family: system-ui, sans-serif; margin: 0; background:#0f1419; color:#e6e6e6; }
  header { padding: 14px 20px; background:#161b22; border-bottom:1px solid #30363d;
           display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
  h1 { font-size: 18px; margin:0; font-weight:600; }
  select, button { background:#21262d; color:#e6e6e6; border:1px solid #30363d;
                   border-radius:6px; padding:6px 10px; font-size:13px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(440px,1fr)); gap:16px; padding:16px; }
  .card { background:#161b22; border:1px solid #30363d; border-radius:10px; padding:12px 14px; }
  .card h2 { font-size:13px; margin:0 0 8px; font-weight:600; color:#8b949e; text-transform:uppercase; letter-spacing:.04em; }
  .muted { color:#8b949e; font-size:12px; }
  #status { font-size:12px; }
  #countdown { margin-left:auto; font-size:12px; font-variant-numeric:tabular-nums;
               color:#58a6ff; min-width:150px; text-align:right; }
  #countdown.now { color:#3fb950; }
  #countdown.paused { color:#8b949e; }
  canvas { max-height:260px; }
</style>
</head>
<body>
<header>
  <h1>vLLM Monitor <span class="muted">__SUBTITLE__</span></h1>
  <span class="muted" style="font-size:11px">v__VERSION__</span>
  <label class="muted">Zeitraum
    <select id="range">
      <option value="900">15 min</option>
      <option value="3600" selected>1 h</option>
      <option value="21600">6 h</option>
      <option value="86400">24 h</option>
      <option value="604800">7 Tage</option>
    </select>
  </label>
  <label class="muted"><input type="checkbox" id="auto" checked> Auto-Refresh (15s)</label>
  <button id="reload">Aktualisieren</button>
  <span id="status" class="muted"></span>
  <span id="countdown"></span>
</header>

<div class="grid">
  <div class="card"><h2>KV-Cache-Auslastung (%)</h2><canvas id="kv"></canvas></div>
  <div class="card"><h2>Aktive / wartende Requests</h2><canvas id="req"></canvas></div>
  <div class="card"><h2>Generierung (Tokens/s)</h2><canvas id="gen"></canvas></div>
  <div class="card"><h2>Prompt-Durchsatz (Tokens/s)</h2><canvas id="prompt"></canvas></div>
  <div class="card"><h2>Time-to-First-Token Ø (ms)</h2><canvas id="ttft"></canvas></div>
  <div class="card"><h2>E2E-Latenz Ø (s)</h2><canvas id="e2e"></canvas></div>
  <div class="card"><h2>Inter-Token-Latenz Ø (ms)</h2><canvas id="itl"></canvas></div>
  <div class="card"><h2>Prefix-Cache-Hit-Rate (%)</h2><canvas id="hit"></canvas></div>
</div>

<script>
const COLORS = ["#58a6ff","#f778ba","#3fb950","#d29922","#a371f7","#ff7b72"];
const charts = {};
const timeFmt = t => new Date(t).toLocaleTimeString("de-DE",{hour:"2-digit",minute:"2-digit"});

function mkChart(id, yLabel, opts={}) {
  const ctx = document.getElementById(id);
  charts[id] = new Chart(ctx, {
    type: "line",
    data: { datasets: [] },
    options: {
      animation:false, responsive:true, maintainAspectRatio:false,
      interaction:{mode:"nearest",intersect:false},
      scales:{
        x:{type:"linear",ticks:{callback:v=>timeFmt(v),maxRotation:0,color:"#8b949e"},grid:{color:"#21262d"}},
        y:{beginAtZero:true,title:{display:!!yLabel,text:yLabel,color:"#8b949e"},
           ticks:{color:"#8b949e"},grid:{color:"#21262d"}, ...(opts.y||{})}
      },
      plugins:{legend:{labels:{color:"#e6e6e6",boxWidth:12,font:{size:11}}}}
    }
  });
}

function shortModel(m){ return m.split("/").pop(); }

function datasets(models, fields) {
  // fields: [{key, label, dash}] – erzeugt pro Modell (und Feld) eine Linie
  const names = Object.keys(models).sort();
  const ds = [];
  names.forEach((name, mi) => {
    const color = COLORS[mi % COLORS.length];
    fields.forEach((f, fi) => {
      ds.push({
        label: shortModel(name) + (f.label ? " · " + f.label : ""),
        data: models[name].map(p => ({x:p.t, y:p[f.key]})).filter(p=>p.y!==null&&p.y!==undefined),
        borderColor: color, backgroundColor: color,
        borderDash: f.dash || [], borderWidth: 1.8, pointRadius: 0, tension: 0.25, spanGaps: true
      });
    });
  });
  return ds;
}

async function refresh() {
  const range = document.getElementById("range").value;
  const st = document.getElementById("status");
  try {
    const r = await fetch("/api/series?range=" + range);
    const j = await r.json();
    if (j.error) { st.textContent = j.error; return; }
    const m = j.models;
    const n = Object.values(m).reduce((a,s)=>a+s.length,0);
    charts.kv.data.datasets     = datasets(m,[{key:"kv"}]);
    charts.req.data.datasets    = datasets(m,[{key:"running",label:"aktiv"},{key:"waiting",label:"wartend",dash:[4,3]}]);
    charts.gen.data.datasets    = datasets(m,[{key:"gen_tps"}]);
    charts.prompt.data.datasets = datasets(m,[{key:"prompt_tps"}]);
    charts.ttft.data.datasets   = datasets(m,[{key:"ttft_ms"}]);
    charts.e2e.data.datasets    = datasets(m,[{key:"e2e_s"}]);
    charts.itl.data.datasets    = datasets(m,[{key:"itl_ms"}]);
    charts.hit.data.datasets    = datasets(m,[{key:"hit_rate"}]);
    Object.values(charts).forEach(c=>c.update());
    st.textContent = "Stand " + new Date(j.now).toLocaleTimeString("de-DE") + " · " + n + " Punkte";
  } catch(e) {
    st.textContent = "Fehler: " + e;
  }
}

["kv","req","gen","prompt","ttft","e2e","itl","hit"].forEach(id=>mkChart(id));

// --- Countdown bis zur nächsten Aktualisierung ---
const REFRESH = 15;               // Sekunden zwischen Auto-Refreshes
let remaining = REFRESH;
const cd = document.getElementById("countdown");

function resetCountdown() { remaining = REFRESH; }

function renderCountdown(text, cls) {
  cd.className = cls || "";
  cd.textContent = text;
}

function tick() {
  const auto = document.getElementById("auto").checked;
  if (!auto) { renderCountdown("Auto-Refresh aus", "paused"); return; }
  remaining -= 1;
  if (remaining <= 0) {
    renderCountdown("↻ 0 s – aktualisiert jetzt", "now");
    refresh().finally(resetCountdown);
  } else {
    renderCountdown("↻ nächste Aktualisierung in " + remaining + " s");
  }
}

document.getElementById("reload").onclick = () => { refresh(); resetCountdown(); };
document.getElementById("range").onchange = () => { refresh(); resetCountdown(); };
setInterval(tick, 1000);
refresh();
</script>
</body>
</html>
"""


def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    # Bind-Adresse: argv[2] > Umgebungsvariable > localhost
    bind = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("VLLM_DASH_BIND", "127.0.0.1")
    srv = ThreadingHTTPServer((bind, port), Handler)
    shown = bind if bind not in ("0.0.0.0", "") else "<diese-IP>"
    print("vLLM-Dashboard läuft:  http://%s:%d  (Bind %s)" % (shown, port, bind))
    if bind in ("0.0.0.0", ""):
        print("  [!] Ohne Auth im Netzwerk erreichbar – ggf. per Firewall einschränken.")
    print("DB: %s   (Strg+C zum Beenden)" % DB_PATH)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nDashboard beendet.")


if __name__ == "__main__":
    main()
