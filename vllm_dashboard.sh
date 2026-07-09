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

Nur Python-Standardbibliothek – Chart.js/Zoom-Plugin via CDN.
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

__version__ = "0.9.0"

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vllm_metrics.db")
DEFAULT_PORT = 8899
LABEL = os.environ.get("VLLM_LABEL", "")
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
        inst.append({
            "host": c["host"], "port": c["port"], "model": c["model"],
            "online": online, "age": age,
            "num_gpu_blocks": c["num_gpu_blocks"], "block_size": c["block_size"],
            "capacity_tokens": cap, "max_model_len": c["max_model_len"],
            "gpu_memory_utilization": c["gpu_memory_utilization"],
            "kv_cache_dtype": c["kv_cache_dtype"],
            "enable_prefix_caching": c["enable_prefix_caching"],
            "version": c["version"],
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
        elif parsed.path in ("/", "/index.html"):
            sub = ("– " + html.escape(LABEL)) if LABEL else ""
            page = PAGE.replace("__SUBTITLE__", sub).replace("__VERSION__", __version__)
            self._send(200, "text/html; charset=utf-8", page.encode("utf-8"))
        else:
            self._send(404, "text/plain", b"not found")

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
  }
  [data-theme="light"]{
    --bg:#f6f8fa; --panel:#ffffff; --border:#d0d7de; --grid:#eaeef2;
    --fg:#1f2328; --muted:#57606a; --accent:#0969da;
  }
  *{box-sizing:border-box}
  body{font-family:system-ui,sans-serif;margin:0;background:var(--bg);color:var(--fg);}
  header{padding:12px 18px;background:var(--panel);border-bottom:1px solid var(--border);
         display:flex;align-items:center;gap:12px;flex-wrap:wrap;position:sticky;top:0;z-index:10;}
  h1{font-size:17px;margin:0;font-weight:600;}
  select,button{background:var(--panel);color:var(--fg);border:1px solid var(--border);
                border-radius:6px;padding:5px 9px;font-size:12px;cursor:pointer;}
  button:hover{border-color:var(--accent);}
  label.ctl{color:var(--muted);font-size:12px;display:flex;align-items:center;gap:5px;}
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
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(430px,1fr));gap:14px;padding:14px 16px;}
  .card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:10px 12px;}
  .card h2{font-size:12px;margin:0 0 6px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;}
  canvas{max-height:240px;}
  table{width:100%;border-collapse:collapse;font-size:12px;}
  th,td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--grid);}
  th{color:var(--muted);font-weight:600;}
  .placeholder{color:var(--muted);font-size:12px;padding:18px 4px;text-align:center;}
  #status{font-size:11px;color:var(--muted);}
</style>
</head>
<body>
<header>
  <h1>vLLM Monitor <span style="color:var(--muted)">__SUBTITLE__</span></h1>
  <span style="font-size:11px;color:var(--muted)">v__VERSION__</span>
  <label class="ctl">Zeitraum
    <select id="range">
      <option value="900">15 min</option>
      <option value="3600" selected>1 h</option>
      <option value="21600">6 h</option>
      <option value="86400">24 h</option>
      <option value="604800">7 Tage</option>
    </select>
  </label>
  <label class="ctl">Latenz
    <select id="pct"><option value="p50">P50</option><option value="p95" selected>P95</option><option value="p99">P99</option></select>
  </label>
  <label class="ctl">Aktualisierung
    <select id="mode">
      <option value="live" selected>Live (SSE)</option>
      <option value="5">alle 5 s</option>
      <option value="15">alle 15 s</option>
      <option value="60">alle 60 s</option>
      <option value="off">Aus</option>
    </select>
  </label>
  <button id="reload">Neu laden</button>
  <button id="resetzoom" title="Zoom zurücksetzen">Zoom ⟲</button>
  <button id="export">Export CSV</button>
  <button id="exportjson">JSON</button>
  <button id="theme" title="Hell/Dunkel">◐</button>
  <button id="notif" title="Alarm-Benachrichtigungen">🔔</button>
  <span id="countdown"></span>
