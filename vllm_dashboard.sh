#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vllm_dashboard.sh – Web-Dashboard für die gesammelten vLLM-Metriken
===================================================================
Liest die von vllm_collector.sh gefüllte SQLite-DB und stellt die Werte je
Modell/Instanz über die Zeit grafisch dar (Chart.js). Berechnet Raten,
Perzentile (aus Histogramm-Buckets), Health und KV-Kapazität.

Endpunkte:
  /                    – Dashboard (HTML)
  /api/series?range=S  – Zeitreihen (JSON)
  /api/config          – Instanz-Konfiguration + Health (JSON)
  /api/stream?range=S  – Server-Sent-Events-Push (Live)

Bedienung:
  python3 vllm_dashboard.sh                 – http://127.0.0.1:8899
  python3 vllm_dashboard.sh 8899 0.0.0.0    – im Netzwerk erreichbar
  VLLM_LABEL=... setzt den Untertitel.
  VLLM_TLS_CERT=cert.pem VLLM_TLS_KEY=key.pem ...  – aktiviert HTTPS.

Nur Python-Standardbibliothek – Chart.js/Zoom-Plugin via CDN.
"""

import os
import sys
import ssl
import json
import math
import time
import html
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

__version__ = "0.11.1"

DB_PATH = os.environ.get("VLLM_DB") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "vllm_metrics.db")
DEFAULT_PORT = 8899
LABEL = os.environ.get("VLLM_LABEL", "")
CERT_PATH = None            # wird in main() gesetzt, wenn TLS aktiv ist
PUSH_INTERVAL = 5           # SSE-Push-Takt (Sekunden)
STALE_AFTER = 90            # Instanz gilt als offline, wenn älter (Sekunden)

# Counter-Spalten -> Raten-Feld (Δwert / Δt)
RATES = {
    "generation_tokens_total": "gen_tps",
    "prompt_tokens_total":     "prompt_tps",
    "requests_success_total":  "req_ps",
    "preemptions_total":       "preempt_ps",
    "req_stop":                "stop_ps",
    "req_error":               "error_ps",
    "req_abort":               "abort_ps",
    "req_length":              "length_ps",
}
# Gauge-Spalten (Momentanwerte) -> Feld
GAUGES = {
    "requests_running": "running",
    "requests_waiting": "waiting",
    "waiting_capacity": "waiting_capacity",
    "waiting_deferred": "waiting_deferred",
    "preemptions_total": "preemptions",
    "vram_bytes": "vram_bytes",
    "gpu_util": "gpu_util",
    "gpu_mem_util": "gpu_mem_util",
    "gpu_temp": "gpu_temp",
    "gpu_power": "gpu_power",
    "vram_total_mb": "vram_total_mb",
}
# Histogramm-Bucket-Spalte -> (Feld-Präfix, Skalierung auf Anzeigeeinheit)
HISTOS = {
    "ttft_buckets": ("ttft", 1000.0),   # -> ms
    "e2e_buckets":  ("e2e", 1.0),        # -> s
    "itl_buckets":  ("itl", 1000.0),     # -> ms
}
PCTS = {"p50": 0.50, "p95": 0.95, "p99": 0.99}


# ---------------------------------------------------------------------------
# Hilfen
# ---------------------------------------------------------------------------

def _clean(v):
    if v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _sanitize(p):
    return {k: (v if k in ("t", "reset") else _clean(v)) for k, v in p.items()}


def _percentile(delta, p):
    """delta: {le: kumulative Anzahl im Intervall}. Prometheus-Quantil."""
    if not delta:
        return None
    items = []
    for le, c in delta.items():
        v = math.inf if le in ("+Inf", "Inf", "inf") else float(le)
        items.append((v, c))
    items.sort()
    total = items[-1][1]
    if total <= 0:
        return None
    rank = p * total
    prev_v, prev_c = 0.0, 0.0
    for v, c in items:
        if c >= rank:
            if math.isinf(v):
                return prev_v
            if c == prev_c:
                return v
            return prev_v + (v - prev_v) * (rank - prev_c) / (c - prev_c)
        prev_v, prev_c = v, c
    return items[-1][0]


def _bucket_delta(cur_json, prev_json):
    try:
        cur = json.loads(cur_json) if cur_json else None
        prev = json.loads(prev_json) if prev_json else {}
    except (ValueError, TypeError):
        return None
    if not cur:
        return None
    out = {}
    for le, c in cur.items():
        d = c - prev.get(le, 0.0)
        if d < 0:
            return None   # Counter-Reset -> Intervall überspringen
        out[le] = d
    return out


def _connect():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


# ---------------------------------------------------------------------------
# Zeitreihen
# ---------------------------------------------------------------------------

def build_series(range_s):
    if not os.path.exists(DB_PATH):
        return {"error": "Keine Datenbank – läuft der Collector?", "models": {}}

    now = int(time.time())
    since = now - range_s
    bucket = max(1, range_s // 800)

    conn = _connect()
    in_window = conn.execute("""
        SELECT s.* FROM samples s
        JOIN (SELECT model, MAX(ts) AS mts FROM samples
               WHERE ts >= ? GROUP BY model, ts / ?) g
          ON s.model = g.model AND s.ts = g.mts
        ORDER BY s.model, s.ts
    """, (since, bucket)).fetchall()
    anchors = conn.execute("""
        SELECT s.* FROM samples s
        JOIN (SELECT model, MAX(ts) AS mts FROM samples
               WHERE ts < ? GROUP BY model) a
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
        prev = anchor_by_model.get(model)
        for r in pts:
            p = {
                "t": r["ts"] * 1000,
                "kv": (_clean(r["kv_cache_usage"]) or 0.0) * 100.0,
            }
            for col, field in GAUGES.items():
                p[field] = r[col]
            if prev is not None:
                dt = r["ts"] - prev["ts"]
                if dt > 0:
                    for col, field in RATES.items():
                        d = (r[col] or 0) - (prev[col] or 0)
                        p[field] = round(d / dt, 3) if d >= 0 else None
                    dq = (r["prefix_queries_total"] or 0) - (prev["prefix_queries_total"] or 0)
                    dh = (r["prefix_hits_total"] or 0) - (prev["prefix_hits_total"] or 0)
                    p["hit_rate"] = round(100.0 * dh / dq, 2) if dq > 0 else None
                    # Perzentile aus Histogramm-Bucket-Deltas
                    for bcol, (pref, scale) in HISTOS.items():
                        delta = _bucket_delta(r[bcol], prev[bcol])
                        for pname, pv in PCTS.items():
                            q = _percentile(delta, pv) if delta else None
                            p["%s_%s" % (pref, pname)] = round(q * scale, 2) if q is not None else None
                    # Counter-Reset-Markierung
                    if (r["prompt_tokens_total"] or 0) < (prev["prompt_tokens_total"] or 0):
                        p["reset"] = True
            series.append(_sanitize(p))
            prev = r
        out[model] = series

    return {"now": now * 1000, "range": range_s, "bucket": bucket, "models": out}


def build_config():
    if not os.path.exists(DB_PATH):
        return {"instances": []}
    now = int(time.time())
    conn = _connect()
    inst = []
    for c in conn.execute("SELECT * FROM config ORDER BY host, port"):
        last = conn.execute(
            "SELECT MAX(ts) FROM samples WHERE host=? AND port=? AND model=?",
            (c["host"], c["port"], c["model"])).fetchone()[0]
        age = (now - last) if last else None
        online = bool(c["up"]) and age is not None and age <= STALE_AFTER
        cap = (c["num_gpu_blocks"] or 0) * (c["block_size"] or 0)
        kind = c["kind"] if "kind" in c.keys() and c["kind"] else "vllm"
        # aktuelle VRAM-Belegung (falls vorhanden, z.B. Ollama)
        vram = conn.execute(
            "SELECT vram_bytes FROM samples WHERE host=? AND port=? AND model=? "
            "ORDER BY ts DESC LIMIT 1", (c["host"], c["port"], c["model"])).fetchone()
        inst.append({
            "host": c["host"], "port": c["port"], "model": c["model"],
            "kind": kind, "online": online, "age": age,
            "num_gpu_blocks": c["num_gpu_blocks"], "block_size": c["block_size"],
            "capacity_tokens": cap, "max_model_len": c["max_model_len"],
            "gpu_memory_utilization": c["gpu_memory_utilization"],
            "kv_cache_dtype": c["kv_cache_dtype"],
            "enable_prefix_caching": c["enable_prefix_caching"],
            "version": c["version"],
            "vram_bytes": (vram[0] if vram else None),
        })
    conn.close()
    return {"now": now * 1000, "instances": inst}


# ---------------------------------------------------------------------------
# HTTP-Handler
# ---------------------------------------------------------------------------