</header>

<div class="kpis" id="kpis"></div>

<div class="card" style="margin:14px 16px 0">
  <h2>Instanzen</h2>
  <table id="insttable"><thead><tr>
    <th>Status</th><th>Instanz</th><th>Modell</th><th>vLLM</th>
    <th>KV-Kapazität</th><th>max_model_len</th><th>gpu_mem</th><th>Prefix-Cache</th>
  </tr></thead><tbody></tbody></table>
</div>

<div class="grid" id="charts"></div>

<script>
const COLORS=["#58a6ff","#f778ba","#3fb950","#d29922","#a371f7","#ff7b72"];
if(window.ChartZoom) Chart.register(window.ChartZoom);

const CHARTS=[
 {id:"kv",title:"KV-Cache-Auslastung (%)",fields:[{k:"kv"}],max:100,threshold:90},
 {id:"kvtok",title:"KV-Belegung (Tokens, rel. zur Kapazität)",fields:[{k:"kv_tokens"}]},
 {id:"req",title:"Requests aktiv / wartend",fields:[{k:"running",l:"aktiv"},{k:"waiting",l:"wartend",dash:[4,3]}]},
 {id:"waitreason",title:"Wartend nach Grund",fields:[{k:"waiting_capacity",l:"capacity"},{k:"waiting_deferred",l:"deferred",dash:[4,3]}]},
 {id:"preempt",title:"Preemptions/s",fields:[{k:"preempt_ps"}]},
 {id:"gen",title:"Generierung (Tokens/s)",fields:[{k:"gen_tps"}]},
 {id:"prompt",title:"Prompt-Durchsatz (Tokens/s)",fields:[{k:"prompt_tps"}]},
 {id:"ttft",title:"Time-to-First-Token (ms)",pct:"ttft"},
 {id:"e2e",title:"E2E-Latenz (s)",pct:"e2e"},
 {id:"itl",title:"Inter-Token-Latenz (ms)",pct:"itl"},
 {id:"finish",title:"Requests nach Ergebnis (/s)",fields:[{k:"stop_ps",l:"stop"},{k:"error_ps",l:"error"},{k:"abort_ps",l:"abort",dash:[4,3]},{k:"length_ps",l:"length",dash:[2,2]}]},
 {id:"hit",title:"Prefix-Cache-Hit-Rate (%)",fields:[{k:"hit_rate"}],max:100},
];

let charts={}, lastData=null, lastConfig=null, hoverX=null, resets=[];
const shortModel=m=>m.split("/").pop();
const css=v=>getComputedStyle(document.body).getPropertyValue(v).trim();

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
      onHover:(e,els,c)=>{const p=c.scales.x.getValueForPixel(e.x);hoverX=p;Object.values(charts).forEach(o=>o.draw());},
      scales:{
        x:{type:"linear",ticks:{callback:v=>new Date(v).toLocaleTimeString("de-DE",{hour:"2-digit",minute:"2-digit"}),maxRotation:0,color:css("--muted")},grid:{color:css("--grid")}},
        y:{beginAtZero:true,...yMax,ticks:{color:css("--muted")},grid:{color:css("--grid")}}
      },
      plugins:{
        legend:{labels:{color:css("--fg"),boxWidth:11,font:{size:10}}},
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
    const color=COLORS[mi%COLORS.length];
    fieldsFor(spec).forEach(f=>{
      const data=models[name].map(p=>{
        let y=p[f.k];
        if(spec.id==="kvtok"){const cap=capacityOf(name);y=(cap&&p.kv!=null)?Math.round(p.kv/100*cap):null;}
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
  if(!lastData)return;
  const wrap=document.getElementById("kpis");wrap.innerHTML="";
  const alerts=[];
  Object.keys(lastData.models).sort().forEach(model=>{
    const s=lastData.models[model];const last=s.length?s[s.length-1]:{};
    const inst=lastConfig?lastConfig.instances.find(x=>x.model===model):null;
    const online=inst?inst.online:true;
    const kv=last.kv||0, wait=last.waiting||0, err=last.error_ps||0;
    const kvBad=kv>90, waitWarn=wait>0, errBad=err>0;
    if(!online)alerts.push(shortModel(model)+": offline");
    if(kvBad)alerts.push(shortModel(model)+": KV "+kv.toFixed(0)+"%");
    if(errBad)alerts.push(shortModel(model)+": Fehler");
    const pct=document.getElementById("pct").value;
    const el=document.createElement("div");
    el.className="kpi"+((kvBad||errBad||!online)?" alert":"");
    el.innerHTML=`<h3><span class="dot ${online?"on":"off"}"></span>${shortModel(model)}
        <span style="margin-left:auto;font-size:11px;color:var(--muted)">${online?"online":"offline"}</span></h3>
      <div class="row">
        <div class="metric"><b>${num(last.running,0)}</b>aktiv${wait?` / ${num(wait,0)} wartend`:""}</div>
        <div class="metric ${kvBad?"bad":""}"><b>${kv.toFixed(0)}%</b>KV-Cache</div>
        <div class="metric"><b>${num(last.gen_tps)}</b>gen tok/s</div>
        <div class="metric"><b>${num(last["ttft_"+pct])}</b>TTFT ${pct} (ms)</div>
        <div class="metric ${errBad?"bad":""}"><b>${num(err,2)}</b>Fehler/s</div>
      </div>`;
    wrap.appendChild(el);
  });
  window._alerts=alerts;maybeNotify(alerts);
}

function renderInstances(){
  const tb=document.querySelector("#insttable tbody");tb.innerHTML="";
  if(!lastConfig)return;
  lastConfig.instances.forEach(i=>{
    const tr=document.createElement("tr");
    const cap=i.capacity_tokens?Math.round(i.capacity_tokens).toLocaleString("de-DE")+" Tok":"–";
    tr.innerHTML=`<td><span class="dot ${i.online?"on":"off"}"></span> ${i.online?"online":"offline"}</td>
      <td>${i.host}:${i.port}</td><td>${shortModel(i.model)}</td><td>${i.version||"–"}</td>
      <td>${cap}${i.kv_cache_dtype?` <span style="color:var(--muted)">(${i.kv_cache_dtype})</span>`:""}</td>
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
  CHARTS.forEach(spec=>{charts[spec.id].data.datasets=datasets(j.models,spec);charts[spec.id].update();});
  renderKPIs();
  const n=Object.values(j.models).reduce((a,s)=>a+s.length,0);
  document.getElementById("status").textContent="Stand "+new Date(j.now).toLocaleTimeString("de-DE")+" · "+n+" Punkte";
}

async function fetchConfig(){try{lastConfig=await(await fetch("/api/config")).json();renderInstances();renderKPIs();}catch(e){}}
async function fetchOnce(){try{applySeries(await(await fetch("/api/series?range="+rangeVal())).json());}catch(e){document.getElementById("status").textContent="Fehler: "+e;}}

// --- Refresh-Steuerung: Live (SSE) oder Intervall ---
let es=null, remaining=0, period=0;
const rangeVal=()=>document.getElementById("range").value;
const cd=document.getElementById("countdown");
function setCd(t,cls){cd.className=cls||"";cd.textContent=t;}
function stopAll(){if(es){es.close();es=null;}}

function startRefresh(){
  stopAll();
  const mode=document.getElementById("mode").value;
  if(mode==="off"){setCd("Aktualisierung aus","paused");fetchOnce();return;}
  if(mode==="live"){
    period=__PUSH__; remaining=period;
    es=new EventSource("/api/stream?range="+rangeVal());
    es.onmessage=e=>{applySeries(JSON.parse(e.data));remaining=period;};
    es.onerror=()=>{stopAll();document.getElementById("mode").value="15";startRefresh();};
    fetchOnce();
  }else{
    period=parseInt(mode,10); remaining=period; fetchOnce();
  }
}
setInterval(()=>{
  const mode=document.getElementById("mode").value;
  if(mode==="off")return;
  remaining-=1;
  if(mode!=="live"&&remaining<=0){fetchOnce();remaining=period;setCd("↻ 0 s – aktualisiert","now");return;}
  const label=mode==="live"?"Live – nächster Push":"nächste Aktualisierung";
  setCd("↻ "+label+" in "+Math.max(0,remaining)+" s",mode==="live"?"now":"");
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
function maybeNotify(alerts){
  if(!alerts.length||Notification.permission!=="granted")return;
  const key=alerts.join("|");if(key===window._lastNotifKey)return;window._lastNotifKey=key;
  new Notification("vLLM Monitor – Warnung",{body:alerts.join("\n")});
}

// --- Theme ---
function applyTheme(t){document.body.dataset.theme=t;localStorage.setItem("vllm_theme",t);
  // Chart-Farben neu setzen
  Object.values(charts).forEach(c=>{c.options.scales.x.ticks.color=css("--muted");c.options.scales.x.grid.color=css("--grid");
    c.options.scales.y.ticks.color=css("--muted");c.options.scales.y.grid.color=css("--grid");
    c.options.plugins.legend.labels.color=css("--fg");c.update();});}

// --- Init ---
function buildGrid(){
  const g=document.getElementById("charts");
  CHARTS.forEach(spec=>{const d=document.createElement("div");d.className="card";
    d.innerHTML=`<h2>${spec.title}</h2><canvas id="c_${spec.id}"></canvas>`;g.appendChild(d);});
  // GPU-Hardware-Platzhalter (#15)
  const gpu=document.createElement("div");gpu.className="card";
  gpu.innerHTML=`<h2>GPU-Hardware</h2><div class="placeholder">SM-Auslastung, VRAM, Temperatur, Watt –
    noch nicht verfügbar.<br>Benötigt einen DCGM-/node-Exporter auf dem Zielhost (Roadmap).</div>`;
  g.appendChild(gpu);
  CHARTS.forEach(mkChart);
}

buildGrid();
applyTheme(localStorage.getItem("vllm_theme")||"dark");
document.getElementById("range").onchange=()=>{fetchConfig();startRefresh();};
document.getElementById("pct").onchange=()=>{if(lastData)applySeries(lastData);};
document.getElementById("mode").onchange=startRefresh;
document.getElementById("reload").onclick=()=>{fetchConfig();fetchOnce();};
document.getElementById("resetzoom").onclick=()=>Object.values(charts).forEach(c=>c.resetZoom&&c.resetZoom());
document.getElementById("export").onclick=exportCSV;
document.getElementById("exportjson").onclick=()=>lastData&&download("vllm_metrics.json",JSON.stringify(lastData,null,2),"application/json");
document.getElementById("theme").onclick=()=>applyTheme(document.body.dataset.theme==="dark"?"light":"dark");
document.getElementById("notif").onclick=()=>Notification.requestPermission();
fetchConfig();
startRefresh();
setInterval(fetchConfig,30000);
</script>
</body>
</html>
"""
PAGE = PAGE.replace("__PUSH__", str(PUSH_INTERVAL))


def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    bind = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("VLLM_DASH_BIND", "127.0.0.1")
    srv = ThreadingHTTPServer((bind, port), Handler)
    shown = bind if bind not in ("0.0.0.0", "") else "<diese-IP>"
    print("vLLM-Dashboard %s läuft:  http://%s:%d  (Bind %s)" % (__version__, shown, port, bind))
    if bind in ("0.0.0.0", ""):
        print("  [!] Ohne Auth im Netzwerk erreichbar – ggf. per Firewall einschränken.")
    print("DB: %s   (Strg+C zum Beenden)" % DB_PATH)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nDashboard beendet.")


if __name__ == "__main__":
    main()