def _range_from(qs):
    try:
        r = int(qs.get("range", ["3600"])[0])
    except ValueError:
        r = 3600
    return max(60, min(r, 30 * 86400))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        if parsed.path == "/api/series":
            self._json(build_series(_range_from(qs)))
        elif parsed.path == "/api/config":
            self._json(build_config())
        elif parsed.path == "/api/stream":
            self._stream(_range_from(qs))
        elif parsed.path == "/api/cert":
            self._send_cert()
        elif parsed.path in ("/", "/index.html"):
            sub = ("– " + html.escape(LABEL)) if LABEL else ""
            page = (PAGE.replace("__SUBTITLE__", sub)
                        .replace("__VERSION__", __version__)
                        .replace("__TLSAVAIL__", "1" if CERT_PATH else "0"))
            self._send(200, "text/html; charset=utf-8", page.encode("utf-8"))
        else:
            self._send(404, "text/plain", b"not found")

    def _send_cert(self):
        if CERT_PATH and os.path.exists(CERT_PATH):
            try:
                with open(CERT_PATH, "rb") as f:
                    data = f.read()
            except OSError:
                self._send(500, "text/plain", b"cert read error")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", "attachment; filename=vllm-monitor.crt")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self._send(404, "text/plain; charset=utf-8",
                       "Kein TLS-Zertifikat konfiguriert (HTTP-Modus).".encode("utf-8"))

    def _json(self, obj):
        self._send(200, "application/json", json.dumps(obj).encode("utf-8"))

    def _stream(self, range_s):
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            while True:
                payload = json.dumps(build_series(range_s))
                self.wfile.write(("data: %s\n\n" % payload).encode("utf-8"))
                self.wfile.flush()
                time.sleep(PUSH_INTERVAL)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


# ---------------------------------------------------------------------------
# Frontend
# ---------------------------------------------------------------------------

PAGE = r"""<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>vLLM Monitor</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2.0.1/dist/chartjs-plugin-zoom.min.js"></script>
<style>
  :root{
    --bg:#0f1419; --panel:#161b22; --border:#30363d; --grid:#21262d;
    --fg:#e6e6e6; --muted:#8b949e; --accent:#58a6ff;
    --ok:#3fb950; --warn:#d29922; --bad:#f85149;
    --tile-min:430px; --card-h:240px;
  }
  [data-theme="light"]{
    --bg:#f6f8fa; --panel:#ffffff; --border:#d0d7de; --grid:#eaeef2;
    --fg:#1f2328; --muted:#57606a; --accent:#0969da;
  }
  [data-density="kompakt"]{--tile-min:330px; --card-h:185px;}
  [data-density="dicht"]{--tile-min:235px; --card-h:135px;}
  [data-density="sehrdicht"]{--tile-min:190px; --card-h:100px;}
  *{box-sizing:border-box}
  body{font-family:system-ui,sans-serif;margin:0;background:var(--bg);color:var(--fg);}
  header{padding:12px 18px;background:var(--panel);border-bottom:1px solid var(--border);
         display:flex;align-items:center;gap:12px;flex-wrap:wrap;position:sticky;top:0;z-index:10;}
  h1{font-size:17px;margin:0;font-weight:600;}
  select,button{background:var(--panel);color:var(--fg);border:1px solid var(--border);
                border-radius:6px;padding:5px 9px;font-size:12px;cursor:pointer;}
  button:hover{border-color:var(--accent);}
  label.ctl{color:var(--muted);font-size:12px;display:flex;align-items:center;gap:5px;}
  .menuwrap{position:relative;display:inline-flex;}
  .menu{position:absolute;top:125%;right:0;background:var(--panel);border:1px solid var(--border);
    border-radius:8px;padding:8px;display:none;flex-direction:column;gap:6px;z-index:30;min-width:190px;
    box-shadow:0 8px 24px rgba(0,0,0,.45);}
  .menu.open{display:flex;}
  .menu .mrow{display:flex;justify-content:space-between;align-items:center;gap:8px;color:var(--muted);font-size:12px;}
  .menu button{width:100%;text-align:left;}
  .densgroup{display:inline-flex;gap:3px;align-items:center;}
  .dbtn{padding:3px 5px;line-height:0;}
  .dbtn .dg{width:22px;height:17px;display:block;fill:var(--muted);}
  .dbtn:hover .dg{fill:var(--fg);}
  .dbtn.active{border-color:var(--accent);}
  .dbtn.active .dg{fill:var(--accent);}
  #countdown{margin-left:auto;font-size:12px;font-variant-numeric:tabular-nums;color:var(--accent);
             min-width:150px;text-align:right;}
  #countdown.now{color:var(--ok);} #countdown.paused{color:var(--muted);}
  .kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px;padding:14px 16px 0;}
  .kpi{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px 14px;}
  .kpi.alert{border-color:var(--bad);box-shadow:0 0 0 1px var(--bad) inset;}
  .kpi h3{margin:0 0 8px;font-size:13px;display:flex;align-items:center;gap:8px;}
  .dot{width:9px;height:9px;border-radius:50%;display:inline-block;}
  .dot.on{background:var(--ok);} .dot.off{background:var(--bad);}
  .kpi .row{display:flex;flex-wrap:wrap;gap:12px;}
  .metric{font-size:12px;color:var(--muted);} .metric b{display:block;font-size:17px;color:var(--fg);}
  .metric.warn b{color:var(--warn);} .metric.bad b{color:var(--bad);}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(var(--tile-min),1fr));gap:14px;padding:14px 16px;}
  .card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:10px 12px;position:relative;}
  .card h2{font-size:12px;margin:0 0 6px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;}
  .cardbtns{position:absolute;top:5px;right:7px;display:flex;gap:3px;z-index:6;}
  .cbtn{background:var(--panel);border:1px solid var(--border);color:var(--muted);border-radius:5px;
        width:22px;height:20px;font-size:13px;line-height:1;padding:0;cursor:pointer;}
  .cbtn:hover{color:var(--fg);border-color:var(--accent);}
  .cbtn.close:hover{color:var(--bad);border-color:var(--bad);}
  .card.maximized{position:fixed;inset:14px;z-index:2000;margin:0;overflow:auto;
    box-shadow:0 0 0 100vmax rgba(0,0,0,.55);}
  .card.maximized canvas{max-height:calc(100vh - 90px);}
  .hidden-card{display:none !important;}
  #instcard.collapsed #insttable{display:none;}
  canvas{max-height:var(--card-h);}
  .card h2.handle,.kpi h3.handle{cursor:grab;user-select:none;touch-action:none;
    margin:-10px -12px 6px;padding:6px 12px;border-radius:10px 10px 0 0;background:rgba(127,127,127,.06);}
  .kpi h3.handle{margin:-12px -14px 8px;padding:8px 14px;}
  .card h2.handle:hover,.kpi h3.handle:hover{background:rgba(88,166,255,.12);}
  .card h2.handle:active,.kpi h3.handle:active{cursor:grabbing;}
  .card h2.handle::before,.kpi h3.handle::before{content:"⠿ ";color:var(--muted);opacity:.7;}
  .cpick{margin-left:auto;width:20px;height:20px;padding:0;border:1px solid var(--border);
    border-radius:5px;background:none;cursor:pointer;flex:0 0 auto;}
  .cpick::-webkit-color-swatch-wrapper{padding:0;}
  .cpick::-webkit-color-swatch{border:none;border-radius:4px;}
  .cpick::-moz-color-swatch{border:none;border-radius:4px;}
  .dragging{opacity:.97;box-shadow:0 12px 34px rgba(0,0,0,.55);outline:2px solid var(--accent);
    border-radius:10px;transform:scale(1.02);cursor:grabbing;}
  .placeholder-slot{border:2px dashed var(--accent);border-radius:10px;background:rgba(88,166,255,.08);}
  table{width:100%;border-collapse:collapse;font-size:12px;}
  th,td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--grid);}
  th{color:var(--muted);font-weight:600;}
  .placeholder{color:var(--muted);font-size:12px;padding:18px 4px;text-align:center;}
  #status{font-size:11px;color:var(--muted);}
  #legend{display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center;padding:12px 16px 0;}
  .lchip{display:inline-flex;align-items:center;gap:6px;font-size:12px;cursor:pointer;color:var(--fg);user-select:none;}
  .lchip.off{opacity:.4;text-decoration:line-through;}
  .ldot{width:11px;height:11px;border-radius:50%;display:inline-block;flex:0 0 auto;}
  #secbtn.insecure{border-color:var(--bad);color:var(--bad);}
  #secbtn.secure{border-color:var(--ok);color:var(--ok);}
  #secbanner{background:rgba(248,81,73,.14);color:var(--bad);border-bottom:1px solid var(--bad);
    padding:8px 16px;font-size:13px;display:flex;align-items:center;gap:10px;flex-wrap:wrap;}
  #secbanner button{font-size:12px;}
  .modal-ov{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:3000;display:none;
    align-items:flex-start;justify-content:center;padding:40px 14px;overflow:auto;}
  .modal-card{background:var(--panel);border:1px solid var(--border);border-radius:12px;
    max-width:560px;width:100%;padding:20px 22px;color:var(--fg);}
  .modal-card h2{margin:0 0 12px;font-size:18px;}
  .modal-card p{font-size:13px;color:var(--muted);line-height:1.6;}
  .dlbtn{display:inline-flex;align-items:center;gap:8px;background:var(--accent);color:#fff;
    border:none;border-radius:8px;padding:9px 14px;font-size:13px;text-decoration:none;margin:6px 0 14px;cursor:pointer;}
  .tabs{display:flex;gap:4px;margin-bottom:10px;}
  .tab{font-size:12px;}
  .tab.active{border-color:var(--accent);color:var(--accent);}
  .tabc ol{font-size:13px;line-height:1.7;padding-left:18px;margin:0;}
  .tabc pre{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px 12px;
    font-size:12px;overflow-x:auto;}
  .tabc code{background:var(--grid);padding:1px 5px;border-radius:4px;}
  #certstatus{font-size:13px;line-height:1.6;background:var(--bg);border:1px solid var(--border);
    border-radius:8px;padding:10px 12px;margin-bottom:12px;}
</style>
</head>
<body>
<header>
  <h1>vLLM Monitor <span style="color:var(--muted)">__SUBTITLE__</span></h1>
  <span style="font-size:11px;color:var(--muted)">v__VERSION__</span>
  <label class="ctl" title="Zeitfenster, das in allen Diagrammen dargestellt wird. Bei großen Fenstern werden die Daten automatisch verdichtet (Downsampling).">Zeitraum
    <select id="range" title="Zeitfenster der Diagramme (15 min bis 7 Tage)">
      <option value="900">15 min</option>
      <option value="3600" selected>1 h</option>
      <option value="21600">6 h</option>
      <option value="86400">24 h</option>
      <option value="604800">7 Tage</option>
    </select>
  </label>
  <span class="densgroup" title="Kacheldichte – mehr Punkte = mehr, kleinere Kacheln">
    <button class="dbtn" data-d="sehrdicht" title="Sehr klein, sehr viele Kacheln (6×5)"><svg class="dg" viewBox="0 0 26 20"><circle cx="3.5" cy="2.8" r="1.05"/><circle cx="7.3" cy="2.8" r="1.05"/><circle cx="11.1" cy="2.8" r="1.05"/><circle cx="14.9" cy="2.8" r="1.05"/><circle cx="18.7" cy="2.8" r="1.05"/><circle cx="22.5" cy="2.8" r="1.05"/><circle cx="3.5" cy="6.4" r="1.05"/><circle cx="7.3" cy="6.4" r="1.05"/><circle cx="11.1" cy="6.4" r="1.05"/><circle cx="14.9" cy="6.4" r="1.05"/><circle cx="18.7" cy="6.4" r="1.05"/><circle cx="22.5" cy="6.4" r="1.05"/><circle cx="3.5" cy="10.0" r="1.05"/><circle cx="7.3" cy="10.0" r="1.05"/><circle cx="11.1" cy="10.0" r="1.05"/><circle cx="14.9" cy="10.0" r="1.05"/><circle cx="18.7" cy="10.0" r="1.05"/><circle cx="22.5" cy="10.0" r="1.05"/><circle cx="3.5" cy="13.6" r="1.05"/><circle cx="7.3" cy="13.6" r="1.05"/><circle cx="11.1" cy="13.6" r="1.05"/><circle cx="14.9" cy="13.6" r="1.05"/><circle cx="18.7" cy="13.6" r="1.05"/><circle cx="22.5" cy="13.6" r="1.05"/><circle cx="3.5" cy="17.2" r="1.05"/><circle cx="7.3" cy="17.2" r="1.05"/><circle cx="11.1" cy="17.2" r="1.05"/><circle cx="14.9" cy="17.2" r="1.05"/><circle cx="18.7" cy="17.2" r="1.05"/><circle cx="22.5" cy="17.2" r="1.05"/></svg></button>
    <button class="dbtn" data-d="dicht" title="Klein, viele Kacheln (5×4)"><svg class="dg" viewBox="0 0 26 20"><circle cx="4.3" cy="4.0" r="1.3"/><circle cx="8.7" cy="4.0" r="1.3"/><circle cx="13.0" cy="4.0" r="1.3"/><circle cx="17.3" cy="4.0" r="1.3"/><circle cx="21.7" cy="4.0" r="1.3"/><circle cx="4.3" cy="8.0" r="1.3"/><circle cx="8.7" cy="8.0" r="1.3"/><circle cx="13.0" cy="8.0" r="1.3"/><circle cx="17.3" cy="8.0" r="1.3"/><circle cx="21.7" cy="8.0" r="1.3"/><circle cx="4.3" cy="12.0" r="1.3"/><circle cx="8.7" cy="12.0" r="1.3"/><circle cx="13.0" cy="12.0" r="1.3"/><circle cx="17.3" cy="12.0" r="1.3"/><circle cx="21.7" cy="12.0" r="1.3"/><circle cx="4.3" cy="16.0" r="1.3"/><circle cx="8.7" cy="16.0" r="1.3"/><circle cx="13.0" cy="16.0" r="1.3"/><circle cx="17.3" cy="16.0" r="1.3"/><circle cx="21.7" cy="16.0" r="1.3"/></svg></button>
    <button class="dbtn" data-d="kompakt" title="Mittel (4×3)"><svg class="dg" viewBox="0 0 26 20"><circle cx="5.2" cy="5.0" r="1.7"/><circle cx="10.4" cy="5.0" r="1.7"/><circle cx="15.6" cy="5.0" r="1.7"/><circle cx="20.8" cy="5.0" r="1.7"/><circle cx="5.2" cy="10.0" r="1.7"/><circle cx="10.4" cy="10.0" r="1.7"/><circle cx="15.6" cy="10.0" r="1.7"/><circle cx="20.8" cy="10.0" r="1.7"/><circle cx="5.2" cy="15.0" r="1.7"/><circle cx="10.4" cy="15.0" r="1.7"/><circle cx="15.6" cy="15.0" r="1.7"/><circle cx="20.8" cy="15.0" r="1.7"/></svg></button>
    <button class="dbtn" data-d="normal" title="Große Kacheln (3×2)"><svg class="dg" viewBox="0 0 26 20"><circle cx="6.5" cy="6.7" r="2.2"/><circle cx="13.0" cy="6.7" r="2.2"/><circle cx="19.5" cy="6.7" r="2.2"/><circle cx="6.5" cy="13.3" r="2.2"/><circle cx="13.0" cy="13.3" r="2.2"/><circle cx="19.5" cy="13.3" r="2.2"/></svg></button>
  </span>
  <label class="ctl" title="Wie sich das Dashboard aktualisiert: Live schiebt Daten per Server-Sent-Events (Push), oder festes Poll-Intervall, oder ganz aus.">Aktualisierung
    <select id="mode" title="Aktualisierungsmodus des Dashboards">
      <option value="live" selected title="Live-Push vom Server (SSE) – niedrigste Verzögerung">Live (SSE)</option>
      <option value="5" title="Alle 5 Sekunden neu abfragen">alle 5 s</option>
      <option value="15" title="Alle 15 Sekunden neu abfragen">alle 15 s</option>
      <option value="60" title="Alle 60 Sekunden neu abfragen">alle 60 s</option>
      <option value="off" title="Keine automatische Aktualisierung – nur per „Neu laden“">Aus</option>
    </select>
  </label>
  <button id="reload" title="Daten und Instanz-Konfiguration sofort neu laden">Neu laden</button>
  <button id="resetzoom" title="Zoom/Verschieben in allen Diagrammen zurücksetzen (Mausrad = Zoom, Ziehen = Verschieben)">Zoom ⟲</button>
  <button id="theme" title="Zwischen hellem und dunklem Design umschalten (wird gespeichert)">◐</button>
  <button id="notif" title="Browser-Benachrichtigungen bei Warnungen (KV-Cache voll, Fehler, Instanz offline) erlauben">🔔</button>
  <button id="secbtn" title="Verbindungssicherheit & Zertifikat">🔒</button>
  <button id="restore" title="Ausgeblendete Kacheln wieder einblenden" style="display:none">Ausgeblendet: 0 ⟲</button>
  <div class="menuwrap">
    <button id="gear" title="Weitere Optionen (Latenz-Perzentil, Export)">⚙</button>
    <div id="gearmenu" class="menu">
      <label class="mrow" title="Latenz-Perzentil für die Panels TTFT/E2E/ITL und die KPI-Karten. P95 = 95 % der Requests sind schneller; P99 zeigt Ausreißer, P50 den Median.">Latenz-Perzentil
        <select id="pct">
          <option value="p50">P50</option>
          <option value="p95" selected>P95</option>
          <option value="p99">P99</option>
        </select>
      </label>
      <button id="export" title="Aktuell angezeigte Zeitreihen als CSV-Datei herunterladen">⬇ Export CSV</button>
      <button id="exportjson" title="Aktuell angezeigte Zeitreihen als JSON-Datei herunterladen">⬇ Export JSON</button>
    </div>
  </div>
  <span id="countdown"></span>
  <span id="status" style="flex-basis:100%;text-align:right"></span>
</header>

<div class="kpis" id="kpis"></div>

<div class="card" id="instcard" style="margin:14px 16px 0">
  <div class="cardbtns"><button class="cbtn" id="insttoggle" title="Ein-/Ausklappen">▾</button></div>
  <h2>Instanzen</h2>
  <table id="insttable"><thead><tr>
    <th>Status</th><th>Typ</th><th>Instanz</th><th>Modell</th><th>Version</th>
    <th>KV-Kap. / VRAM</th><th>max_model_len</th><th>gpu_mem</th><th>Prefix-Cache</th>
  </tr></thead><tbody></tbody></table>
</div>

<div id="legend" title="Farb-Zuordnung der Modelle – Klick blendet ein Modell in allen Diagrammen aus/ein"></div>
<div class="grid" id="charts"></div>

<div id="secbanner" style="display:none">
  <span>⚠️ Unverschlüsselte Verbindung (HTTP) – Browser-Benachrichtigungen sind hier nicht möglich.</span>
  <button id="secbanner-btn">Zertifikat / HTTPS</button>
  <button id="secbanner-x" title="Ausblenden">×</button>
</div>

<div id="certmodal" class="modal-ov">
  <div class="modal-card">
    <h2>🔒 Verbindung & SSL-Zertifikat</h2>
    <div id="certstatus"></div>
    <p>Selbstsigniertes Zertifikat – einmalig als <b>vertrauenswürdig</b> installieren, damit der Browser
       die Verbindung als sicher einstuft (und Benachrichtigungen erlaubt).</p>
    <a id="certdl" href="/api/cert" download="vllm-monitor.crt" class="dlbtn">⬇ Zertifikat herunterladen (vllm-monitor.crt)</a>
    <div class="tabs">
      <button class="tab active" data-tab="win">Windows</button>
      <button class="tab" data-tab="linux">Linux</button>
      <button class="tab" data-tab="browser">Firefox/Browser</button>
    </div>
    <div id="tab-win" class="tabc">
      <ol>
        <li>Zertifikat <code>vllm-monitor.crt</code> herunterladen.</li>
        <li>Doppelklick / Rechtsklick → <b>Zertifikat installieren</b>.</li>
        <li>Speicherort <b>Lokaler Computer</b> (oder Aktueller Benutzer) wählen.</li>
        <li><b>Alle Zertifikate in folgendem Speicher speichern</b> → Durchsuchen →
            <b>Vertrauenswürdige Stammzertifizierungsstellen</b>.</li>
        <li>Fertigstellen und <b>Browser komplett neu starten</b>.</li>
      </ol>
    </div>
    <div id="tab-linux" class="tabc" hidden>
      <ol><li>System-weit als vertrauenswürdige CA hinterlegen:</li></ol>
      <pre>sudo cp vllm-monitor.crt /usr/local/share/ca-certificates/vllm-monitor.crt
sudo update-ca-certificates</pre>
      <p style="margin:6px 0 0">Danach den Browser neu starten. (Chrome/Chromium nutzen den System-Store.)</p>
    </div>
    <div id="tab-browser" class="tabc" hidden>
      <ol>
        <li>Browser-Einstellungen öffnen, nach <b>Zertifikate</b> suchen.</li>
        <li>Reiter <b>Zertifizierungsstellen</b> → <b>Importieren</b>.</li>
        <li>Datei <code>vllm-monitor.crt</code> auswählen.</li>
        <li>Haken bei <b>Dieser CA für die Identifizierung von Websites vertrauen</b> setzen.</li>
        <li>Bestätigen und die Seite neu laden.</li>
      </ol>
    </div>
    <button id="certclose" style="margin-top:14px">Schließen</button>
  </div>
</div>

<script>
const COLORS=["#58a6ff","#f778ba","#3fb950","#d29922","#a371f7","#ff7b72"];
if(window.ChartZoom) Chart.register(window.ChartZoom);

const CHARTS=[
 {id:"kv",title:"KV-Cache-Auslastung (%)",fields:[{k:"kv"}],max:100,threshold:90,
  desc:"Belegung des KV-Caches – des GPU-Speichers für die Kontexte laufender Requests.\n100 % = voll: neue oder lange Anfragen müssen warten oder werden verdrängt.\nDauerhaft hohe Werte deuten auf einen Speicherengpass hin."},
 {id:"kvtok",title:"KV-Belegung (Tokens, rel. zur Kapazität)",fields:[{k:"kv_tokens"}],
  desc:"Belegte KV-Cache-Tokens, absolut statt in Prozent.\nBezugsgröße ist die Kapazität num_gpu_blocks × block_size.\nZeigt, wie viel Kontext gleichzeitig im GPU-Speicher liegt."},
 {id:"vram",title:"VRAM-Belegung (GB)",fields:[{k:"vram_bytes"}],
  desc:"Belegter GPU-Speicher in GB.\nQuelle: DCGM (FB_USED je GPU) bzw. Ollama /api/ps (size_vram).\nBei vLLM-Instanzen nicht verfügbar – dort bleibt das Panel leer."},
 {id:"gpu_util",title:"GPU-Auslastung (%)",fields:[{k:"gpu_util",l:"SM"},{k:"gpu_mem_util",l:"Mem",dash:[4,3]}],max:100,
  desc:"GPU-Hardware-Auslastung (NVIDIA DCGM).\nSM = Rechenwerk-Auslastung, Mem = Speicher-Kopier-Auslastung.\nNur für GPU-Instanzen (DCGM-Exporter)."},
 {id:"gpu_temp",title:"GPU-Temperatur (°C)",fields:[{k:"gpu_temp"}],
  desc:"GPU-Kerntemperatur in °C (NVIDIA DCGM).\nSteigt unter Last; Drosselung droht bei Überhitzung.\nNur für GPU-Instanzen."},
 {id:"gpu_power",title:"GPU-Leistung (W)",fields:[{k:"gpu_power"}],
  desc:"Aktuelle Leistungsaufnahme der GPU in Watt (NVIDIA DCGM).\nIndikator für Auslastung/Energieverbrauch.\nNur für GPU-Instanzen."},
 {id:"req",title:"Requests aktiv / wartend",fields:[{k:"running",l:"aktiv"},{k:"waiting",l:"wartend",dash:[4,3]}],
  desc:"Anzahl der gerade verarbeiteten (aktiv) und in der Warteschlange\nstehenden (wartend) Anfragen dieses Modells.\nWartend > 0 heißt: die Instanz ist an der Kapazitätsgrenze."},
 {id:"waitreason",title:"Wartend nach Grund",fields:[{k:"waiting_capacity",l:"capacity"},{k:"waiting_deferred",l:"deferred",dash:[4,3]}],
  desc:"Warum Requests warten:\n'capacity' = keine Scheduling-/Speicherkapazität (echte Last).\n'deferred' = vorübergehende Beschränkung (z. B. KV-Transfer, LoRA-Budget)."},
 {id:"preempt",title:"Preemptions/s",fields:[{k:"preempt_ps"}],
  desc:"Rate der verdrängten Requests pro Sekunde.\n> 0 = KV-Cache-Druck: laufende Sequenzen werden pausiert und später\nneu berechnet – das kostet zusätzliche Zeit und Durchsatz."},
 {id:"gen",title:"Generierung (Tokens/s)",fields:[{k:"gen_tps"}],
  desc:"Ausgabe-Durchsatz: erzeugte Tokens pro Sekunde über alle Requests.\nKernmaß für die Antwortgeschwindigkeit unter Last.\nSinkt, wenn KV-Cache oder GPU zum Flaschenhals werden."},
 {id:"prompt",title:"Prompt-Durchsatz (Tokens/s)",fields:[{k:"prompt_tps"}],
  desc:"Verarbeitete Eingabe-(Prefill-)Tokens pro Sekunde.\nHoch bei langen Prompts oder vielen neuen Anfragen\n(typisch für RAG und Zusammenfassungen)."},
 {id:"ttft",title:"Time-to-First-Token (ms)",pct:"ttft",
  desc:"Zeit bis zum ersten Antwort-Token (gewähltes Perzentil).\nMaß für die gefühlte Reaktionszeit des Modells.\nSteigt bei Warteschlange oder langen Eingabe-Prompts."},
 {id:"e2e",title:"E2E-Latenz (s)",pct:"e2e",
  desc:"Gesamtdauer eines Requests: von Eingang bis zum letzten Token\n(gewähltes Perzentil). Enthält Warten + Prefill + Generierung.\nWichtigste Nutzer-Kennzahl für die Antwortdauer."},
 {id:"itl",title:"Inter-Token-Latenz (ms)",pct:"itl",
  desc:"Durchschnittlicher Abstand zwischen zwei Ausgabe-Tokens\n(gewähltes Perzentil). Bestimmt, wie flüssig die Antwort 'tippt'.\nHohe Werte = ruckelige/langsame Ausgabe."},
 {id:"finish",title:"Requests nach Ergebnis (/s)",fields:[{k:"stop_ps",l:"stop"},{k:"error_ps",l:"error"},{k:"abort_ps",l:"abort",dash:[4,3]},{k:"length_ps",l:"length",dash:[2,2]}],
  desc:"Abschlussrate nach Grund pro Sekunde:\nstop = normal beendet, length = Längenlimit erreicht,\nabort = abgebrochen, error = Fehler. error/abort > 0 = Probleme."},
 {id:"hit",title:"Prefix-Cache-Hit-Rate (%)",fields:[{k:"hit_rate"}],max:100,
  desc:"Anteil der Prompt-Tokens, die aus dem Prefix-Cache wiederverwendet\nwurden statt neu berechnet zu werden.\nHoch = effizient bei wiederkehrenden Prompt-Anfängen (System-Prompts, RAG)."},
];

let charts={}, lastData=null, lastConfig=null, hoverX=null, resets=[];
const shortModel=m=>m.split("/").pop();
const css=v=>getComputedStyle(document.body).getPropertyValue(v).trim();

// --- Persistenz in Cookies (Layout, ausgeblendete Kacheln, Theme) ---
function setCookie(name,value,days){
  let exp="";
  if(days){const d=new Date();d.setTime(d.getTime()+days*864e5);exp="; expires="+d.toUTCString();}
  document.cookie=name+"="+encodeURIComponent(value)+exp+"; path=/; SameSite=Lax";
}
function getCookie(name){
  const m=document.cookie.match(new RegExp("(?:^|; )"+name.replace(/([.*+?^${}()|[\]\\])/g,"\\$1")+"=([^;]*)"));
  return m?decodeURIComponent(m[1]):null;
}
const store={ get:k=>getCookie(k), set:(k,v)=>setCookie(k,v,365), del:k=>setCookie(k,"",-1) };

// --- Stabile Modell-Farben + gemeinsame Legende (statt Legende je Diagramm) ---
let modelColors={};
let customColors=JSON.parse(store.get("vllm_colors")||"{}");   // vom Nutzer gewählte Farben
const colorFor=m=>customColors[m]||modelColors[m]||COLORS[0];
// Feste Default-Farben je Instanz-Typ (überschreibbar per Farbwähler)
function defaultColorFor(m){
  const s=m.toLowerCase();
  if(s.startsWith("gpu")||s.includes("dcgm"))return "#d29922";                       // GPU = gelb
  if(s.includes("qwen"))return "#58a6ff";                                            // Qwen = blau
  if(s.includes("gemma"))return "#3fb950";                                           // Gemma = grün
  if(s.includes("whisper")||s.includes("stt")||s.includes("faster"))return "#f778ba";// STT = rosa
  return null;
}
function computeColors(models){
  modelColors={}; Object.keys(models).sort().forEach((m,i)=>modelColors[m]=defaultColorFor(m)||COLORS[i%COLORS.length]);
}
function setColor(m,c,rebuild){
  customColors[m]=c; store.set("vllm_colors",JSON.stringify(customColors));
  if(!lastData)return;
  renderLegend(lastData.models);   // Legende + Diagramme live aktualisieren
  CHARTS.forEach(spec=>{charts[spec.id].data.datasets=datasets(lastData.models,spec);charts[spec.id].update();});
  if(rebuild)renderKPIs();         // KPI-Karten nur neu bauen, wenn Picker zu ist (sonst schließt er)
}
const hiddenModels=new Set(JSON.parse(store.get("vllm_hidden_models")||"[]"));
const saveHiddenModels=()=>store.set("vllm_hidden_models",JSON.stringify([...hiddenModels]));
function renderLegend(models){
  const el=document.getElementById("legend"); if(!el)return;
  el.innerHTML="";
  Object.keys(models).sort().forEach(m=>{
    const chip=document.createElement("span");
    chip.className="lchip"+(hiddenModels.has(m)?" off":"");
    chip.innerHTML='<span class="ldot" style="background:'+colorFor(m)+'"></span>'+shortModel(m);
    chip.onclick=()=>{ hiddenModels.has(m)?hiddenModels.delete(m):hiddenModels.add(m); saveHiddenModels(); if(lastData)applySeries(lastData); };
    el.appendChild(chip);
  });
}

// --- Verschiebbare Kacheln (Drag & Drop, Reihenfolge in Cookie) ---
function orderBy(items,saved,idOf){
  if(!saved||!saved.length)return items;
  const map=new Map(items.map(x=>[idOf(x),x]));
  const out=[];
  saved.forEach(id=>{if(map.has(id)){out.push(map.get(id));map.delete(id);}});
  map.forEach(v=>out.push(v));
  return out;
}
function saveOrder(container,key){
  const ids=[...container.children].map(c=>c.dataset.id).filter(Boolean);
  store.set(key,JSON.stringify(ids));
}
function afterElement(container,x,y,ph){
  // Treffer-Test: über welcher Karte steht der Zeiger? -> davor/danach einsortieren.
  // Kein Sprung, wenn der Zeiger über der Lücke oder zwischen den Karten liegt.
  const cards=[...container.querySelectorAll(":scope > [data-id]:not(.dragging)")];
  if(!cards.length) return null;
  for(const c of cards){
    const b=c.getBoundingClientRect();
    if(x>=b.left && x<=b.right && y>=b.top && y<=b.bottom){
      return (x < b.left + b.width/2) ? c : c.nextElementSibling;
    }
  }
  const first=cards[0].getBoundingClientRect();
  const last=cards[cards.length-1].getBoundingClientRect();
  if(y > last.bottom) return null;       // unterhalb aller Karten -> ans Ende
  if(y < first.top)   return cards[0];   // oberhalb aller Karten -> vor die erste
  return ph;                             // dazwischen -> Platzhalter nicht bewegen
}
function makeSortable(container,onSave){
  container.querySelectorAll(".handle").forEach(h=>{
    if(h._sortBound)return; h._sortBound=true;
    h.addEventListener("pointerdown",e=>{
      if(e.button!==0)return;
      const el=h.closest("[data-id]"); if(!el)return;
      e.preventDefault();
      const rect=el.getBoundingClientRect();
      const offX=e.clientX-rect.left, offY=e.clientY-rect.top;
      // Platzhalter-Lücke einsetzen, Karte "anheben" (schwebt, folgt der Maus)
      const ph=document.createElement("div");
      ph.className="placeholder-slot"; ph.style.height=rect.height+"px";
      container.insertBefore(ph,el);
      window._dragging=true; el.classList.add("dragging");
      el.style.position="fixed"; el.style.width=rect.width+"px";
      el.style.left=(e.clientX-offX)+"px"; el.style.top=(e.clientY-offY)+"px";
      el.style.zIndex="1000"; el.style.pointerEvents="none";
      document.body.appendChild(el);   // aus dem Raster nehmen -> keine Sibling-Rückkopplung
      const move=ev=>{
        ev.preventDefault();
        el.style.left=(ev.clientX-offX)+"px";
        el.style.top=(ev.clientY-offY)+"px";
        const ref=afterElement(container,ev.clientX,ev.clientY,ph);
        if(ref!==ph){ if(ref)container.insertBefore(ph,ref); else container.appendChild(ph); }
      };
      const up=()=>{
        document.removeEventListener("pointermove",move);
        document.removeEventListener("pointerup",up);
        document.removeEventListener("pointercancel",up);
        container.insertBefore(el,ph); ph.remove();
        el.classList.remove("dragging");
        el.style.position=el.style.width=el.style.left=el.style.top=el.style.zIndex=el.style.pointerEvents="";
        window._dragging=false;
        onSave&&onSave();
      };
      document.addEventListener("pointermove",move,{passive:false});
      document.addEventListener("pointerup",up);
      document.addEventListener("pointercancel",up);
    });
  });
}

// Plugin: synchrones Fadenkreuz + Counter-Reset-Marker
const overlay={id:"overlay",afterDraw(c){
  const {ctx,chartArea:a,scales:{x}}=c;
  ctx.save();
  resets.forEach(t=>{const px=x.getPixelForValue(t);if(px>=a.left&&px<=a.right){
    ctx.strokeStyle="rgba(248,81,73,.5)";ctx.setLineDash([3,3]);ctx.lineWidth=1;
    ctx.beginPath();ctx.moveTo(px,a.top);ctx.lineTo(px,a.bottom);ctx.stroke();}});
  if(hoverX!=null){const px=x.getPixelForValue(hoverX);if(px>=a.left&&px<=a.right){
    ctx.setLineDash([]);ctx.strokeStyle=css("--muted");ctx.lineWidth=1;
    ctx.beginPath();ctx.moveTo(px,a.top);ctx.lineTo(px,a.bottom);ctx.stroke();}}
  ctx.restore();
}};

function mkChart(spec){
  const ctx=document.getElementById("c_"+spec.id);
  const yMax=spec.max?{max:spec.max}:{};
  charts[spec.id]=new Chart(ctx,{type:"line",data:{datasets:[]},plugins:[overlay],
    options:{animation:false,responsive:true,maintainAspectRatio:false,
      interaction:{mode:"index",intersect:false},
      onHover:(e,els,c)=>{const p=c.scales.x.getValueForPixel(e.x);if(p===hoverX)return;hoverX=p;
        requestAnimationFrame(()=>Object.values(charts).forEach(o=>o.draw()));},
      scales:{
        x:{type:"linear",ticks:{callback:v=>new Date(v).toLocaleTimeString("de-DE",{hour:"2-digit",minute:"2-digit"}),maxRotation:0,color:css("--muted")},grid:{color:css("--grid")}},
        y:{beginAtZero:true,...yMax,ticks:{color:css("--muted")},grid:{color:css("--grid")}}
      },
      plugins:{
        legend:{display:false},
        zoom:{pan:{enabled:true,mode:"x"},zoom:{wheel:{enabled:true},drag:{enabled:false},pinch:{enabled:true},mode:"x"}},
        annotation:false
      }}});
}

function fieldsFor(spec){
  if(spec.pct){const p=document.getElementById("pct").value;return [{k:spec.pct+"_"+p,l:p.toUpperCase()}];}
  return spec.fields;
}

function capacityOf(model){
  if(!lastConfig)return null;
  const i=lastConfig.instances.find(x=>x.model===model);
  return i&&i.capacity_tokens?i.capacity_tokens:null;
}

function datasets(models,spec){
  const names=Object.keys(models).sort();
  const ds=[];
  names.forEach((name,mi)=>{
    if(hiddenModels.has(name))return;
    const color=colorFor(name);
    const cap=spec.id==="kvtok"?capacityOf(name):null;
    fieldsFor(spec).forEach(f=>{
      const data=models[name].map(p=>{
        let y=p[f.k];
        if(spec.id==="kvtok"){y=(cap&&p.kv!=null)?Math.round(p.kv/100*cap):null;}
        else if(spec.id==="vram"){y=(p.vram_bytes!=null)?Math.round(p.vram_bytes/1e7)/100:null;}
        return {x:p.t,y};
      }).filter(p=>p.y!==null&&p.y!==undefined);
      ds.push({label:shortModel(name)+(f.l?" · "+f.l:""),data,borderColor:color,backgroundColor:color,
               borderDash:f.dash||[],borderWidth:1.8,pointRadius:0,tension:.25,spanGaps:true});
    });
  });
  return ds;
}

function num(v,d){return v==null?"–":(typeof v==="number"?(Number.isInteger(v)?v:v.toFixed(d==null?1:d)):v);}

function renderKPIs(){
  if(!lastData||window._dragging||window._picking)return;   // Verschieben/Farbwahl nicht stören
  const wrap=document.getElementById("kpis");wrap.innerHTML="";
  const alerts=[];
  const saved=JSON.parse(store.get("vllm_kpi_order")||"null");
  const pct=document.getElementById("pct").value;
  orderBy(Object.keys(lastData.models).sort(),saved,m=>m).forEach(model=>{
    const s=lastData.models[model];const last=s.length?s[s.length-1]:{};
    const inst=lastConfig?lastConfig.instances.find(x=>x.model===model):null;
    const online=inst?inst.online:true;
    const kind=inst?inst.kind:"vllm";
    const kv=last.kv||0, wait=last.waiting||0, err=last.error_ps||0, temp=last.gpu_temp||0;
    const kvBad=kv>90, errBad=err>0, tempBad=temp>85;
    if(!online)alerts.push(shortModel(model)+": offline");
    if(kvBad)alerts.push(shortModel(model)+": KV "+kv.toFixed(0)+"%");
    if(errBad)alerts.push(shortModel(model)+": Fehler");
    if(tempBad)alerts.push(shortModel(model)+": "+temp.toFixed(0)+"°C");
    let row;
    if(kind==="gpu"){
      row=`<div class="metric"><b>${num(last.gpu_util,0)}%</b>GPU-Last</div>
        <div class="metric"><b>${last.vram_bytes!=null?(last.vram_bytes/1e9).toFixed(0):"–"} GB</b>VRAM</div>
        <div class="metric ${tempBad?"bad":""}"><b>${num(last.gpu_temp,0)} °C</b>Temp</div>
        <div class="metric"><b>${num(last.gpu_power,0)} W</b>Leistung</div>`;
    }else{
      row=`<div class="metric"><b>${num(last.running,0)}</b>aktiv${wait?` / ${num(wait,0)} wartend`:""}</div>
        <div class="metric ${kvBad?"bad":""}"><b>${kv.toFixed(0)}%</b>KV-Cache</div>
        <div class="metric"><b>${num(last.gen_tps)}</b>gen tok/s</div>
        <div class="metric"><b>${num(last["ttft_"+pct])}</b>TTFT ${pct} (ms)</div>
        <div class="metric ${errBad?"bad":""}"><b>${num(err,2)}</b>Fehler/s</div>`;
    }
    const el=document.createElement("div");
    el.className="kpi"+((kvBad||errBad||tempBad||!online)?" alert":"");
    el.dataset.id=model;
    el.innerHTML=`<h3 class="handle"><span class="dot ${online?"on":"off"}"></span>${shortModel(model)}
        <input type="color" class="cpick" value="${colorFor(model)}" title="Diagramm-Farbe wählen">
        <span style="font-size:11px;color:var(--muted)">${online?"online":"offline"}</span></h3>
      <div class="row">${row}</div>`;
    const pick=el.querySelector(".cpick");
    // Farbwahl darf kein Verschieben auslösen
    ["pointerdown","mousedown","click"].forEach(ev=>pick.addEventListener(ev,e=>e.stopPropagation()));
    // Solange der Picker offen ist, kein Neuzeichnen der Karten (sonst schließt das Popup)
    pick.addEventListener("focus",()=>{window._picking=true;});
    pick.addEventListener("blur",()=>{window._picking=false;renderKPIs();});
    pick.addEventListener("input",e=>setColor(model,e.target.value,false));
    wrap.appendChild(el);
  });
  makeSortable(wrap,()=>saveOrder(wrap,"vllm_kpi_order"));
  window._alerts=alerts;maybeNotify(alerts);
}

function renderInstances(){
  const tb=document.querySelector("#insttable tbody");tb.innerHTML="";
  if(!lastConfig)return;
  lastConfig.instances.forEach(i=>{
    const tr=document.createElement("tr");
    let capcell="–";
    if(i.capacity_tokens){capcell=Math.round(i.capacity_tokens).toLocaleString("de-DE")+" Tok"
      +(i.kv_cache_dtype?` <span style="color:var(--muted)">(${i.kv_cache_dtype})</span>`:"");}
    else if(i.vram_bytes){capcell=(i.vram_bytes/1e9).toFixed(2)+" GB VRAM";}
    tr.innerHTML=`<td><span class="dot ${i.online?"on":"off"}"></span> ${i.online?"online":"offline"}</td>
      <td>${i.kind||"vllm"}</td>
      <td>${i.host}:${i.port}</td><td>${shortModel(i.model)}</td><td>${i.version||"–"}</td>
      <td>${capcell}</td>
      <td>${i.max_model_len?Number(i.max_model_len).toLocaleString("de-DE"):"–"}</td>
      <td>${i.gpu_memory_utilization!=null?i.gpu_memory_utilization:"–"}</td>
      <td>${i.enable_prefix_caching==="True"?"an":"aus"}</td>`;
    tb.appendChild(tr);
  });
}

function applySeries(j){
  if(j.error){document.getElementById("status").textContent=j.error;return;}
  lastData=j;
  resets=[];
  Object.values(j.models).forEach(s=>s.forEach(p=>{if(p.reset)resets.push(p.t);}));
  computeColors(j.models);
  renderLegend(j.models);
  CHARTS.forEach(spec=>{charts[spec.id].data.datasets=datasets(j.models,spec);charts[spec.id].update();});
  renderKPIs();
  const n=Object.values(j.models).reduce((a,s)=>a+s.length,0);
  document.getElementById("status").textContent="Stand "+new Date(j.now).toLocaleTimeString("de-DE")+" · "+n+" Punkte";
}

async function fetchConfig(){try{lastConfig=await(await fetch("/api/config")).json();renderInstances();renderKPIs();}catch(e){}}
async function fetchOnce(){try{applySeries(await(await fetch("/api/series?range="+rangeVal())).json());}catch(e){document.getElementById("status").textContent="Fehler: "+e;}}

// --- Refresh-Steuerung: Live (SSE) oder Intervall ---
let es=null, remaining=0, period=0, lastMsg=Date.now();
const rangeVal=()=>document.getElementById("range").value;
const cd=document.getElementById("countdown");
function setCd(t,cls){cd.className=cls||"";cd.textContent=t;}
function stopAll(){if(es){es.close();es=null;}}

function startRefresh(){
  stopAll();
  const mode=document.getElementById("mode").value;
  if(mode==="off"){setCd("Aktualisierung aus","paused");fetchOnce();return;}
  if(mode==="live"){
    lastMsg=Date.now();
    es=new EventSource("/api/stream?range="+rangeVal());
    es.onmessage=e=>{applySeries(JSON.parse(e.data));lastMsg=Date.now();};
    es.onerror=()=>{stopAll();document.getElementById("mode").value="15";startRefresh();};
    fetchOnce();
  }else{
    period=parseInt(mode,10); remaining=period; fetchOnce();
  }
}
setInterval(()=>{
  const mode=document.getElementById("mode").value;
  if(mode==="off")return;
  if(mode==="live"){
    const secs=Math.max(0,Math.round((Date.now()-lastMsg)/1000));
    setCd("↻ Live · aktualisiert vor "+secs+" s", secs<=1?"now":"");
    return;
  }
  remaining-=1;
  if(remaining<=0){fetchOnce();remaining=period;setCd("↻ 0 s – aktualisiert","now");return;}
  setCd("↻ nächste Aktualisierung in "+remaining+" s","");
},1000);

// --- Export ---
function download(name,text,type){const b=new Blob([text],{type});const u=URL.createObjectURL(b);
  const a=document.createElement("a");a.href=u;a.download=name;a.click();URL.revokeObjectURL(u);}
function exportCSV(){
  if(!lastData)return;
  const fields=["gen_tps","prompt_tps","kv","running","waiting","hit_rate","ttft_p95","e2e_p95","itl_p95","error_ps"];
  let rows=["model,ts,iso,"+fields.join(",")];
  Object.entries(lastData.models).forEach(([m,s])=>s.forEach(p=>{
    rows.push([m,p.t,new Date(p.t).toISOString(),...fields.map(f=>p[f]==null?"":p[f])].join(","));}));
  download("vllm_metrics.csv",rows.join("\n"),"text/csv");
}

// --- Notifications ---
function notifyAvailable(){return (typeof window.Notification!=="undefined" && !!window.Notification
  && typeof window.Notification.requestPermission==="function");}
function maybeNotify(alerts){
  if(!alerts.length||!notifyAvailable()||Notification.permission!=="granted")return;
  const key=alerts.join("|");if(key===window._lastNotifKey)return;window._lastNotifKey=key;
  try{new Notification("vLLM Monitor – Warnung",{body:alerts.join("\n")});}catch(e){}
}

// --- Theme ---
function applyTheme(t){document.body.dataset.theme=t;store.set("vllm_theme",t);
  // Chart-Farben neu setzen
  Object.values(charts).forEach(c=>{c.options.scales.x.ticks.color=css("--muted");c.options.scales.x.grid.color=css("--grid");
    c.options.scales.y.ticks.color=css("--muted");c.options.scales.y.grid.color=css("--grid");
    c.update();});}

// --- Init ---
function buildGrid(){
  const g=document.getElementById("charts");
  const saved=JSON.parse(store.get("vllm_chart_order")||"null");
  const btns=`<div class="cardbtns"><button class="cbtn max" title="Maximieren (Esc schließt)">⛶</button>`+
             `<button class="cbtn close" title="Kachel ausblenden">×</button></div>`;
  orderBy(CHARTS,saved,s=>s.id).forEach(spec=>{
    const d=document.createElement("div");d.className="card";d.dataset.id=spec.id;
    d.innerHTML=btns+`<h2 class="handle" title="${spec.desc||""}">${spec.title}</h2><canvas id="c_${spec.id}"></canvas>`;
    g.appendChild(d);
  });
  makeSortable(g,()=>saveOrder(g,"vllm_chart_order"));
  wireCardButtons(g);
  applyHidden();
  CHARTS.forEach(mkChart);
}

// --- Maximieren / Ausblenden ---
const loadHidden=()=>{try{return JSON.parse(store.get("vllm_hidden")||"[]");}catch(e){return [];}};
const saveHidden=h=>store.set("vllm_hidden",JSON.stringify(h));
function applyHidden(){
  const h=loadHidden();
  document.querySelectorAll("#charts > [data-id]").forEach(c=>c.classList.toggle("hidden-card",h.includes(c.dataset.id)));
  const btn=document.getElementById("restore");
  if(btn){ const n=h.length; btn.style.display=n?"":"none"; btn.textContent="Ausgeblendet: "+n+" ⟲"; }
}
function toggleMax(card,id){
  const on=card.classList.toggle("maximized");
  document.body.style.overflow=on?"hidden":"";
  const c=charts[id]; if(c) setTimeout(()=>{try{c.resize();}catch(e){}},60);
}
function wireCardButtons(container){
  if(container._btnwired)return; container._btnwired=true;
  container.addEventListener("click",e=>{
    const b=e.target.closest(".cbtn"); if(!b)return;
    const card=b.closest("[data-id]"); if(!card)return;
    if(b.classList.contains("max")) toggleMax(card,card.dataset.id);
    else if(b.classList.contains("close")){ const h=loadHidden(); if(!h.includes(card.dataset.id)){h.push(card.dataset.id);saveHidden(h);} if(card.classList.contains("maximized"))toggleMax(card,card.dataset.id); applyHidden(); }
  });
}
// Esc beendet die Maximierung
document.addEventListener("keydown",e=>{
  if(e.key==="Escape"){const m=document.querySelector(".card.maximized");if(m)toggleMax(m,m.dataset.id);}
});

buildGrid();
applyTheme(store.get("vllm_theme")||"dark");
function applyDensity(d){
  document.body.dataset.density=d; store.set("vllm_density",d);
  document.querySelectorAll(".dbtn").forEach(b=>b.classList.toggle("active", b.dataset.d===d));
  setTimeout(()=>Object.values(charts).forEach(c=>{try{c.resize();}catch(e){}}),60);
}
document.querySelectorAll(".dbtn").forEach(b=>b.onclick=()=>applyDensity(b.dataset.d));
applyDensity(store.get("vllm_density")||"normal");
// ⚙-Menü (Latenz-Perzentil + Export)
(function(){
  const gear=document.getElementById("gear"), gmenu=document.getElementById("gearmenu");
  gear.onclick=e=>{ e.stopPropagation(); gmenu.classList.toggle("open"); };
  gmenu.querySelectorAll("button").forEach(b=>b.addEventListener("click",()=>gmenu.classList.remove("open")));
  document.addEventListener("click",e=>{ if(!gmenu.contains(e.target)&&e.target!==gear) gmenu.classList.remove("open"); });
})();
document.getElementById("range").onchange=()=>{fetchConfig();startRefresh();};
document.getElementById("pct").onchange=()=>{if(lastData)applySeries(lastData);};
document.getElementById("mode").onchange=startRefresh;
document.getElementById("reload").onclick=()=>{fetchConfig();fetchOnce();};
document.getElementById("resetzoom").onclick=()=>Object.values(charts).forEach(c=>c.resetZoom&&c.resetZoom());
document.getElementById("export").onclick=exportCSV;
document.getElementById("exportjson").onclick=()=>lastData&&download("vllm_metrics.json",JSON.stringify(lastData,null,2),"application/json");
document.getElementById("theme").onclick=()=>applyTheme(document.body.dataset.theme==="dark"?"light":"dark");
document.getElementById("restore").onclick=()=>{ saveHidden([]); applyHidden(); };
// Instanzen-Karte einklappbar (Zustand im Cookie)
(function(){
  const ic=document.getElementById("instcard"), it=document.getElementById("insttoggle");
  const sync=()=>{ it.textContent = ic.classList.contains("collapsed") ? "▸" : "▾"; };
  if(store.get("vllm_inst_collapsed")==="1") ic.classList.add("collapsed");
  sync();
  it.onclick=()=>{ store.set("vllm_inst_collapsed", ic.classList.toggle("collapsed")?"1":"0"); sync(); };
})();
document.getElementById("notif").onclick=()=>{
  const st=document.getElementById("status");
  const say=t=>{ if(st)st.textContent=t; };
  // Notifications brauchen einen sicheren Kontext (HTTPS oder http://localhost).
  if(!window.isSecureContext || !notifyAvailable()){
    alert("Browser-Benachrichtigungen brauchen einen sicheren Kontext (HTTPS oder http://localhost).\n\n"+
          "Du rufst das Dashboard über http://"+location.hostname+" auf – dort lässt der Browser sie nicht zu "+
          "(deshalb 'nicht erlaubt').\n\nAlternativen: das Dashboard per HTTPS bereitstellen, oder direkt auf der "+
          "Maschine über http://localhost:"+location.port+" öffnen.\n\nDie farbigen Alarm-Rahmen an den Kacheln "+
          "funktionieren unabhängig davon.");
    say("Benachrichtigungen über http://"+location.hostname+" nicht möglich (nur HTTPS/localhost).");
    return;
  }
  if(Notification.permission==="granted"){ say("Benachrichtigungen sind bereits aktiv."); alert("Benachrichtigungen sind bereits aktiv."); return; }
  if(Notification.permission==="denied"){
    alert("Benachrichtigungen sind im Browser für diese Seite blockiert.\n\nBitte über das Schloss-/Info-Symbol "+
          "in der Adressleiste unter 'Benachrichtigungen' auf 'Zulassen' setzen.");
    say("Benachrichtigungen im Browser blockiert – bitte in den Seiteneinstellungen erlauben."); return;
  }
  Notification.requestPermission().then(p=>{
    if(p==="granted"){ say("Benachrichtigungen aktiviert.");
      try{new Notification("vLLM Monitor",{body:"Benachrichtigungen sind jetzt aktiv."});}catch(e){}
      alert("Benachrichtigungen aktiviert."); }
    else { say("Benachrichtigungen: "+p); alert("Benachrichtigungen wurden nicht erlaubt ("+p+")."); }
  });
};
fetchConfig();
startRefresh();
setInterval(fetchConfig,30000);

// --- Verbindungssicherheit & Zertifikat ---
(function(){
  const https=location.protocol==="https:";
  const local=["localhost","127.0.0.1","[::1]",""].includes(location.hostname);
  const tlsAvail="__TLSAVAIL__"==="1";
  const badge=document.getElementById("secbtn");
  badge.textContent=https?"🔒":"⚠️";
  badge.className=https?"secure":"insecure";
  badge.title=https?"Verbindung verschlüsselt (HTTPS) – Zertifikat verwalten"
                    :"Unverschlüsselt (HTTP) – klicken für Zertifikat/HTTPS";
  const banner=document.getElementById("secbanner");
  if(!https && !local) banner.style.display="flex";
  const modal=document.getElementById("certmodal");
  function openModal(){
    const s=document.getElementById("certstatus");
    if(https){
      s.innerHTML='<b style="color:var(--ok)">✔ Verbindung ist verschlüsselt (HTTPS).</b><br>'+
        'Zeigt der Browser dennoch eine Warnung, ist das self-signed Zertifikat noch nicht als '+
        'vertrauenswürdig installiert – unten herunterladen und installieren.';
    }else{
      s.innerHTML='<b style="color:var(--bad)">✖ Unverschlüsselte Verbindung (HTTP).</b><br>'+
        (tlsAvail?('HTTPS ist auf dem Server verfügbar – öffne stattdessen <code>https://'+location.host+'</code>.')
                 :('HTTPS ist nicht aktiviert. Auf dem Server per <code>./setup.sh</code> aktivieren (Menü → HTTPS).'));
    }
    document.getElementById("certdl").style.display=tlsAvail?"":"none";
    modal.style.display="flex";
  }
  badge.onclick=openModal;
  document.getElementById("secbanner-btn").onclick=openModal;
  document.getElementById("secbanner-x").onclick=()=>banner.style.display="none";
  document.getElementById("certclose").onclick=()=>modal.style.display="none";
  modal.onclick=e=>{ if(e.target===modal) modal.style.display="none"; };
  // Download per fetch->Blob: umgeht Chromes Sperre für Downloads über noch
  // nicht vertrauenswürdige (self-signed) HTTPS-Verbindungen ("Netzwerkfehler").
  document.getElementById("certdl").onclick=function(e){
    e.preventDefault();
    const st=document.getElementById("status");
    fetch("/api/cert").then(r=>{ if(!r.ok) throw new Error("HTTP "+r.status); return r.blob(); })
      .then(b=>{ const u=URL.createObjectURL(b); const a=document.createElement("a");
        a.href=u; a.download="vllm-monitor.crt"; document.body.appendChild(a); a.click(); a.remove();
        setTimeout(()=>URL.revokeObjectURL(u),1500);
        if(st) st.textContent="Zertifikat heruntergeladen (vllm-monitor.crt)."; })
      .catch(err=>alert("Download fehlgeschlagen: "+err+"\n\nAlternativ direkt öffnen:\n"+location.origin+"/api/cert"));
  };
  modal.querySelectorAll(".tab").forEach(t=>t.onclick=()=>{
    modal.querySelectorAll(".tab").forEach(x=>x.classList.remove("active"));
    t.classList.add("active");
    ["win","linux","browser"].forEach(k=>document.getElementById("tab-"+k).hidden=(k!==t.dataset.tab));
  });
})();
</script>
</body>
</html>
"""
PAGE = PAGE.replace("__PUSH__", str(PUSH_INTERVAL))


class DashServer(ThreadingHTTPServer):
    """ThreadingHTTPServer mit optionalem TLS. Der TLS-Handshake wird pro
    Verbindung im jeweiligen Handler-Thread ausgeführt (do_handshake_on_connect
    =False), damit eine langsame/haltende Verbindung (z.B. SSE) die zentrale
    accept()-Schleife nicht blockiert."""
    daemon_threads = True
    ssl_ctx = None

    def get_request(self):
        sock, addr = self.socket.accept()
        if self.ssl_ctx is not None:
            sock = self.ssl_ctx.wrap_socket(sock, server_side=True,
                                            do_handshake_on_connect=False)
        return sock, addr

    def handle_error(self, request, client_address):
        pass  # TLS-Handshake-Fehler einzelner Clients nicht ins Log spammen


def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    bind = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("VLLM_DASH_BIND", "127.0.0.1")
    srv = DashServer((bind, port), Handler)

    # TLS: aktiv, sobald VLLM_TLS_CERT + VLLM_TLS_KEY gesetzt sind und existieren.
    scheme = "http"
    cert = os.environ.get("VLLM_TLS_CERT")
    key = os.environ.get("VLLM_TLS_KEY")
    if cert and key and os.path.exists(cert) and os.path.exists(key):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        try:
            ctx.load_cert_chain(certfile=cert, keyfile=key)
        except ssl.SSLError as e:
            print("  [!] TLS-Zertifikat/Key konnte nicht geladen werden: %s" % e)
            sys.exit(1)
        srv.ssl_ctx = ctx      # pro Verbindung umhüllen, nicht den Listen-Socket
        scheme = "https"
        global CERT_PATH
        CERT_PATH = cert       # für den Zertifikat-Download (/api/cert)
    elif cert or key:
        print("  [!] Für HTTPS müssen BEIDE gesetzt sein: VLLM_TLS_CERT und VLLM_TLS_KEY – starte als HTTP.")

    shown = bind if bind not in ("0.0.0.0", "") else "<diese-IP>"
    print("vLLM-Dashboard %s läuft:  %s://%s:%d  (Bind %s)" % (__version__, scheme, shown, port, bind))
    if scheme == "https":
        print("  [i] Self-signed? Der Browser zeigt einmalig eine Warnung – Ausnahme bestätigen.")
    if bind in ("0.0.0.0", ""):
        print("  [!] Ohne Auth im Netzwerk erreichbar – ggf. per Firewall einschränken.")
    print("DB: %s   (Strg+C zum Beenden)" % DB_PATH)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nDashboard beendet.")


if __name__ == "__main__":
    main()
