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
import hmac
import base64
import socket
import hashlib
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from urllib import request as urlrequest, error as urlerror

__version__ = "0.17.0"

DB_PATH = os.environ.get("VLLM_DB") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "vllm_metrics.db")
DEFAULT_PORT = 8899
LABEL = os.environ.get("VLLM_LABEL", "")
CERT_PATH = None            # wird in main() gesetzt, wenn TLS aktiv ist
PUSH_INTERVAL = 5           # SSE-Push-Takt (Sekunden)

# KI-Auswertung: OpenAI-kompatibler Chat-Endpunkt (Default: leer -> im Frontend
# konfigurierbar). Werte aus dem Request-Body haben Vorrang vor diesen Defaults.
AI_URL = os.environ.get("VLLM_AI_URL", "")        # z. B. http://host:9081/v1/chat/completions
AI_MODEL = os.environ.get("VLLM_AI_MODEL", "")
AI_KEY = os.environ.get("VLLM_AI_KEY", "")
AI_TIMEOUT = float(os.environ.get("VLLM_AI_TIMEOUT", "120"))
AI_MAX_TOKENS = int(os.environ.get("VLLM_AI_MAX_TOKENS", "2000"))
# Reasoning-Modelle (Qwen3 u.a.): Denk-Phase abschalten -> saubere, kurze Antwort
AI_NO_THINK = os.environ.get("VLLM_AI_NO_THINK", "0").lower() not in ("0", "false", "no", "off", "")
STALE_AFTER = 90            # Instanz gilt als offline, wenn älter (Sekunden)

# Schwellwerte für Alarme (dieselben Env wie der Collector; ans Frontend gereicht)
ALERT_KV = float(os.environ.get("VLLM_ALERT_KV", "90"))
ALERT_TEMP = float(os.environ.get("VLLM_ALERT_TEMP", "85"))
ALERT_ERR = float(os.environ.get("VLLM_ALERT_ERR", "0"))
ALERT_OFFLINE_MIN = float(os.environ.get("VLLM_ALERT_OFFLINE_MIN", "1"))

# Geplanter Schicht-Report (CLI `report` + systemd-Timer)
REPORT_DIR = os.environ.get("VLLM_REPORT_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "reports")
REPORT_RANGE = int(os.environ.get("VLLM_REPORT_RANGE", str(8 * 3600)))

# --- Authentifizierung: lokale Nutzer + optional LDAP/AD; alles in auth.json ---
# Auth ist IMMER aktiv (Default-Konto admin/admin, Passwortwechsel erzwungen).
# LDAP-/Nutzer-Konfiguration wird im Frontend gepflegt und in auth.json abgelegt.
# Die VLLM_LDAP_*-Env-Variablen dienen nur noch als Erst-Seed beim allerersten Start.
AUTH_FILE = os.environ.get("VLLM_AUTH_FILE",
                           os.path.join(os.path.dirname(os.path.abspath(DB_PATH)), "auth.json"))
AUTH_REALM = os.environ.get("VLLM_AUTH_REALM", "vLLM Monitor")
AUTH_TTL = int(os.environ.get("VLLM_AUTH_TTL", "300"))        # Sekunden, erfolgreiche Prüfung cachen
AUTH_ENABLED = True                                           # immer an
AUTH_COOKIE = "vllm_auth"                                    # persistentes Sitzungs-Cookie
AUTH_COOKIE_DAYS = int(os.environ.get("VLLM_AUTH_COOKIE_DAYS", "7"))
PBKDF2_ITER = int(os.environ.get("VLLM_PBKDF2_ITER", "200000"))
ROLES = ("admin", "readonly")
_auth_cache = {}                                             # cred-hash -> (Ablaufzeit, userdict)
_auth_lock = threading.Lock()
_auth_file_lock = threading.Lock()


def _load_auth_secret():
    """Stabiles HMAC-Secret für Session-Cookies (Env oder persistente Datei)."""
    s = os.environ.get("VLLM_AUTH_SECRET")
    if s:
        return s.encode("utf-8")
    path = os.path.join(os.path.dirname(os.path.abspath(DB_PATH)), ".auth_secret")
    try:
        with open(path, "rb") as f:
            data = f.read()
        if data:
            return data
    except OSError:
        pass
    secret = os.urandom(32)
    try:
        with open(path, "wb") as f:
            f.write(secret)
        os.chmod(path, 0o600)
    except OSError:
        pass
    return secret


AUTH_SECRET = _load_auth_secret()

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

def build_series(range_s, offset_s=0, start=None, end=None):
    if not os.path.exists(DB_PATH):
        return {"error": "Keine Datenbank – läuft der Collector?", "models": {}}

    now = int(time.time())
    if start is not None and end is not None:
        since = start                       # absolutes Fenster (Von/Bis)
    else:
        end = now - offset_s
        since = end - range_s
    bucket = max(1, (end - since) // 800)

    conn = _connect()
    in_window = conn.execute("""
        SELECT s.* FROM samples s
        JOIN (SELECT model, MAX(ts) AS mts FROM samples
               WHERE ts >= ? AND ts < ? GROUP BY model, ts / ?) g
          ON s.model = g.model AND s.ts = g.mts
        ORDER BY s.model, s.ts
    """, (since, end, bucket)).fetchall()
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
                "t": (r["ts"] + offset_s) * 1000,   # bei Vergleich aufs aktuelle Fenster projiziert
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

    return {"now": now * 1000, "range": range_s, "bucket": bucket,
            "offset": offset_s, "models": out}


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
    # Konfigurierte, aber (noch) nie erreichte Instanzen ergänzen, damit
    # eingetragene Ziele auch offline sichtbar sind (statt zu „verschwinden").
    seen = {(i["host"], str(i["port"])) for i in inst}
    for t in _load_targets():
        if t.get("enabled", True) is False:
            continue
        key = (t.get("host"), str(t.get("port")))
        if not t.get("host") or t.get("port") is None or key in seen:
            continue
        seen.add(key)
        inst.append({
            "host": t.get("host"), "port": t.get("port"),
            "model": t.get("label") or t.get("kind") or "—",
            "kind": t.get("kind") or "vllm", "online": False, "age": None,
            "num_gpu_blocks": None, "block_size": None, "capacity_tokens": 0,
            "max_model_len": None, "gpu_memory_utilization": None,
            "kv_cache_dtype": None, "enable_prefix_caching": None,
            "version": None, "vram_bytes": None, "configured": True,
        })
    inst.sort(key=lambda i: (i["host"] or "", i["port"] or 0))

    # Self-Monitoring: Herzschlag des Collectors
    collector = None
    try:
        r = conn.execute("SELECT ts,scrapes,errors,interval,version,host "
                         "FROM collector_status WHERE id=1").fetchone()
        if r and r["ts"]:
            iv = r["interval"] or 15
            age = now - r["ts"]
            collector = {"ts": r["ts"] * 1000, "age": age, "scrapes": r["scrapes"],
                         "errors": r["errors"], "interval": iv, "version": r["version"],
                         "host": r["host"], "ok": age <= max(3 * iv, 60)}
    except sqlite3.OperationalError:
        collector = None            # alter Collector ohne Heartbeat-Tabelle
    conn.close()
    # Zentrale KI-Config (Server-Default für alle Frontends). Der Key selbst wird
    # NIE ausgeliefert – nur, ob server-seitig einer gesetzt ist.
    ai = {"url": AI_URL, "model": AI_MODEL, "key_set": bool(AI_KEY),
          "configured": bool(AI_URL)}
    return {"now": now * 1000, "instances": inst, "ai": ai,
            "thresholds": load_thresholds(), "collector": collector}


def build_alerts(limit=100):
    """Letzte Alarm-Ereignisse (Historie) aus der events-Tabelle."""
    if not os.path.exists(DB_PATH):
        return {"events": []}
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT ts,host,port,model,kind,state,severity,value,message "
            "FROM events ORDER BY ts DESC, id DESC LIMIT ?", (int(limit),)).fetchall()
    except sqlite3.OperationalError:
        conn.close()
        return {"events": []}   # Tabelle noch nicht vorhanden (alter Collector)
    conn.close()
    ev = [{"ts": r["ts"] * 1000, "host": r["host"], "port": r["port"],
           "model": r["model"], "kind": r["kind"], "state": r["state"],
           "severity": r["severity"], "value": r["value"], "message": r["message"]}
          for r in rows]
    return {"events": ev, "now": int(time.time()) * 1000}


def _ensure_annotations(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS annotations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL, label TEXT, created INTEGER)""")


def build_annotations(range_s=None, start=None, end=None):
    """Manuelle Zeitachsen-Annotationen (Deploy/Restart o. ä.)."""
    if not os.path.exists(DB_PATH):
        return {"annotations": []}
    conn = _connect()
    _ensure_annotations(conn)
    if start is not None and end is not None:
        rows = conn.execute("SELECT id,ts,label FROM annotations WHERE ts>=? AND ts<? ORDER BY ts",
                            (start, end)).fetchall()
    elif range_s:
        since = int(time.time()) - range_s
        rows = conn.execute("SELECT id,ts,label FROM annotations WHERE ts>=? ORDER BY ts",
                            (since,)).fetchall()
    else:
        rows = conn.execute("SELECT id,ts,label FROM annotations ORDER BY ts DESC LIMIT 500").fetchall()
    conn.close()
    return {"annotations": [{"id": r["id"], "ts": r["ts"] * 1000, "label": r["label"]} for r in rows]}


def add_annotation(ts, label):
    label = (label or "").strip()[:120]
    if not label:
        return {"error": "leeres Label"}
    ts = int(ts) if ts else int(time.time())
    conn = _connect()
    _ensure_annotations(conn)
    cur = conn.execute("INSERT INTO annotations (ts,label,created) VALUES (?,?,?)",
                       (ts, label, int(time.time())))
    conn.commit()
    nid = cur.lastrowid
    conn.close()
    return {"ok": True, "id": nid, "ts": ts * 1000, "label": label}


def del_annotation(aid):
    conn = _connect()
    _ensure_annotations(conn)
    conn.execute("DELETE FROM annotations WHERE id=?", (int(aid),))
    conn.commit()
    conn.close()
    return {"ok": True}


# ---------------------------------------------------------------------------
# UI-verwaltete Instanzen (targets.json; der Collector lädt sie zur Laufzeit neu)
# ---------------------------------------------------------------------------

TARGETS_FILE = os.environ.get("VLLM_TARGETS_FILE") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "targets.json")
_targets_lock = threading.Lock()
_TARGET_KINDS = ("vllm", "ollama", "stt", "dcgm")


def _load_targets():
    try:
        with open(TARGETS_FILE) as f:
            data = json.load(f)
        return data.get("targets", []) if isinstance(data, dict) else []
    except (OSError, ValueError):
        return []


def _save_targets(targets):
    tmp = TARGETS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"targets": targets}, f, indent=2)
    os.replace(tmp, TARGETS_FILE)


def _target_id(t):
    return "%s:%s:%s" % (t.get("kind"), t.get("host"), t.get("port"))


def build_targets():
    return {"targets": _load_targets(), "file": TARGETS_FILE}


def add_target(body):
    kind = (body.get("kind") or "").strip().lower()
    host = (body.get("host") or "").strip()
    label = (body.get("label") or "").strip()
    if kind not in _TARGET_KINDS:
        return {"error": "ungültiger Typ"}
    if not host:
        return {"error": "Host fehlt"}
    try:
        port = int(body.get("port"))
    except (ValueError, TypeError):
        return {"error": "ungültiger Port"}
    newt = {"kind": kind, "host": host, "port": port, "label": label,
            "enabled": bool(body.get("enabled", True))}
    nid = _target_id(newt)
    with _targets_lock:
        targets = _load_targets()
        for i, t in enumerate(targets):
            if _target_id(t) == nid:
                targets[i] = newt
                break
        else:
            targets.append(newt)
        _save_targets(targets)
    return {"ok": True, "id": nid}


def del_target(tid):
    with _targets_lock:
        targets = _load_targets()
        victim = next((t for t in targets if _target_id(t) == tid), None)
        if victim is None:
            return {"ok": True}
        if victim.get("kind") == "vllm" and sum(1 for t in targets if t.get("kind") == "vllm") <= 1:
            return {"error": "Die letzte vLLM-Instanz kann nicht gelöscht werden."}
        _save_targets([t for t in targets if _target_id(t) != tid])
    return {"ok": True}


# --- Alarm-Schwellwerte (im UI editierbar, vom Collector zur Laufzeit gelesen) ---
SETTINGS_FILE = os.environ.get("VLLM_SETTINGS_FILE") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "settings.json")
_settings_lock = threading.Lock()
_THRESH_DEFAULTS = {"kv": ALERT_KV, "temp": ALERT_TEMP, "err": ALERT_ERR,
                    "offline_min": ALERT_OFFLINE_MIN}


def load_thresholds():
    """Schwellwerte: settings.json überschreibt die Env-Defaults."""
    t = dict(_THRESH_DEFAULTS)
    try:
        with open(SETTINGS_FILE) as f:
            d = json.load(f)
        for k in t:
            if k in d.get("thresholds", {}):
                t[k] = float(d["thresholds"][k])
    except (OSError, ValueError, TypeError):
        pass
    return t


def save_thresholds(body):
    if not isinstance(body, dict):
        return {"error": "ungültige Anfrage"}
    cur = load_thresholds()
    for k in _THRESH_DEFAULTS:
        if k in body:
            try:
                v = float(body[k])
            except (ValueError, TypeError):
                return {"error": "ungültiger Wert für %s" % k}
            if v < 0:
                return {"error": "Werte dürfen nicht negativ sein"}
            cur[k] = v
    with _settings_lock:
        data = {}
        try:
            with open(SETTINGS_FILE) as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = {}
        data["thresholds"] = cur
        tmp = SETTINGS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, SETTINGS_FILE)
    return {"ok": True, "thresholds": cur}


# ---------------------------------------------------------------------------
# Prometheus-Exporter (GET /metrics) – additiv für vorhandenes Grafana/Prometheus
# ---------------------------------------------------------------------------

# (samples-Spalte, Prom-Name, Typ, HELP). Counter kumulativ -> Prometheus bildet rate().
PROM_METRICS = [
    ("kv_cache_usage", "vllm_monitor_kv_cache_usage_ratio", "gauge", "KV-Cache-Auslastung (0..1)"),
    ("requests_running", "vllm_monitor_requests_running", "gauge", "Laufende Requests"),
    ("requests_waiting", "vllm_monitor_requests_waiting", "gauge", "Wartende Requests"),
    ("prompt_tokens_total", "vllm_monitor_prompt_tokens_total", "counter", "Prompt-Tokens (kumulativ)"),
    ("generation_tokens_total", "vllm_monitor_generation_tokens_total", "counter", "Generierte Tokens (kumulativ)"),
    ("requests_success_total", "vllm_monitor_request_success_total", "counter", "Erfolgreiche Requests (kumulativ)"),
    ("requests_error_total", "vllm_monitor_request_error_total", "counter", "Fehlerhafte Requests (kumulativ)"),
    ("prefix_queries_total", "vllm_monitor_prefix_cache_queries_total", "counter", "Prefix-Cache-Anfragen (kumulativ)"),
    ("prefix_hits_total", "vllm_monitor_prefix_cache_hits_total", "counter", "Prefix-Cache-Treffer (kumulativ)"),
    ("preemptions_total", "vllm_monitor_preemptions_total", "counter", "Preemptions (kumulativ)"),
    ("ttft_sum", "vllm_monitor_ttft_seconds_sum", "counter", "Time-to-First-Token Summe (s)"),
    ("ttft_count", "vllm_monitor_ttft_seconds_count", "counter", "Time-to-First-Token Anzahl"),
    ("e2e_sum", "vllm_monitor_e2e_seconds_sum", "counter", "E2E-Latenz Summe (s)"),
    ("e2e_count", "vllm_monitor_e2e_seconds_count", "counter", "E2E-Latenz Anzahl"),
    ("itl_sum", "vllm_monitor_itl_seconds_sum", "counter", "Inter-Token-Latenz Summe (s)"),
    ("itl_count", "vllm_monitor_itl_seconds_count", "counter", "Inter-Token-Latenz Anzahl"),
    ("gpu_util", "vllm_monitor_gpu_utilization_percent", "gauge", "GPU-Auslastung (%)"),
    ("gpu_mem_util", "vllm_monitor_gpu_memory_utilization_percent", "gauge", "GPU-Speicher-Auslastung (%)"),
    ("gpu_temp", "vllm_monitor_gpu_temperature_celsius", "gauge", "GPU-Temperatur (°C)"),
    ("gpu_power", "vllm_monitor_gpu_power_watts", "gauge", "GPU-Leistung (W)"),
    ("vram_bytes", "vllm_monitor_vram_used_bytes", "gauge", "Belegter VRAM (Bytes)"),
]


def _prom_esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _prom_num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return "0"
    return str(int(f)) if f == int(f) else repr(f)


def build_prometheus():
    now = int(time.time())
    out = {}   # name -> {"type","help","rows":[(labels, val)]}

    def add(name, typ, help_, labels, val):
        if val is None:
            return
        e = out.setdefault(name, {"type": typ, "help": help_, "rows": []})
        e["rows"].append((labels, val))

    if os.path.exists(DB_PATH):
        conn = _connect()
        # Neueste Probe je Instanz (nur kürzlich gesehene -> „lebende" Instanzen)
        rows = conn.execute("""
            SELECT s.* FROM samples s
            JOIN (SELECT host,port,model,MAX(ts) AS mts FROM samples
                   WHERE ts >= ? GROUP BY host,port,model) g
              ON s.host=g.host AND s.port=g.port AND s.model=g.model AND s.ts=g.mts
        """, (now - 600,)).fetchall()
        for r in rows:
            lab = {"host": r["host"], "port": str(r["port"]), "model": r["model"]}
            for col, name, typ, help_ in PROM_METRICS:
                add(name, typ, help_, lab, r[col])
        # Instanz online/offline aus config
        for c in conn.execute("SELECT host,port,model,up,updated,kind FROM config"):
            age = now - (c["updated"] or 0)
            up = 1 if (c["up"] and age <= STALE_AFTER) else 0
            add("vllm_monitor_instance_up", "gauge", "Instanz online (1) / offline (0)",
                {"host": c["host"], "port": str(c["port"]), "model": c["model"],
                 "kind": (c["kind"] if "kind" in c.keys() and c["kind"] else "vllm")}, up)
        # Collector-Self-Monitoring
        try:
            cs = conn.execute("SELECT ts,scrapes,errors,interval FROM collector_status WHERE id=1").fetchone()
        except sqlite3.OperationalError:
            cs = None
        if cs and cs["ts"]:
            iv = cs["interval"] or 15
            add("vllm_monitor_collector_last_scrape_timestamp_seconds", "gauge",
                "Unix-Zeit des letzten Collector-Scrapes", {}, cs["ts"])
            add("vllm_monitor_collector_scrapes_total", "counter", "Anzahl Scrapes seit Start", {}, cs["scrapes"])
            add("vllm_monitor_collector_errors_total", "counter", "Anzahl Scrape-Fehler", {}, cs["errors"])
            add("vllm_monitor_collector_up", "gauge", "Collector-Heartbeat frisch (1) / veraltet (0)",
                {}, 1 if (now - cs["ts"]) <= max(3 * iv, 60) else 0)
        conn.close()

    text = []
    for name, e in out.items():
        text.append("# HELP %s %s" % (name, e["help"]))
        text.append("# TYPE %s %s" % (name, e["type"]))
        for labels, val in e["rows"]:
            if labels:
                ls = "{%s}" % ",".join('%s="%s"' % (k, _prom_esc(v)) for k, v in labels.items())
            else:
                ls = ""
            text.append("%s%s %s" % (name, ls, _prom_num(val)))
    return ("\n".join(text) + "\n").encode("utf-8")


# ---------------------------------------------------------------------------
# Auth-Store: lokale Nutzer + AD-Nutzer + LDAP-Config in auth.json
# ---------------------------------------------------------------------------

def _default_ldap_cfg():
    """Erst-Seed der LDAP-Config aus den Env-Variablen (nur beim allerersten
    Anlegen von auth.json; danach wird alles im Frontend gepflegt)."""
    host = os.environ.get("VLLM_LDAP_HOST", "").strip()
    return {
        "enabled": bool(host),
        "host": host,
        "domain": os.environ.get("VLLM_LDAP_DOMAIN", "").strip(),
        "port": int(os.environ.get("VLLM_LDAP_PORT", "389")),
        "port_tls": int(os.environ.get("VLLM_LDAP_PORT_TLS", "636")),
        "tls": os.environ.get("VLLM_LDAP_TLS", "auto").strip().lower(),
        "base_dn": os.environ.get("VLLM_LDAP_BASE_DN", "").strip(),
        "group_admin": "",
        "group_readonly": "",
        "default_role": "",   # "" = kein Zugriff ohne Gruppen-/Einzelfreigabe
    }


def _hash_pw(password, salt=None, iterations=PBKDF2_ITER):
    salt = salt or os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return {"salt": salt.hex(), "hash": dk.hex(), "iter": iterations}


def _verify_pw(rec, password):
    try:
        salt = bytes.fromhex(rec.get("salt", ""))
        it = int(rec.get("iter", PBKDF2_ITER))
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, it)
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(dk.hex(), rec.get("hash", ""))


def _default_auth():
    """Frische auth.json mit Default-Admin (admin/admin, Wechsel erzwungen)."""
    rec = _hash_pw("admin")
    rec.update({"username": "admin", "role": "admin", "must_change": True,
                "created": int(time.time())})
    return {"version": 1, "users": [rec], "ad_users": [], "ldap": _default_ldap_cfg()}


def load_auth():
    """Lädt auth.json (legt sie beim ersten Aufruf mit Default-Admin an)."""
    with _auth_file_lock:
        if not os.path.exists(AUTH_FILE):
            au = _default_auth()
            _write_auth(au)
            return au
        try:
            with open(AUTH_FILE, "r", encoding="utf-8") as f:
                au = json.load(f)
        except (ValueError, OSError):
            au = _default_auth()
            _write_auth(au)
            return au
    # fehlende Felder tolerant ergänzen
    au.setdefault("users", [])
    au.setdefault("ad_users", [])
    if "ldap" not in au or not isinstance(au["ldap"], dict):
        au["ldap"] = _default_ldap_cfg()
    else:
        base = _default_ldap_cfg()
        base.update(au["ldap"])
        au["ldap"] = base
    return au


def _write_auth(au):
    """Atomar schreiben (Datei enthält Passwort-Hashes -> 0600)."""
    tmp = AUTH_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(au, f, indent=2, ensure_ascii=False)
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, AUTH_FILE)


def save_auth(au):
    with _auth_file_lock:
        _write_auth(au)


def _find_local(au, username):
    u = (username or "").strip().lower()
    for rec in au.get("users", []):
        if rec.get("username", "").lower() == u:
            return rec
    return None


def _find_ad_user(au, username):
    short = (username or "").split("@")[0].split("\\")[-1].strip().lower()
    full = (username or "").strip().lower()
    for rec in au.get("ad_users", []):
        n = rec.get("username", "").strip().lower()
        if n and (n == short or n == full):
            return rec
    return None


def _pub_user(rec, source):
    """Für die Ausgabe ans Frontend – ohne Hash/Salt."""
    return {"username": rec.get("username", ""), "role": rec.get("role", "readonly"),
            "source": source, "must_change": bool(rec.get("must_change"))}


# ---------------------------------------------------------------------------
# LDAP-/AD-Authentifizierung (Simple Bind + memberOf-Suche, nur Standardbibliothek)
# ---------------------------------------------------------------------------

def _ber_len(n):
    if n < 0x80:
        return bytes([n])
    b = b""
    while n:
        b = bytes([n & 0xFF]) + b
        n >>= 8
    return bytes([0x80 | len(b)]) + b


def _ber_tlv(tag, value):
    return bytes([tag]) + _ber_len(len(value)) + value


def _ber_int(n):
    b = b""
    x = n
    while True:
        b = bytes([x & 0xFF]) + b
        x >>= 8
        if (x == 0 and not (b[0] & 0x80)) or (x == -1 and (b[0] & 0x80)):
            break
    return _ber_tlv(0x02, b)


def _recvn(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def _read_ldap_message(sock):
    tag = _recvn(sock, 1)
    if not tag:
        return None
    l0 = _recvn(sock, 1)[0]
    if l0 < 0x80:
        length = l0
    else:
        length = int.from_bytes(_recvn(sock, l0 & 0x7F), "big")
    return _recvn(sock, length)


def _parse_tlv(data, i=0):
    tag = data[i]; i += 1
    l0 = data[i]; i += 1
    if l0 < 0x80:
        length = l0
    else:
        nb = l0 & 0x7F
        length = int.from_bytes(data[i:i + nb], "big"); i += nb
    return tag, data[i:i + length], i + length


def _ldap_bind_result(body):
    # LDAPMessage: SEQUENCE { messageID INTEGER, [APPLICATION 1] BindResponse }
    _, _, i = _parse_tlv(body, 0)          # messageID überspringen
    _, op, _ = _parse_tlv(body, i)         # BindResponse
    _, rc, _ = _parse_tlv(op, 0)           # resultCode ENUMERATED
    return int.from_bytes(rc, "big")


def _ber_enum(n):
    return _ber_tlv(0x0A, bytes([n & 0xFF]))


def _ber_bool(b):
    return _ber_tlv(0x01, b"\xff" if b else b"\x00")


def _domain_to_base(domain):
    return ",".join("DC=%s" % p for p in (domain or "").split(".") if p)


def _ldap_connect(host, port, use_tls, timeout=6):
    raw = socket.create_connection((host, port), timeout=timeout)
    if use_tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx.wrap_socket(raw, server_hostname=None), raw
    return raw, raw


def _ldap_do_bind(sock, dn, password, msgid=1):
    # BindRequest [APPLICATION 0] { version=3, name=DN, [0] simple-password }
    bind = _ber_int(3) + _ber_tlv(0x04, dn.encode("utf-8")) + _ber_tlv(0x80, password.encode("utf-8"))
    sock.sendall(_ber_tlv(0x30, _ber_int(msgid) + _ber_tlv(0x60, bind)))
    body = _read_ldap_message(sock)
    if not body:
        return None
    return _ldap_bind_result(body)         # 0 = success, 49 = invalidCredentials, …


def _parse_entry_memberof(op):
    _, _obj, i = _parse_tlv(op, 0)          # objectName
    _, attrs, _ = _parse_tlv(op, i)         # PartialAttributeList SEQUENCE
    out, j = [], 0
    while j < len(attrs):
        _, attr, j = _parse_tlv(attrs, j)   # attribute SEQUENCE { type, vals SET }
        _, atype, k = _parse_tlv(attr, 0)
        if atype.decode("utf-8", "replace").lower() == "memberof":
            _, vset, _ = _parse_tlv(attr, k)
            m = 0
            while m < len(vset):
                _, vv, m = _parse_tlv(vset, m)
                out.append(vv.decode("utf-8", "replace"))
    return out


def _ldap_search_memberof(sock, base_dn, upn, msgid=2):
    """Sucht den Nutzer per (|(sAMAccountName=..)(userPrincipalName=..)) und
    liefert dessen memberOf-Gruppen (Liste von DNs)."""
    short = upn.split("@")[0].split("\\")[-1]
    f1 = _ber_tlv(0xA3, _ber_tlv(0x04, b"sAMAccountName") + _ber_tlv(0x04, short.encode("utf-8")))
    f2 = _ber_tlv(0xA3, _ber_tlv(0x04, b"userPrincipalName") + _ber_tlv(0x04, upn.encode("utf-8")))
    filt = _ber_tlv(0xA1, f1 + f2)          # or [1]
    req = (_ber_tlv(0x04, base_dn.encode("utf-8")) +
           _ber_enum(2) + _ber_enum(0) +    # scope=wholeSubtree, deref=never
           _ber_int(5) + _ber_int(10) + _ber_bool(False) +
           filt + _ber_tlv(0x30, _ber_tlv(0x04, b"memberOf")))
    sock.sendall(_ber_tlv(0x30, _ber_int(msgid) + _ber_tlv(0x63, req)))
    groups = []
    for _ in range(500):
        body = _read_ldap_message(sock)
        if not body:
            break
        _, _, i = _parse_tlv(body, 0)       # messageID
        optag = body[i]
        _, op, _ = _parse_tlv(body, i)
        if optag == 0x64:                   # SearchResultEntry
            groups += _parse_entry_memberof(op)
        else:                               # SearchResultDone (0x65) o. a. -> Ende
            break
    return groups


# --- Verzeichnissuche (Benutzer/Gruppen im AD durchsuchen) ---

def _ldap_escape(s):
    out = []
    for ch in (s or ""):
        if ch in "\\*()\0":
            out.append("\\%02x" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


def _f_eq(attr, val):
    return _ber_tlv(0xA3, _ber_tlv(0x04, attr.encode("utf-8")) + _ber_tlv(0x04, val.encode("utf-8")))


def _f_sub(attr, val):     # substrings: (attr=*val*)  -> ein 'any'-Element [1]
    return _ber_tlv(0xA4, _ber_tlv(0x04, attr.encode("utf-8")) +
                    _ber_tlv(0x30, _ber_tlv(0x81, val.encode("utf-8"))))


def _f_or(*subs):
    return _ber_tlv(0xA1, b"".join(subs))


def _f_and(*subs):
    return _ber_tlv(0xA0, b"".join(subs))


def _parse_entry_attrs(op):
    _, objname, i = _parse_tlv(op, 0)       # objectName (DN)
    d = {"dn": [objname.decode("utf-8", "replace")]}
    _, attrs, _ = _parse_tlv(op, i)
    j = 0
    while j < len(attrs):
        _, attr, j = _parse_tlv(attrs, j)
        _, atype, k = _parse_tlv(attr, 0)
        name = atype.decode("utf-8", "replace").lower()
        _, vset, _ = _parse_tlv(attr, k)
        vals, m = [], 0
        while m < len(vset):
            _, vv, m = _parse_tlv(vset, m)
            vals.append(vv.decode("utf-8", "replace"))
        d[name] = vals
    return d


def _ldap_search(sock, base, filt, attrs, sizelimit=25, msgid=2):
    aseq = _ber_tlv(0x30, b"".join(_ber_tlv(0x04, a.encode("utf-8")) for a in attrs))
    req = (_ber_tlv(0x04, base.encode("utf-8")) + _ber_enum(2) + _ber_enum(0) +
           _ber_int(sizelimit) + _ber_int(15) + _ber_bool(False) + filt + aseq)
    sock.sendall(_ber_tlv(0x30, _ber_int(msgid) + _ber_tlv(0x63, req)))
    out = []
    for _ in range(2000):
        body = _read_ldap_message(sock)
        if not body:
            break
        _, _, i = _parse_tlv(body, 0)
        optag = body[i]
        _, op, _ = _parse_tlv(body, i)
        if optag == 0x64:                   # SearchResultEntry
            out.append(_parse_entry_attrs(op))
        elif optag == 0x65:                 # SearchResultDone
            break
        # 0x73 = SearchResultReference u. a. überspringen
    return out


def ldap_directory_search(cfg, kind, q, user, password, limit=25):
    """Durchsucht das AD nach Benutzern oder Gruppen (Substring). Bindet mit den
    übergebenen Anmeldedaten (kein gespeichertes Dienstkonto)."""
    q = (q or "").strip()
    if not cfg.get("host"):
        return {"error": "Kein LDAP-Host konfiguriert."}
    if not user or not password:
        return {"error": "Für die Suche Test-Benutzer/-Passwort angeben."}
    if not q:
        return {"error": "Suchbegriff angeben."}
    domain = (cfg.get("domain") or "").strip()

    def _dn(u):
        return u if ("@" in u or "\\" in u or "=" in u) else ("%s@%s" % (u, domain) if domain else u)

    base = (cfg.get("base_dn") or "").strip() or _domain_to_base(domain)
    if not base:
        return {"error": "Basis-DN bzw. Domäne fehlt."}
    qe = _ldap_escape(q)
    if kind == "group":
        filt = _f_and(_f_eq("objectClass", "group"),
                      _f_or(_f_sub("cn", qe), _f_sub("sAMAccountName", qe)))
        attrs = ["cn", "distinguishedName", "sAMAccountName"]
    else:
        filt = _f_and(_f_eq("objectClass", "user"), _f_eq("objectCategory", "person"),
                      _f_or(_f_sub("sAMAccountName", qe), _f_sub("displayName", qe),
                            _f_sub("userPrincipalName", qe)))
        attrs = ["sAMAccountName", "displayName", "userPrincipalName", "distinguishedName"]
    tls = (cfg.get("tls") or "auto").lower()
    port = int(cfg.get("port", 389)); port_tls = int(cfg.get("port_tls", 636))
    if tls in ("1", "require", "yes", "on", "ldaps"):
        attempts = [(True, port_tls)]
    elif tls in ("0", "off", "no", "none"):
        attempts = [(False, port)]
    else:
        attempts = [(True, port_tls), (False, port)]
    for use_tls, p in attempts:
        sock = raw = None
        try:
            sock, raw = _ldap_connect(cfg["host"], p, use_tls)
            rc = _ldap_do_bind(sock, _dn(user), password)
            if rc is None:
                continue
            if rc != 0:
                return {"error": "Bind fehlgeschlagen (Anmeldedaten prüfen)."}
            entries = _ldap_search(sock, base, filt, attrs, limit)
            res = []
            for e in entries:
                if kind == "group":
                    cn = (e.get("cn") or [""])[0]
                    dn = (e.get("distinguishedname") or e.get("dn") or [""])[0]
                    if cn or dn:
                        res.append({"name": cn or dn, "dn": dn})
                else:
                    sam = (e.get("samaccountname") or [""])[0]
                    if sam:
                        res.append({"name": sam,
                                    "display": (e.get("displayname") or [""])[0],
                                    "upn": (e.get("userprincipalname") or [""])[0]})
            return {"ok": True, "results": res}
        except Exception:
            continue
        finally:
            for s in (sock, raw):
                if s:
                    try:
                        s.close()
                    except OSError:
                        pass
    return {"error": "Verbindung zum Domain-Controller fehlgeschlagen."}


def ldap_search_api(body):
    if not isinstance(body, dict):
        return {"error": "ungültige Anfrage"}
    au = load_auth()
    ld = dict(au["ldap"])
    for k in ("host", "domain", "base_dn", "tls"):
        if k in body and body[k] is not None:
            ld[k] = str(body[k]).strip()
    for k in ("port", "port_tls"):
        if k in body:
            try:
                ld[k] = int(body[k])
            except (ValueError, TypeError):
                pass
    return ldap_directory_search(ld, body.get("kind", "user"), body.get("q", ""),
                                 (body.get("username") or "").strip(), body.get("password") or "")


def ldap_login(cfg, username, password):
    """Simple Bind gegen den DC; bei Erfolg optional memberOf-Gruppen holen.
    Gibt (ok, groups) zurück. Leeres Passwort wird abgelehnt."""
    username = (username or "").strip()
    if not (cfg.get("enabled") and cfg.get("host")) or not username or not password:
        return False, []
    domain = (cfg.get("domain") or "").strip()
    if "@" in username or "\\" in username:
        dn = username
    elif domain:
        dn = "%s@%s" % (username, domain)
    else:
        dn = username
    base = (cfg.get("base_dn") or "").strip() or _domain_to_base(domain)
    tls = (cfg.get("tls") or "auto").lower()
    port = int(cfg.get("port", 389)); port_tls = int(cfg.get("port_tls", 636))
    if tls in ("1", "require", "yes", "on", "ldaps"):
        attempts = [(True, port_tls)]
    elif tls in ("0", "off", "no", "none"):
        attempts = [(False, port)]
    else:                                   # auto: erst LDAPS, dann Klartext
        attempts = [(True, port_tls), (False, port)]
    need_groups = bool(cfg.get("group_admin") or cfg.get("group_readonly"))
    for use_tls, p in attempts:
        sock = raw = None
        try:
            sock, raw = _ldap_connect(cfg["host"], p, use_tls)
            rc = _ldap_do_bind(sock, dn, password)
            if rc is None:
                continue
            if rc != 0:
                return False, []
            groups = []
            if need_groups and base:
                try:
                    groups = _ldap_search_memberof(sock, base, dn)
                except Exception:
                    groups = []
            return True, groups
        except Exception:
            continue
        finally:
            for s in (sock, raw):
                if s:
                    try:
                        s.close()
                    except OSError:
                        pass
    return False, []


def _group_match(configured, member_dns):
    c = (configured or "").strip().lower()
    if not c:
        return False
    for dn in member_dns:
        d = dn.strip().lower()
        if d == c:
            return True
        first = d.split(",")[0]             # z. B. "cn=vllm-admins"
        if first.startswith("cn=") and first[3:] == c:
            return True
    return False


def resolve_ad_role(au, username, groups):
    """Rolle eines AD-Nutzers: expliziter Eintrag > Gruppen-Mapping > default_role."""
    ad = _find_ad_user(au, username)
    if ad:
        return ad.get("role", "readonly")
    ld = au.get("ldap", {})
    if _group_match(ld.get("group_admin", ""), groups):
        return "admin"
    if _group_match(ld.get("group_readonly", ""), groups):
        return "readonly"
    dr = (ld.get("default_role") or "").strip()
    return dr if dr in ROLES else None


def resolve_login(username, password):
    """Prüft Anmeldedaten gegen lokale Nutzer, sonst gegen LDAP/AD.
    Gibt userdict {username, role, source, must_change} oder None zurück."""
    username = (username or "").strip()
    if not username or not password:
        return None
    au = load_auth()
    lu = _find_local(au, username)
    if lu:
        if _verify_pw(lu, password):
            return {"username": lu["username"], "role": lu.get("role", "admin"),
                    "source": "local", "must_change": bool(lu.get("must_change"))}
        return None            # lokaler Nutzer, falsches Passwort -> nicht via LDAP probieren
    ld = au.get("ldap", {})
    if ld.get("enabled") and ld.get("host"):
        ok, groups = ldap_login(ld, username, password)
        if ok:
            role = resolve_ad_role(au, username, groups)
            if role:
                short = username.split("@")[0].split("\\")[-1]
                return {"username": short, "role": role, "source": "ad", "must_change": False}
    return None


def _basic_login(header):
    """Basic-Auth-Header -> userdict (für Scraper/CLI wie Prometheus), mit Cache."""
    if not header or not header.startswith("Basic "):
        return None
    try:
        user, _, pw = base64.b64decode(header[6:]).decode("utf-8", "replace").partition(":")
    except Exception:
        return None
    if not user or not pw:
        return None
    key = hashlib.sha256(("%s\0%s" % (user, pw)).encode("utf-8")).hexdigest()
    now = time.time()
    with _auth_lock:
        ent = _auth_cache.get(key)
        if ent and ent[0] > now:
            return ent[1]
    ud = resolve_login(user, pw)
    if ud:
        with _auth_lock:
            _auth_cache[key] = (now + AUTH_TTL, ud)
            for k, e in list(_auth_cache.items()):
                if e[0] <= now:
                    _auth_cache.pop(k, None)
    return ud


# ---------------------------------------------------------------------------
# Verwaltungs-Endpunkte (nur Admins): Nutzer + LDAP-Konfiguration
# ---------------------------------------------------------------------------

def build_users():
    au = load_auth()
    users = [{"username": u["username"], "role": u.get("role", "admin"),
              "must_change": bool(u.get("must_change"))} for u in au.get("users", [])]
    return {"users": users, "ad_users": au.get("ad_users", []), "ldap": au.get("ldap", {})}


def users_upsert(body):
    if not isinstance(body, dict):
        return {"error": "ungültige Anfrage"}
    kind = body.get("kind", "local")
    username = (body.get("username") or "").strip()
    role = body.get("role", "readonly")
    if not username:
        return {"error": "Benutzername fehlt"}
    if role not in ROLES:
        return {"error": "ungültige Rolle"}
    au = load_auth()
    if kind == "ad":
        short = username.split("@")[0].split("\\")[-1].strip()
        ex = _find_ad_user(au, short)
        if ex:
            ex["role"] = role
            ex["username"] = short
        else:
            au["ad_users"].append({"username": short, "role": role})
        save_auth(au)
        return {"ok": True}
    # lokaler Nutzer
    pw = body.get("password")
    lu = _find_local(au, username)
    if lu:
        lu["role"] = role
        if pw:
            lu.update(_hash_pw(pw))
            lu["must_change"] = bool(body.get("must_change", False))
        save_auth(au)
        return {"ok": True}
    if not pw:
        return {"error": "Passwort für neuen lokalen Nutzer erforderlich"}
    rec = _hash_pw(pw)
    rec.update({"username": username, "role": role,
                "must_change": bool(body.get("must_change", False)),
                "created": int(time.time())})
    au["users"].append(rec)
    save_auth(au)
    return {"ok": True}


def users_delete(username, kind="local"):
    au = load_auth()
    username = (username or "").strip()
    if kind == "ad":
        short = username.split("@")[0].split("\\")[-1].lower()
        before = len(au["ad_users"])
        au["ad_users"] = [u for u in au["ad_users"] if u.get("username", "").lower() != short]
        save_auth(au)
        return {"ok": before != len(au["ad_users"])}
    lu = _find_local(au, username)
    if not lu:
        return {"error": "unbekannter Nutzer"}
    admins = [u for u in au["users"] if u.get("role") == "admin"]
    if lu.get("role") == "admin" and len(admins) <= 1:
        return {"error": "Der letzte Admin kann nicht gelöscht werden."}
    au["users"] = [u for u in au["users"] if u.get("username", "").lower() != username.lower()]
    save_auth(au)
    return {"ok": True}


def ldap_update(body):
    if not isinstance(body, dict):
        return {"error": "ungültige Anfrage"}
    au = load_auth()
    ld = au["ldap"]
    for k in ("host", "domain", "base_dn", "group_admin", "group_readonly"):
        if k in body:
            ld[k] = (body.get(k) or "").strip()
    if "tls" in body:
        ld["tls"] = (body.get("tls") or "auto").strip().lower()
    if "enabled" in body:
        ld["enabled"] = bool(body["enabled"])
    for k in ("port", "port_tls"):
        if k in body:
            try:
                ld[k] = int(body[k])
            except (ValueError, TypeError):
                pass
    if "default_role" in body:
        dr = (body.get("default_role") or "").strip()
        ld["default_role"] = dr if dr in ROLES else ""
    save_auth(au)
    return {"ok": True, "ldap": ld}


def ldap_test(body):
    """Test-Bind mit übergebenen Zugangsdaten (Formularwerte überschreiben die
    gespeicherte Config, damit man vor dem Speichern prüfen kann)."""
    if not isinstance(body, dict):
        return {"error": "ungültige Anfrage"}
    au = load_auth()
    ld = dict(au["ldap"])
    for k in ("host", "domain", "base_dn", "tls", "group_admin", "group_readonly"):
        if k in body and body[k] is not None:
            ld[k] = str(body[k]).strip()
    for k in ("port", "port_tls"):
        if k in body:
            try:
                ld[k] = int(body[k])
            except (ValueError, TypeError):
                pass
    ld["enabled"] = True
    user = (body.get("username") or "").strip()
    pw = body.get("password") or ""
    if not user or not pw:
        return {"error": "Test-Benutzer und -Passwort angeben."}
    try:
        ok, groups = ldap_login(ld, user, pw)
    except Exception as e:
        return {"ok": False, "error": str(e)}
    if not ok:
        return {"ok": False, "error": "Bind fehlgeschlagen (Host/Port/Benutzer/Passwort prüfen)."}
    role = resolve_ad_role(au, user, groups)
    return {"ok": True, "groups": groups,
            "role": role or "(keine Rolle – Gruppen-Mapping oder Einzelfreigabe fehlt)"}


def _cookie_sign(payload):
    return hmac.new(AUTH_SECRET, payload.encode("utf-8"), hashlib.sha256).hexdigest()


def _make_cookie_value(user, role="admin", source="local"):
    exp = int(time.time()) + AUTH_COOKIE_DAYS * 86400
    b64u = base64.urlsafe_b64encode(user.encode("utf-8")).decode("ascii")
    payload = "%s|%s|%s|%d" % (b64u, role, source, exp)
    return "%s|%s" % (payload, _cookie_sign(payload))


def _check_cookie_value(val):
    """Gibt dict {user, role, source, exp} zurück, wenn Signatur gültig & aktuell."""
    try:
        b64u, role, source, exp_s, sig = val.rsplit("|", 4)
    except ValueError:
        return None
    if not hmac.compare_digest(sig, _cookie_sign("%s|%s|%s|%s" % (b64u, role, source, exp_s))):
        return None
    try:
        exp = int(exp_s)
    except ValueError:
        return None
    if exp < time.time():
        return None
    try:
        user = base64.urlsafe_b64decode(b64u.encode("ascii")).decode("utf-8")
    except Exception:
        return None
    return {"user": user, "role": role, "source": source, "exp": exp}


# ---------------------------------------------------------------------------
# HTTP-Handler
# ---------------------------------------------------------------------------

def _range_from(qs):
    try:
        r = int(qs.get("range", ["3600"])[0])
    except ValueError:
        r = 3600
    return max(60, min(r, 30 * 86400))


def _abs_window(qs):
    """Optionales absolutes Zeitfenster (from/to in Sekunden). Gibt (from, to)
    zurück oder (None, None), wenn nicht/ungültig angegeben. Deckelt auf 30 Tage."""
    if "from" not in qs or "to" not in qs:
        return None, None
    try:
        fr = int(qs["from"][0])
        to = int(qs["to"][0])
    except (ValueError, KeyError, IndexError):
        return None, None
    if to <= fr:
        return None, None
    if to - fr > 30 * 86400:
        fr = to - 30 * 86400
    return fr, to


def _normalize_ai_url(u):
    """Macht die Endpunkt-Angabe tolerant: akzeptiert host:port, .../v1 oder die
    volle .../v1/chat/completions-URL und ergänzt den fehlenden Pfad."""
    u = (u or "").strip().rstrip("/")
    if not u:
        return u
    if "://" not in u:
        u = "http://" + u
    low = u.lower()
    if low.endswith("/chat/completions"):
        return u
    if low.endswith("/v1"):
        return u + "/chat/completions"
    return u + "/v1/chat/completions"


def ai_analyze(body):
    """Leitet eine Analyse-Anfrage an einen OpenAI-kompatiblen Chat-Endpunkt
    (z. B. das überwachte vLLM) weiter. Request-Body überschreibt die Defaults."""
    url = _normalize_ai_url(body.get("url") or AI_URL or "")
    model = (body.get("model") or AI_MODEL or "").strip()
    key = (body.get("key") or AI_KEY or "").strip()
    system = body.get("system") or (
        "Du bist ein erfahrener Monitoring-Analyst für LLM-Server (vLLM). "
        "Antworte knapp, sachlich und auf Deutsch.")
    user = body.get("user") or ""
    if not url:
        return {"error": "Kein KI-Endpunkt konfiguriert. Bitte im ⚙-Menü unter "
                         "'KI-Auswertung' einen /v1/chat/completions-Endpunkt eintragen."}
    if not model:
        return {"error": "Kein KI-Modell konfiguriert (⚙-Menü → KI-Auswertung)."}
    try:
        max_tokens = int(body.get("max_tokens") or AI_MAX_TOKENS)
    except (ValueError, TypeError):
        max_tokens = AI_MAX_TOKENS
    req_obj = {
        "model": model,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "temperature": 0.3,
        "max_tokens": max_tokens,
        "stream": False,
    }
    no_think = body.get("no_think")
    if no_think is None:
        no_think = AI_NO_THINK
    if no_think:
        # Qwen3 & Co.: Denk-Phase im Chat-Template abschalten -> direkte Antwort
        req_obj["chat_template_kwargs"] = {"enable_thinking": False}
    payload = json.dumps(req_obj).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urlrequest.Request(url, data=payload, headers=headers, method="POST")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urlrequest.urlopen(req, timeout=AI_TIMEOUT, context=ctx) as r:
            data = json.loads(r.read().decode("utf-8"))
    except urlerror.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8")[:300]
        except Exception:
            pass
        return {"error": "KI-Endpunkt HTTP %s%s" % (e.code, (": " + detail) if detail else "")}
    except Exception as e:
        return {"error": "KI-Endpunkt nicht erreichbar: %s" % e}
    try:
        msg = data["choices"][0]["message"]
        text = (msg.get("content") or "").strip()
        # Reasoning-Modelle (z. B. Qwen3) legen die Antwort ggf. nur ins Denk-Feld,
        # wenn das Token-Budget vorher aufgebraucht wurde -> als Fallback nutzen.
        if not text:
            text = (msg.get("reasoning") or msg.get("reasoning_content") or "").strip()
        finish = data["choices"][0].get("finish_reason")
    except (KeyError, IndexError, TypeError):
        text, finish = "", None
    if not text and finish == "length":
        return {"error": "KI-Antwort abgeschnitten (Token-Budget erschöpft). "
                         "Im ⚙-Menü ggf. ein Modell ohne langes Reasoning wählen oder "
                         "VLLM_AI_MAX_TOKENS erhöhen."}
    return {"text": text, "model": model}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _get_cookie(self, name):
        for part in (self.headers.get("Cookie", "") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == name:
                return v
        return None

    def _set_auth_cookie(self, user, role, source):
        self._auth_cookie = _make_cookie_value(user, role, source)

    def _clear_auth_cookie(self):
        self._auth_cookie = ""              # leerer Wert -> _send löscht das Cookie

    def _is_admin(self):
        return bool(self._user and self._user.get("role") == "admin")

    def _forbidden(self):
        self._send(403, "application/json",
                   json.dumps({"error": "Keine Berechtigung"}).encode("utf-8"))

    def _must_change(self):
        u = getattr(self, "_user", None)
        if not u or u.get("source") != "local":
            return False
        lu = _find_local(load_auth(), u["username"])
        return bool(lu and lu.get("must_change"))

    def _auth_state(self):
        """Anmeldestatus für /api/me – ohne 401 auszulösen."""
        au = load_auth()
        ldap_on = bool(au.get("ldap", {}).get("enabled"))
        cval = self._get_cookie(AUTH_COOKIE)
        if cval:
            chk = _check_cookie_value(cval)
            if chk:
                mc = False
                if chk["source"] == "local":
                    lu = _find_local(au, chk["user"])
                    mc = bool(lu and lu.get("must_change"))
                return {"authenticated": True, "username": chk["user"], "role": chk["role"],
                        "source": chk["source"], "must_change": mc, "ldap_enabled": ldap_on}
        return {"authenticated": False, "ldap_enabled": ldap_on}

    def _require_auth(self):
        """Setzt self._user aus gültigem Session-Cookie oder Basic-Auth (Scraper).
        Ohne gültige Anmeldung: 401 als JSON (kein Basic-Popup – Login-Formular im UI)."""
        self._user = None
        now = time.time()
        cval = self._get_cookie(AUTH_COOKIE)
        if cval:
            chk = _check_cookie_value(cval)
            if chk:
                self._user = {"username": chk["user"], "role": chk["role"], "source": chk["source"]}
                if chk["exp"] - now < AUTH_COOKIE_DAYS * 86400 / 2:   # gleitend verlängern
                    self._set_auth_cookie(chk["user"], chk["role"], chk["source"])
                return True
        ud = _basic_login(self.headers.get("Authorization"))
        if ud:
            self._user = {"username": ud["username"], "role": ud["role"], "source": ud["source"]}
            return True
        self._send(401, "application/json",
                   json.dumps({"error": "Anmeldung erforderlich"}).encode("utf-8"))
        return False

    def _handle_login(self):
        body = self._read_body() or {}
        ud = resolve_login(body.get("username", ""), body.get("password", ""))
        if not ud:
            self._send(401, "application/json",
                       json.dumps({"error": "Anmeldung fehlgeschlagen"}).encode("utf-8"))
            return
        self._set_auth_cookie(ud["username"], ud["role"], ud["source"])
        self._json({"ok": True, "username": ud["username"], "role": ud["role"],
                    "source": ud["source"], "must_change": ud["must_change"]})

    def _handle_password(self):
        u = getattr(self, "_user", None)
        if not u or u.get("source") != "local":
            self._forbidden()
            return
        body = self._read_body() or {}
        newpw = body.get("new") or ""
        if len(newpw) < 6:
            self._json({"error": "Neues Passwort muss mindestens 6 Zeichen haben."})
            return
        au = load_auth()
        lu = _find_local(au, u["username"])
        if not lu or not _verify_pw(lu, body.get("old") or ""):
            self._json({"error": "Aktuelles Passwort ist falsch."})
            return
        lu.update(_hash_pw(newpw))
        lu["must_change"] = False
        save_auth(au)
        self._set_auth_cookie(u["username"], lu.get("role", "admin"), "local")
        self._json({"ok": True})

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        # Öffentliche Routen (ohne Anmeldung erreichbar)
        if parsed.path in ("/", "/index.html"):
            sub = ("– " + html.escape(LABEL)) if LABEL else ""
            page = (PAGE.replace("__SUBTITLE__", sub)
                        .replace("__VERSION__", __version__)
                        .replace("__TLSAVAIL__", "1" if CERT_PATH else "0"))
            self._send(200, "text/html; charset=utf-8", page.encode("utf-8"))
            return
        if parsed.path == "/api/me":
            self._json(self._auth_state())
            return
        if not self._require_auth():
            return
        if parsed.path == "/api/users":
            if not self._is_admin():
                self._forbidden()
                return
            self._json(build_users())
            return
        if parsed.path == "/api/series":
            try:
                off = int(qs.get("offset", ["0"])[0])
            except ValueError:
                off = 0
            off = max(0, min(off, 30 * 86400))
            fr, to = _abs_window(qs)
            if fr is not None:
                self._json(build_series(to - fr, off, start=fr, end=to))
            else:
                self._json(build_series(_range_from(qs), off))
        elif parsed.path == "/api/config":
            self._json(build_config())
        elif parsed.path == "/api/alerts":
            try:
                lim = int(qs.get("limit", ["100"])[0])
            except ValueError:
                lim = 100
            self._json(build_alerts(min(max(lim, 1), 500)))
        elif parsed.path == "/api/annotations":
            fr, to = _abs_window(qs)
            if fr is not None:
                self._json(build_annotations(start=fr, end=to))
            else:
                rng = _range_from(qs) if "range" in qs else None
                self._json(build_annotations(rng))
        elif parsed.path == "/api/targets":
            self._json(build_targets())
        elif parsed.path == "/metrics":
            self._send(200, "text/plain; version=0.0.4; charset=utf-8", build_prometheus())
        elif parsed.path == "/api/stream":
            self._stream(_range_from(qs))
        elif parsed.path == "/api/cert":
            self._send_cert()
        else:
            self._send(404, "text/plain", b"not found")

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n > 0 else b"{}"
            return json.loads(raw.decode("utf-8") or "{}")
        except (ValueError, OSError):
            return None

    def do_POST(self):
        parsed = urlparse(self.path)
        # öffentlich: Anmeldung
        if parsed.path == "/api/login":
            self._handle_login()
            return
        if not self._require_auth():
            return
        # jeder angemeldete Nutzer: eigenes Passwort ändern, abmelden
        if parsed.path == "/api/logout":
            self._clear_auth_cookie()
            self._json({"ok": True})
            return
        if parsed.path == "/api/password":
            self._handle_password()
            return
        # solange Passwortwechsel erzwungen ist: nichts anderes zulassen
        if self._must_change():
            self._send(403, "application/json",
                       json.dumps({"error": "Passwortwechsel erforderlich"}).encode("utf-8"))
            return
        if parsed.path == "/api/analyze":            # Auswertung (auch read-only)
            body = self._read_body()
            if body is None:
                self._json({"error": "ungültige Anfrage"})
                return
            self._json(ai_analyze(body))
            return
        # ab hier: nur Admins (schreibende/verwaltende Endpunkte)
        if not self._is_admin():
            self._forbidden()
            return
        if parsed.path == "/api/users":
            body = self._read_body()
            if body is None:
                self._json({"error": "ungültige Anfrage"})
                return
            self._json(users_upsert(body))
        elif parsed.path == "/api/ldap":
            body = self._read_body()
            if body is None:
                self._json({"error": "ungültige Anfrage"})
                return
            self._json(ldap_update(body))
        elif parsed.path == "/api/ldap/test":
            body = self._read_body()
            if body is None:
                self._json({"error": "ungültige Anfrage"})
                return
            self._json(ldap_test(body))
        elif parsed.path == "/api/ldap/search":
            body = self._read_body()
            if body is None:
                self._json({"error": "ungültige Anfrage"})
                return
            self._json(ldap_search_api(body))
        elif parsed.path == "/api/thresholds":
            body = self._read_body()
            if body is None:
                self._json({"error": "ungültige Anfrage"})
                return
            self._json(save_thresholds(body))
        elif parsed.path == "/api/annotations":
            body = self._read_body()
            if body is None:
                self._json({"error": "ungültige Anfrage"})
                return
            ts = body.get("ts")
            if ts:                       # Frontend liefert ms -> Sekunden
                try:
                    ts = int(ts) // 1000
                except (ValueError, TypeError):
                    ts = None
            self._json(add_annotation(ts, body.get("label", "")))
        elif parsed.path == "/api/targets":
            body = self._read_body()
            if body is None:
                self._json({"error": "ungültige Anfrage"})
                return
            self._json(add_target(body))
        else:
            self._send(404, "text/plain", b"not found")

    def do_DELETE(self):
        if not self._require_auth():
            return
        if self._must_change():
            self._send(403, "application/json",
                       json.dumps({"error": "Passwortwechsel erforderlich"}).encode("utf-8"))
            return
        if not self._is_admin():
            self._forbidden()
            return
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        if parsed.path == "/api/annotations" and "id" in qs:
            try:
                self._json(del_annotation(int(qs["id"][0])))
            except ValueError:
                self._json({"error": "ungültige id"})
        elif parsed.path == "/api/targets" and "id" in qs:
            self._json(del_target(qs["id"][0]))
        elif parsed.path == "/api/users" and "username" in qs:
            self._json(users_delete(qs["username"][0], qs.get("kind", ["local"])[0]))
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
        ck = getattr(self, "_auth_cookie", None)
        if ck is not None:
            secure = "; Secure" if CERT_PATH else ""
            if ck == "":                     # Logout -> Cookie sofort löschen
                self.send_header("Set-Cookie", "%s=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax%s"
                                 % (AUTH_COOKIE, secure))
            else:
                self.send_header("Set-Cookie", "%s=%s; Max-Age=%d; Path=/; HttpOnly; SameSite=Lax%s"
                                 % (AUTH_COOKIE, ck, AUTH_COOKIE_DAYS * 86400, secure))
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
<title>KI Monitor</title>
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
         display:flex;align-items:center;gap:12px;flex-wrap:wrap;position:sticky;top:0;z-index:2100;}
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
  .kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px;padding:6px 0 2px;}
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
  .cbtn.analyze:hover{color:var(--accent);border-color:var(--accent);}
  /* Analyse-Overlay */
  #analysis{position:fixed;inset:0;z-index:3000;display:none;background:rgba(0,0,0,.6);
    padding:24px;overflow:auto;}
  #analysis.open{display:flex;align-items:flex-start;justify-content:center;}
  .anbox{background:var(--panel);border:1px solid var(--border);border-radius:12px;
    width:min(760px,100%);box-shadow:0 20px 60px rgba(0,0,0,.6);}
  .anhead{display:flex;align-items:center;gap:10px;padding:14px 16px;border-bottom:1px solid var(--border);}
  .anhead h3{margin:0;font-size:15px;flex:1;}
  .anbody{padding:14px 16px;}
  .anbody h4{margin:0 0 8px;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);}
  .antab{width:100%;border-collapse:collapse;font-size:12px;margin-bottom:14px;}
  .antab th,.antab td{text-align:right;padding:4px 8px;border-bottom:1px solid var(--grid);white-space:nowrap;}
  .antab th:first-child,.antab td:first-child{text-align:left;}
  .antab td .sw{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;vertical-align:middle;}
  .aiout{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:12px 14px;
    font-size:13px;line-height:1.5;white-space:pre-wrap;min-height:40px;color:var(--fg);}
  .aimeta{font-size:11px;color:var(--muted);margin-top:6px;}
  .anfoot{display:flex;gap:8px;align-items:center;padding:0 16px 16px;}
  .abtn{background:var(--accent);color:#fff;border:none;border-radius:7px;padding:7px 14px;
    font-size:13px;cursor:pointer;font-weight:600;}
  .abtn:disabled{opacity:.5;cursor:default;}
  .abtn.sec{background:var(--panel);color:var(--fg);border:1px solid var(--border);font-weight:400;}
  .hidden-card{display:none !important;}
  #kpicard.collapsed #kpis{display:none;}
  #chartcard.collapsed #charts,#chartcard.collapsed #legend{display:none;}
  .chart-h2{display:flex;align-items:center;gap:14px;flex-wrap:wrap;}
  #chartcard .grid{padding:8px 0 2px;}
  #chartcard #legend{padding:8px 0 0;}
  #instcard.collapsed #insttable{display:none;}
  #alertcard.collapsed #alerttable{display:none;}
  #effcard.collapsed #effbody{display:none!important;}
  .ev-raised{color:var(--bad);} .ev-cleared{color:var(--ok);}
  .ev-crit{font-weight:600;}
  .evbadge{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;border:1px solid var(--border);}
  .activebtn{border-color:var(--accent)!important;color:var(--accent)!important;}
  canvas{max-height:var(--card-h);}
  /* Dedizierter Zieh-Griff (links) – nur hierüber wird verschoben/umgeordnet */
  .grip,.sgrip{cursor:grab;user-select:none;touch-action:none;flex:0 0 auto;
    color:var(--muted);font-size:13px;line-height:1;padding:2px 5px;border-radius:4px;
    margin-right:6px;display:inline-flex;align-items:center;}
  .grip:hover,.sgrip:hover{color:var(--fg);background:rgba(88,166,255,.15);}
  .grip:active,.sgrip:active{cursor:grabbing;}
  .kpi h3,.card h2.chart-h2{align-items:center;}
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
  /* --- Auth: Login-/Passwort-Overlay --- */
  #authov{position:fixed;inset:0;background:var(--bg);z-index:5000;display:none;
    align-items:center;justify-content:center;padding:20px;}
  #authov.show{display:flex;}
  .auth-card{background:var(--panel);border:1px solid var(--border);border-radius:12px;
    width:100%;max-width:360px;padding:26px 24px;color:var(--fg);box-shadow:0 8px 40px rgba(0,0,0,.5);}
  .auth-card h2{margin:0 0 4px;font-size:20px;}
  .auth-card .sub{color:var(--muted);font-size:13px;margin:0 0 18px;}
  .auth-card label{display:block;font-size:12px;color:var(--muted);margin:12px 0 4px;}
  .auth-card input{width:100%;box-sizing:border-box;background:var(--bg);color:var(--fg);
    border:1px solid var(--border);border-radius:7px;padding:9px 11px;font-size:14px;}
  .auth-card button.primary{width:100%;margin-top:18px;background:var(--accent);color:#fff;border:none;
    border-radius:8px;padding:10px;font-size:14px;cursor:pointer;}
  .auth-msg{min-height:18px;margin-top:12px;font-size:13px;color:var(--bad);}
  #logoutbtn{color:var(--muted);display:inline-flex;align-items:center;justify-content:center;padding:5px 8px;}
  #logoutbtn svg{width:18px;height:18px;display:block;}
  #logoutbtn:hover{color:var(--bad);border-color:var(--bad);}
  #gear{color:var(--muted);display:inline-flex;align-items:center;justify-content:center;padding:5px 8px;}
  #gear svg{width:18px;height:18px;display:block;}
  #gear:hover{color:var(--fg);}
  #theme{color:var(--muted);display:inline-flex;align-items:center;justify-content:center;padding:5px 8px;}
  #theme svg{width:18px;height:18px;display:block;}
  #theme:hover{color:var(--fg);}
  #theme .ic-sun{display:none;}
  body[data-theme="light"] #theme .ic-moon{display:none;}
  body[data-theme="light"] #theme .ic-sun{display:block;}
  #reload{font-size:20px;line-height:1;padding:2px 8px;}
  .userchip{font-size:12px;color:var(--muted);display:inline-flex;align-items:center;gap:6px;}
  .rolebadge{font-size:10px;text-transform:uppercase;letter-spacing:.04em;padding:1px 6px;border-radius:8px;
    border:1px solid var(--border);color:var(--muted);}
  .rolebadge.admin{color:var(--accent);border-color:var(--accent);}
  /* Schreib-/Admin-Controls für read-only ausblenden */
  body:not(.is-admin) .adminonly{display:none !important;}
  .utable{width:100%;border-collapse:collapse;font-size:13px;margin:4px 0;}
  .utable th,.utable td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--grid);}
  .utable th{color:var(--muted);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.03em;}
  .uinput{background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:5px;padding:4px 6px;font-size:13px;}
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
  <h1>KI Monitor</h1>
  <label class="ctl" id="hostfilterwrap" title="Auf einen Host filtern (Instanzen, KPI-Karten, Diagramme)." style="display:none">Host
    <select id="hostfilter"><option value="">Alle Hosts</option></select>
  </label>
  <span style="font-size:11px;color:var(--muted)">v__VERSION__</span>
  <span id="collstat" title="Status des Metrik-Collectors (Self-Monitoring)" style="font-size:11px"></span>
  <label class="ctl" title="Zeitfenster, das in allen Diagrammen dargestellt wird. Bei großen Fenstern werden die Daten automatisch verdichtet (Downsampling).">Zeitraum
    <select id="range" title="Zeitfenster der Diagramme (15 min bis 7 Tage; „heute“ = seit Mitternacht)">
      <option value="900">15 min</option>
      <option value="3600">1 h</option>
      <option value="21600">6 h</option>
      <option value="86400">24 h</option>
      <option value="today" selected>heute</option>
      <option value="604800">7 Tage</option>
      <option value="custom">benutzerdefiniert…</option>
    </select>
  </label>
  <span class="ctl" id="absrange" style="display:none" title="Freies Zeitfenster mit Datum und Uhrzeit (Von/Bis)">
    <input type="datetime-local" id="absfrom" title="Von – Datum und Uhrzeit">
    <span style="color:var(--muted)">–</span>
    <input type="datetime-local" id="absto" title="Bis – Datum und Uhrzeit">
    <button class="dbtn" id="absapply" title="Zeitfenster anwenden">✓</button>
  </span>
  <label class="ctl" title="Vergleicht das aktuelle Zeitfenster mit einem früheren – als gedämpfte, gestrichelte Linien in allen Diagrammen.">Vergleich
    <select id="compare" title="Vergleichszeitraum (Overlay)">
      <option value="0" selected>aus</option>
      <option value="prev">vorige Periode</option>
      <option value="86400">gestern</option>
      <option value="604800">letzte Woche</option>
    </select>
  </label>
  <span class="densgroup" title="Kacheldichte – mehr Punkte = mehr, kleinere Kacheln">
    <button class="dbtn" data-d="sehrdicht" title="Sehr klein, sehr viele Kacheln (6×5)"><svg class="dg" viewBox="0 0 26 20"><circle cx="3.5" cy="2.8" r="1.05"/><circle cx="7.3" cy="2.8" r="1.05"/><circle cx="11.1" cy="2.8" r="1.05"/><circle cx="14.9" cy="2.8" r="1.05"/><circle cx="18.7" cy="2.8" r="1.05"/><circle cx="22.5" cy="2.8" r="1.05"/><circle cx="3.5" cy="6.4" r="1.05"/><circle cx="7.3" cy="6.4" r="1.05"/><circle cx="11.1" cy="6.4" r="1.05"/><circle cx="14.9" cy="6.4" r="1.05"/><circle cx="18.7" cy="6.4" r="1.05"/><circle cx="22.5" cy="6.4" r="1.05"/><circle cx="3.5" cy="10.0" r="1.05"/><circle cx="7.3" cy="10.0" r="1.05"/><circle cx="11.1" cy="10.0" r="1.05"/><circle cx="14.9" cy="10.0" r="1.05"/><circle cx="18.7" cy="10.0" r="1.05"/><circle cx="22.5" cy="10.0" r="1.05"/><circle cx="3.5" cy="13.6" r="1.05"/><circle cx="7.3" cy="13.6" r="1.05"/><circle cx="11.1" cy="13.6" r="1.05"/><circle cx="14.9" cy="13.6" r="1.05"/><circle cx="18.7" cy="13.6" r="1.05"/><circle cx="22.5" cy="13.6" r="1.05"/><circle cx="3.5" cy="17.2" r="1.05"/><circle cx="7.3" cy="17.2" r="1.05"/><circle cx="11.1" cy="17.2" r="1.05"/><circle cx="14.9" cy="17.2" r="1.05"/><circle cx="18.7" cy="17.2" r="1.05"/><circle cx="22.5" cy="17.2" r="1.05"/></svg></button>
    <button class="dbtn" data-d="dicht" title="Klein, viele Kacheln (5×4)"><svg class="dg" viewBox="0 0 26 20"><circle cx="4.3" cy="4.0" r="1.3"/><circle cx="8.7" cy="4.0" r="1.3"/><circle cx="13.0" cy="4.0" r="1.3"/><circle cx="17.3" cy="4.0" r="1.3"/><circle cx="21.7" cy="4.0" r="1.3"/><circle cx="4.3" cy="8.0" r="1.3"/><circle cx="8.7" cy="8.0" r="1.3"/><circle cx="13.0" cy="8.0" r="1.3"/><circle cx="17.3" cy="8.0" r="1.3"/><circle cx="21.7" cy="8.0" r="1.3"/><circle cx="4.3" cy="12.0" r="1.3"/><circle cx="8.7" cy="12.0" r="1.3"/><circle cx="13.0" cy="12.0" r="1.3"/><circle cx="17.3" cy="12.0" r="1.3"/><circle cx="21.7" cy="12.0" r="1.3"/><circle cx="4.3" cy="16.0" r="1.3"/><circle cx="8.7" cy="16.0" r="1.3"/><circle cx="13.0" cy="16.0" r="1.3"/><circle cx="17.3" cy="16.0" r="1.3"/><circle cx="21.7" cy="16.0" r="1.3"/></svg></button>
    <button class="dbtn" data-d="kompakt" title="Mittel (4×3)"><svg class="dg" viewBox="0 0 26 20"><circle cx="5.2" cy="5.0" r="1.7"/><circle cx="10.4" cy="5.0" r="1.7"/><circle cx="15.6" cy="5.0" r="1.7"/><circle cx="20.8" cy="5.0" r="1.7"/><circle cx="5.2" cy="10.0" r="1.7"/><circle cx="10.4" cy="10.0" r="1.7"/><circle cx="15.6" cy="10.0" r="1.7"/><circle cx="20.8" cy="10.0" r="1.7"/><circle cx="5.2" cy="15.0" r="1.7"/><circle cx="10.4" cy="15.0" r="1.7"/><circle cx="15.6" cy="15.0" r="1.7"/><circle cx="20.8" cy="15.0" r="1.7"/></svg></button>
    <button class="dbtn" data-d="normal" title="Große Kacheln (3×2)"><svg class="dg" viewBox="0 0 26 20"><circle cx="6.5" cy="6.7" r="2.2"/><circle cx="13.0" cy="6.7" r="2.2"/><circle cx="19.5" cy="6.7" r="2.2"/><circle cx="6.5" cy="13.3" r="2.2"/><circle cx="13.0" cy="13.3" r="2.2"/><circle cx="19.5" cy="13.3" r="2.2"/></svg></button>
  </span>
  <button id="resetzoom" title="Zoom/Verschieben in allen Diagrammen zurücksetzen (Mausrad = Zoom, Ziehen = Verschieben)">Zoom ⟲</button>
  <button id="anombtn" title="Ausreißer (robuste MAD-Anomalie-Erkennung) in allen Diagrammen als rote Punkte markieren">⚠ Anomalien</button>
  <button id="reportbtn" title="KI-Gesamt-Report über alle Diagramme (Kennzahlen, Ausreißer, Prognosen)">📋 KI-Report</button>
  <button id="theme" title="Zwischen hellem und dunklem Design umschalten (wird gespeichert)">
    <svg class="ic-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>
    <svg class="ic-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>
  </button>
  <button id="notif" title="Browser-Benachrichtigungen bei Warnungen (KV-Cache voll, Fehler, Instanz offline) erlauben">🔔</button>
  <button id="secbtn" title="Verbindungssicherheit & Zertifikat">🔒</button>
  <button id="restore" title="Ausgeblendete Kacheln wieder einblenden" style="display:none">Ausgeblendet: 0 ⟲</button>
  <button id="reload" title="Daten und Instanz-Konfiguration sofort neu laden">⟳</button>
  <div class="menuwrap">
    <button id="gear" title="Weitere Optionen (Aktualisierung, Latenz-Perzentil, Export)">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
    </button>
    <div id="gearmenu" class="menu">
      <label class="mrow" title="Wie sich das Dashboard aktualisiert: Live schiebt Daten per Server-Sent-Events (Push), oder festes Poll-Intervall, oder ganz aus.">Aktualisierung
        <select id="mode" title="Aktualisierungsmodus des Dashboards">
          <option value="live" selected title="Live-Push vom Server (SSE) – niedrigste Verzögerung">Live (SSE)</option>
          <option value="5" title="Alle 5 Sekunden neu abfragen">alle 5 s</option>
          <option value="15" title="Alle 15 Sekunden neu abfragen">alle 15 s</option>
          <option value="60" title="Alle 60 Sekunden neu abfragen">alle 60 s</option>
          <option value="off" title="Keine automatische Aktualisierung – nur per „Neu laden“">Aus</option>
        </select>
      </label>
      <label class="mrow" title="Latenz-Perzentil für die Panels TTFT/E2E/ITL und die KPI-Karten. P95 = 95 % der Requests sind schneller; P99 zeigt Ausreißer, P50 den Median.">Latenz-Perzentil
        <select id="pct">
          <option value="p50">P50</option>
          <option value="p95" selected>P95</option>
          <option value="p99">P99</option>
        </select>
      </label>
      <button id="annbtn" title="Annotation (Deploy/Restart …) für den aktuellen Zeitpunkt setzen – erscheint als senkrechte Linie in allen Diagrammen; Klick auf eine Linie löscht sie">🏷 Notiz setzen</button>
      <button id="targetsbtn" title="Zusätzliche Instanzen (vLLM/Ollama/STT/GPU) ohne Unit-Editieren hinzufügen/entfernen">🖧 Instanzen verwalten</button>
      <button id="usersbtn" class="adminonly" title="Lokale und Active-Directory-Nutzer sowie LDAP-Zugriff verwalten (nur Admins)">👥 Benutzer &amp; Zugriff</button>
      <button id="threshbtn" class="adminonly" title="Alarm-Schwellwerte (KV-Cache, GPU-Temperatur, Fehler, Offline) anpassen (nur Admins)">🔔 Schwellwerte</button>
      <button id="export" title="Aktuell angezeigte Zeitreihen als CSV-Datei herunterladen">⬇ Export CSV</button>
      <button id="exportjson" title="Aktuell angezeigte Zeitreihen als JSON-Datei herunterladen">⬇ Export JSON</button>
      <a href="/metrics" target="_blank" rel="noopener" title="Prometheus-Exporter: aktuelle Werte im Prometheus-Textformat (für vorhandenes Prometheus/Grafana). Präfix vllm_monitor_, Labels host/port/model." style="display:block;font-size:12px;padding:2px 0;color:var(--fg);text-decoration:none;border-top:1px solid var(--border);margin-top:2px;padding-top:6px">📡 Prometheus /metrics ↗</a>
    </div>
  </div>
  <button id="logoutbtn" title="Abmelden" style="display:none">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>
  </button>
  <span class="userchip" id="userchip" title="Angemeldeter Benutzer" style="display:none">
    <span id="username"></span><span class="rolebadge" id="userrole"></span>
  </span>
  <span id="countdown"></span>
  <span id="status" style="flex-basis:100%;text-align:right"></span>
</header>

<div id="sections">
<div class="card" id="kpicard" data-id="kpi" style="margin:14px 16px 0">
  <div class="cardbtns"><button class="cbtn" id="kpitoggle" title="Ein-/Ausklappen">▾</button></div>
  <h2><span class="sgrip" title="Ziehen zum Umordnen der Bereiche">⠿</span>Modelle &amp; GPU</h2>
  <div class="kpis" id="kpis"></div>
</div>

<div class="card" id="instcard" data-id="inst" style="margin:14px 16px 0">
  <div class="cardbtns"><button class="cbtn" id="insttoggle" title="Ein-/Ausklappen">▾</button></div>
  <h2><span class="sgrip" title="Ziehen zum Umordnen der Bereiche">⠿</span>Instanzen</h2>
  <table id="insttable"><thead><tr>
    <th>Status</th><th>Typ</th><th>Instanz</th><th>Modell</th><th>Version</th>
    <th>KV-Kap. / VRAM</th><th>max_model_len</th><th>gpu_mem</th><th>Prefix-Cache</th>
  </tr></thead><tbody></tbody></table>
</div>

<div class="card collapsed" id="alertcard" data-id="alerts" style="margin:14px 16px 0">
  <div class="cardbtns"><button class="cbtn" id="alerttoggle" title="Ein-/Ausklappen">▸</button></div>
  <h2><span class="sgrip" title="Ziehen zum Umordnen der Bereiche">⠿</span>Alarm-Historie <span id="alertcount" style="color:var(--muted);font-weight:400"></span></h2>
  <table id="alerttable"><thead><tr>
    <th>Zeit</th><th>Status</th><th>Typ</th><th>Instanz / Modell</th><th>Meldung</th>
  </tr></thead><tbody></tbody></table>
</div>

<div class="card collapsed" id="effcard" data-id="eff" style="margin:14px 16px 0">
  <div class="cardbtns"><button class="cbtn" id="efftoggle" title="Ein-/Ausklappen">▸</button></div>
  <h2><span class="sgrip" title="Ziehen zum Umordnen der Bereiche">⠿</span>Effizienz & Kapazität <span style="color:var(--muted);font-weight:400;font-size:11px">(Ø über Zeitfenster, hochgerechnet)</span></h2>
  <div id="effbody" style="display:flex;flex-wrap:wrap;gap:18px;padding-top:4px"></div>
</div>

<div class="card" id="chartcard" data-id="chart" style="margin:14px 16px 0">
  <div class="cardbtns"><button class="cbtn" id="charttoggle" title="Ein-/Ausklappen">▾</button></div>
  <h2 class="chart-h2"><span class="sgrip" title="Ziehen zum Umordnen der Bereiche">⠿</span>Diagramme <span id="densslot"></span></h2>
  <div id="legend" title="Farb-Zuordnung der Modelle – Klick blendet ein Modell in allen Diagrammen aus/ein"></div>
  <div class="grid" id="charts"></div>
</div>
</div>

<div id="analysis">
  <div class="anbox">
    <div class="anhead"><h3 id="an_title">Analyse</h3>
      <button class="cbtn close" id="an_close" title="Schließen (Esc)">×</button></div>
    <div class="anbody">
      <h4>Kennzahlen (aktuelles Zeitfenster)</h4>
      <div id="an_stats"></div>
      <div id="an_extra">
        <h4>Auffälligkeiten (Ausreißer)</h4>
        <div id="an_anom"></div>
        <h4>Prognose</h4>
        <div id="an_fc"></div>
      </div>
      <h4>KI-Auswertung</h4>
      <div class="aiout" id="an_ai">Noch keine Auswertung generiert.</div>
      <div class="aimeta" id="an_aimeta"></div>
    </div>
    <div class="anfoot">
      <button class="abtn" id="an_gen">KI-Auswertung generieren</button>
      <button class="abtn sec" id="an_copy" title="Kennzahlen + KI-Text kopieren">Kopieren</button>
    </div>
  </div>
</div>

<div id="secbanner" style="display:none">
  <span>⚠️ Unverschlüsselte Verbindung (HTTP) – Browser-Benachrichtigungen sind hier nicht möglich.</span>
  <button id="secbanner-btn">Zertifikat / HTTPS</button>
  <button id="secbanner-x" title="Ausblenden">×</button>
</div>

<div id="targetmodal" class="modal-ov">
  <div class="modal-card" style="max-width:680px">
    <h2 style="display:flex;align-items:center;gap:10px">🖧 Instanzen verwalten
      <button class="cbtn close" id="tgt-close" title="Schließen" style="margin-left:auto">×</button></h2>
    <p>Alle Instanzen werden persistent in <code>targets.json</code> gespeichert und vom Collector
       beim nächsten Scrape (≤ 15 s) übernommen – ohne systemd-Unit zu ändern. Die per Setup/Unit
       definierten vLLM-Instanzen werden beim ersten Start automatisch hier übernommen und sind
       dann bearbeit-, pausier- und löschbar (✎ bearbeiten, Häkchen = aktiv, × löschen; die letzte
       vLLM-Instanz bleibt geschützt).</p>
    <table id="tgttable"><thead><tr>
      <th>Typ</th><th>Host</th><th>Port</th><th>Label</th><th>Aktiv</th><th></th>
    </tr></thead><tbody></tbody></table>
    <h4 style="margin:14px 0 8px;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)">Neu hinzufügen</h4>
    <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center">
      <select id="tgt-kind" style="background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:5px;padding:4px 6px">
        <option value="vllm">vLLM</option><option value="ollama">Ollama</option>
        <option value="stt">STT</option><option value="dcgm">DCGM/GPU</option>
      </select>
      <input id="tgt-host" placeholder="Host/IP" style="flex:1;min-width:140px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:5px;padding:4px 6px">
      <input id="tgt-port" placeholder="Port" style="width:80px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:5px;padding:4px 6px">
      <input id="tgt-label" placeholder="Label (optional)" style="width:150px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:5px;padding:4px 6px">
      <button class="abtn" id="tgt-add">Hinzufügen</button>
    </div>
    <div id="tgt-msg" style="color:var(--muted);font-size:12px;margin-top:8px;min-height:16px"></div>
  </div>
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

<!-- Login-/Passwortwechsel-Overlay -->
<div id="authov">
  <div class="auth-card" id="logincard">
    <h2>KI Monitor</h2>
    <p class="sub">Bitte anmelden</p>
    <label for="li-user">Benutzer</label>
    <input id="li-user" autocomplete="username" placeholder="Benutzername oder user@domäne">
    <label for="li-pass">Passwort</label>
    <input id="li-pass" type="password" autocomplete="current-password">
    <button class="primary" id="li-submit">Anmelden</button>
    <div class="auth-msg" id="li-msg"></div>
  </div>
  <div class="auth-card" id="pwcard" style="display:none">
    <h2>Passwort ändern</h2>
    <p class="sub" id="pw-sub">Beim ersten Login muss das Passwort geändert werden.</p>
    <label for="pw-old">Aktuelles Passwort</label>
    <input id="pw-old" type="password" autocomplete="current-password">
    <label for="pw-new">Neues Passwort (mind. 6 Zeichen)</label>
    <input id="pw-new" type="password" autocomplete="new-password">
    <label for="pw-new2">Neues Passwort wiederholen</label>
    <input id="pw-new2" type="password" autocomplete="new-password">
    <button class="primary" id="pw-submit">Speichern</button>
    <div class="auth-msg" id="pw-msg"></div>
  </div>
</div>

<!-- Benutzer- & Zugriffsverwaltung (nur Admins) -->
<div id="usermodal" class="modal-ov">
  <div class="modal-card" style="max-width:760px">
    <h2 style="display:flex;align-items:center;gap:10px">👥 Benutzer &amp; Zugriff
      <button class="cbtn close" id="usr-close" title="Schließen" style="margin-left:auto">×</button></h2>

    <h4 style="margin:6px 0 4px;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)">Lokale Benutzer</h4>
    <table class="utable" id="localtable"><thead><tr><th>Benutzer</th><th>Rolle</th><th>Status</th><th></th></tr></thead><tbody></tbody></table>
    <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin-top:6px">
      <input id="nu-name" class="uinput" placeholder="Benutzername" style="flex:1;min-width:120px">
      <input id="nu-pass" class="uinput" type="password" placeholder="Passwort" style="width:150px">
      <select id="nu-role" class="uinput"><option value="admin">Admin</option><option value="readonly" selected>Read-only</option></select>
      <label style="font-size:12px;color:var(--muted);display:flex;align-items:center;gap:4px"><input type="checkbox" id="nu-mc">Wechsel erzwingen</label>
      <button class="abtn" id="nu-add">Anlegen</button>
    </div>

    <h4 style="margin:16px 0 4px;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)">Active-Directory-Benutzer (Einzelfreigabe)</h4>
    <table class="utable" id="adtable"><thead><tr><th>Benutzer (sAMAccountName)</th><th>Rolle</th><th></th></tr></thead><tbody></tbody></table>
    <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin-top:6px">
      <input id="na-name" class="uinput" placeholder="z. B. jdoe" style="flex:1;min-width:120px">
      <select id="na-role" class="uinput"><option value="admin">Admin</option><option value="readonly" selected>Read-only</option></select>
      <button class="abtn" id="na-add">Freigeben</button>
    </div>

    <h4 style="margin:16px 0 4px;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)">LDAP-/AD-Anbindung</h4>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px 12px">
      <label style="font-size:12px;color:var(--muted);grid-column:1/3;display:flex;align-items:center;gap:6px">
        <input type="checkbox" id="ld-enabled"> LDAP-Anmeldung aktivieren</label>
      <label style="font-size:12px;color:var(--muted)">Domain-Controller (Host/IP)<input id="ld-host" class="uinput" style="width:100%;box-sizing:border-box"></label>
      <label style="font-size:12px;color:var(--muted)">Domäne (UPN-Suffix)<input id="ld-domain" class="uinput" style="width:100%;box-sizing:border-box" placeholder="z. B. firma.int"></label>
      <label style="font-size:12px;color:var(--muted)">TLS<select id="ld-tls" class="uinput" style="width:100%"><option value="auto">auto (LDAPS, sonst Klartext)</option><option value="require">nur LDAPS</option><option value="off">nur Klartext</option></select></label>
      <label style="font-size:12px;color:var(--muted)">Basis-DN (optional)<input id="ld-base" class="uinput" style="width:100%;box-sizing:border-box" placeholder="autom. aus Domäne"></label>
      <label style="font-size:12px;color:var(--muted)">Admin-Gruppe (CN oder DN)<input id="ld-gadmin" class="uinput" style="width:100%;box-sizing:border-box" placeholder="z. B. vllm-admins"></label>
      <label style="font-size:12px;color:var(--muted)">Read-only-Gruppe<input id="ld-gro" class="uinput" style="width:100%;box-sizing:border-box" placeholder="z. B. vllm-viewer"></label>
      <label style="font-size:12px;color:var(--muted)">Standardrolle (ohne Gruppe/Freigabe)<select id="ld-defrole" class="uinput" style="width:100%"><option value="">kein Zugriff</option><option value="readonly">Read-only</option><option value="admin">Admin</option></select></label>
    </div>
    <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin-top:10px">
      <button class="abtn" id="ld-save">LDAP speichern</button>
      <span style="flex:1"></span>
      <input id="ld-tuser" class="uinput" placeholder="Test-Benutzer" style="width:130px">
      <input id="ld-tpass" class="uinput" type="password" placeholder="Test-Passwort" style="width:130px">
      <button class="abtn" id="ld-test">Verbindung testen</button>
    </div>

    <h4 style="margin:16px 0 4px;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)">Verzeichnis durchsuchen</h4>
    <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center">
      <select id="ds-kind" class="uinput"><option value="user">Benutzer</option><option value="group">Gruppe</option></select>
      <input id="ds-q" class="uinput" placeholder="Name/Teil eingeben…" style="flex:1;min-width:150px">
      <button class="abtn" id="ds-go">🔍 Suchen</button>
      <span style="font-size:11px;color:var(--muted)">nutzt die Test-Anmeldedaten oben</span>
    </div>
    <div id="ds-results" style="margin-top:6px;max-height:190px;overflow:auto"></div>

    <div id="usr-msg" style="color:var(--muted);font-size:12px;margin-top:10px;min-height:16px"></div>
  </div>
</div>

<!-- Alarm-Schwellwerte (nur Admins) -->
<div id="threshmodal" class="modal-ov">
  <div class="modal-card" style="max-width:460px">
    <h2 style="display:flex;align-items:center;gap:10px">🔔 Alarm-Schwellwerte
      <button class="cbtn close" id="th-close" title="Schließen" style="margin-left:auto">×</button></h2>
    <p>Ab diesen Werten löst der Collector einen Alarm aus (gilt für alle Instanzen,
       greift ohne Neustart beim nächsten Scrape ≤ 15 s).</p>
    <div style="display:grid;grid-template-columns:1fr auto;gap:10px 12px;align-items:center">
      <label for="th-temp">GPU-Temperatur – Alarm über (°C)</label>
      <input id="th-temp" type="number" min="0" step="1" class="uinput" style="width:100px">
      <label for="th-kv">KV-Cache-Auslastung – Alarm über (%)</label>
      <input id="th-kv" type="number" min="0" max="100" step="1" class="uinput" style="width:100px">
      <label for="th-err">Neue Fehler je Scrape – Alarm über</label>
      <input id="th-err" type="number" min="0" step="1" class="uinput" style="width:100px">
      <label for="th-offline">Offline-Dauer bis Alarm (Minuten)</label>
      <input id="th-offline" type="number" min="0" step="0.5" class="uinput" style="width:100px">
    </div>
    <div style="display:flex;gap:8px;align-items:center;margin-top:14px">
      <button class="abtn" id="th-save">Speichern</button>
      <span id="th-msg" style="color:var(--muted);font-size:12px;min-height:16px"></span>
    </div>
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

let charts={}, lastData=null, lastConfig=null, hoverX=null, resets=[], annotations=[];
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
  if(s.startsWith("gpu")||s.includes("dcgm"))return "#B80F2E";                        // GPU = rot
  if(s.includes("qwen"))return "#35628B";                                            // Qwen = blau
  if(s.includes("gemma"))return "#3fb950";                                           // Gemma = grün
  if(s.includes("whisper")||s.includes("stt")||s.includes("faster"))return "#9C9D9F";// STT = grau/rosa
  return null;
}
function computeColors(models){
  modelColors={}; Object.keys(models).sort().forEach((m,i)=>modelColors[m]=defaultColorFor(m)||COLORS[i%COLORS.length]);
}
function setColor(m,c,rebuild){
  customColors[m]=c; store.set("vllm_colors",JSON.stringify(customColors));
  if(!lastData)return;
  renderLegend(lastData.models);   // Legende + Diagramme live aktualisieren
  redrawCharts(lastData.models);
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
function afterElement(container,x,y,ph,vertical){
  // Treffer-Test: über welcher Karte steht der Zeiger? -> davor/danach einsortieren.
  // Kein Sprung, wenn der Zeiger über der Lücke oder zwischen den Karten liegt.
  const cards=[...container.querySelectorAll(":scope > [data-id]:not(.dragging)")];
  if(!cards.length) return null;
  for(const c of cards){
    const b=c.getBoundingClientRect();
    if(x>=b.left && x<=b.right && y>=b.top && y<=b.bottom){
      const before = vertical ? (y < b.top + b.height/2) : (x < b.left + b.width/2);
      return before ? c : c.nextElementSibling;
    }
  }
  const first=cards[0].getBoundingClientRect();
  const last=cards[cards.length-1].getBoundingClientRect();
  if(y > last.bottom) return null;       // unterhalb aller Karten -> ans Ende
  if(y < first.top)   return cards[0];   // oberhalb aller Karten -> vor die erste
  return ph;                             // dazwischen -> Platzhalter nicht bewegen
}
function makeSortable(container,onSave,handleSel,vertical){
  container.querySelectorAll(handleSel||".handle").forEach(h=>{
    if(h._sortBound)return; h._sortBound=true;
    // Nach echtem Drag den folgenden Klick unterdrücken (sonst toggelt der Header)
    h.addEventListener("click",e=>{ if(h._suppressClick){ e.stopImmediatePropagation(); e.preventDefault(); h._suppressClick=false; } },true);
    h.addEventListener("pointerdown",e=>{
      if(e.button!==0)return;
      const el=h.closest("[data-id]"); if(!el)return;
      const startX=e.clientX, startY=e.clientY;
      let dragging=false, ph=null, offX=0, offY=0;
      const begin=ev=>{
        dragging=true;
        const rect=el.getBoundingClientRect();
        offX=startX-rect.left; offY=startY-rect.top;
        ph=document.createElement("div");
        ph.className="placeholder-slot"; ph.style.height=rect.height+"px";
        container.insertBefore(ph,el);
        window._dragging=true; el.classList.add("dragging");
        el.style.position="fixed"; el.style.width=rect.width+"px";
        el.style.zIndex="1000"; el.style.pointerEvents="none";
        document.body.appendChild(el);   // aus dem Raster nehmen -> keine Sibling-Rückkopplung
      };
      const move=ev=>{
        if(!dragging){
          // erst ab kleiner Bewegungsschwelle wird gezogen – ein Klick bleibt ein Klick
          if(Math.abs(ev.clientX-startX)<5 && Math.abs(ev.clientY-startY)<5) return;
          begin(ev);
        }
        ev.preventDefault();
        el.style.left=(ev.clientX-offX)+"px";
        el.style.top=(ev.clientY-offY)+"px";
        const ref=afterElement(container,ev.clientX,ev.clientY,ph,vertical);
        if(ref!==ph){ if(ref)container.insertBefore(ph,ref); else container.appendChild(ph); }
      };
      const up=()=>{
        document.removeEventListener("pointermove",move);
        document.removeEventListener("pointerup",up);
        document.removeEventListener("pointercancel",up);
        if(!dragging)return;               // war nur ein Klick -> nichts tun
        container.insertBefore(el,ph); ph.remove();
        el.classList.remove("dragging");
        el.style.position=el.style.width=el.style.left=el.style.top=el.style.zIndex=el.style.pointerEvents="";
        window._dragging=false;
        h._suppressClick=true;             // den unmittelbar folgenden Klick verwerfen
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
  // Manuelle Annotationen (Deploy/Restart …): senkrechte Linie + vertikales Label
  const acc=css("--accent");
  annotations.forEach(an=>{const px=x.getPixelForValue(an.ts);if(px>=a.left&&px<=a.right){
    ctx.strokeStyle=acc;ctx.setLineDash([5,3]);ctx.lineWidth=1;
    ctx.beginPath();ctx.moveTo(px,a.top);ctx.lineTo(px,a.bottom);ctx.stroke();
    ctx.setLineDash([]);ctx.fillStyle=acc;ctx.font="10px sans-serif";ctx.textAlign="left";
    ctx.save();ctx.translate(px+3,a.top+3);ctx.rotate(Math.PI/2);ctx.fillText(an.label,0,0);ctx.restore();}});
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
      onClick:(e,els,c)=>{const xs=c.scales.x;let hit=null,best=6;
        annotations.forEach(an=>{const ap=xs.getPixelForValue(an.ts);const d=Math.abs(ap-e.x);if(d<=best){best=d;hit=an;}});
        if(hit&&confirm('Annotation „'+hit.label+'" löschen?')) delAnnotation(hit.id);},
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
    if(hiddenModels.has(name)||!passHost(name))return;
    const color=colorFor(name);
    const cap=spec.id==="kvtok"?capacityOf(name):null;
    fieldsFor(spec).forEach(f=>{
      const data=models[name].map(p=>{
        let y=p[f.k];
        if(spec.id==="kvtok"){y=(cap&&p.kv!=null)?Math.round(p.kv/100*cap):null;}
        else if(spec.id==="vram"){y=(p.vram_bytes!=null)?Math.round(p.vram_bytes/1e7)/100:null;}
        return {x:p.t,y};
      }).filter(p=>p.y!==null&&p.y!==undefined);
      let anomSet=null;
      if(window._anomOn){ const a=detectAnomalies(data); if(a.count) anomSet=new Set(a.items.map(i=>i.t)); }
      ds.push({label:shortModel(name)+(f.l?" · "+f.l:""),data,borderColor:color,backgroundColor:color,
               borderDash:f.dash||[],borderWidth:1.8,tension:.25,spanGaps:true,
               pointRadius: anomSet?(ctx=>{const r=ctx.raw;return r&&anomSet.has(r.x)?3.5:0;}):0,
               pointBackgroundColor:"#ff4d4f",pointBorderColor:"#ff4d4f"});
    });
  });
  return ds;
}

// --- Zeitraum-Vergleich: gedämpfte, gestrichelte Overlay-Linien ---
function hexA(h,a){ const m=/^#?([0-9a-fA-F]{6})$/.exec(h); if(!m)return h;
  const n=parseInt(m[1],16); return "rgba("+((n>>16)&255)+","+((n>>8)&255)+","+(n&255)+","+a+")"; }
function compareDatasets(models,spec){
  const ds=[];
  Object.keys(models).sort().forEach(name=>{
    if(hiddenModels.has(name)||!passHost(name))return;
    const color=hexA(colorFor(name),0.4);
    const cap=spec.id==="kvtok"?capacityOf(name):null;
    fieldsFor(spec).forEach(f=>{
      const data=models[name].map(p=>{ let y=p[f.k];
        if(spec.id==="kvtok"){y=(cap&&p.kv!=null)?Math.round(p.kv/100*cap):null;}
        else if(spec.id==="vram"){y=(p.vram_bytes!=null)?Math.round(p.vram_bytes/1e7)/100:null;}
        return {x:p.t,y};
      }).filter(p=>p.y!==null&&p.y!==undefined);
      ds.push({label:shortModel(name)+(f.l?" · "+f.l:"")+" · Vgl.",data,borderColor:color,
               backgroundColor:color,borderDash:[5,4],borderWidth:1.2,pointRadius:0,tension:.25,spanGaps:true});
    });
  });
  return ds;
}
// --- Host-Filter (mehrere Hosts/Cluster) ---
let hostFilter=store.get("vllm_host")||"";
function hostList(){ return lastConfig?[...new Set((lastConfig.instances||[]).map(i=>i.host))].sort():[]; }
function passHost(model){
  if(!hostFilter||!lastConfig) return true;
  return (lastConfig.instances||[]).some(x=>x.model===model && x.host===hostFilter);
}
function renderHostFilter(){
  const wrap=document.getElementById("hostfilterwrap"), sel=document.getElementById("hostfilter");
  if(!sel)return; const hosts=hostList();
  wrap.style.display = hosts.length ? "" : "none";   // direkt hinter dem Titel, Default „Alle Hosts“
  sel.innerHTML='<option value="">Alle Hosts</option>'+hosts.map(h=>'<option value="'+h+'">'+h+'</option>').join("");
  if(hostFilter && hosts.includes(hostFilter)) sel.value=hostFilter; else { hostFilter=""; sel.value=""; }
}
let compareData=null;
function compareOffset(){ const v=document.getElementById("compare").value;
  if(v==="0")return 0; if(v==="prev")return windowSpan(); return parseInt(v,10)||0; }
async function fetchCompare(){
  const off=compareOffset();
  if(!off){ compareData=null; if(lastData)applySeries(lastData); return; }
  let url;
  if(isAbs()){ const w=absWindow();
    if(!w){ compareData=null; if(lastData)applySeries(lastData); return; }
    url="/api/series?from="+(w.from-off)+"&to="+(w.to-off)+"&offset="+off; }
  else url="/api/series?range="+rangeVal()+"&offset="+off;
  try{ compareData=await(await fetch(url)).json(); }
  catch(e){ compareData=null; }
  if(lastData)applySeries(lastData);
}
function withCompare(dsets,spec){
  if(compareData&&compareData.models&&compareOffset())
    return dsets.concat(compareDatasets(compareData.models,spec));
  return dsets;
}
function redrawCharts(models){
  CHARTS.forEach(spec=>{charts[spec.id].data.datasets=withCompare(datasets(models,spec),spec);charts[spec.id].update();});
}

function num(v,d){return v==null?"–":(typeof v==="number"?(Number.isInteger(v)?v:v.toFixed(d==null?1:d)):v);}
function durTxt(sec){ if(sec==null)return "–"; sec=Math.floor(sec);
  if(sec<60)return sec+" s"; if(sec<3600)return Math.floor(sec/60)+" min";
  const h=Math.floor(sec/3600),m=Math.floor((sec%3600)/60); return h+" h"+(m?" "+m+" min":""); }

function renderKPIs(){
  if(!lastData||window._dragging||window._picking)return;   // Verschieben/Farbwahl nicht stören
  const wrap=document.getElementById("kpis");wrap.innerHTML="";
  const alerts=[];
  const saved=JSON.parse(store.get("vllm_kpi_order")||"null");
  const pct=document.getElementById("pct").value;
  orderBy(Object.keys(lastData.models).sort(),saved,m=>m).forEach(model=>{
    if(!passHost(model))return;
    const s=lastData.models[model];const last=s.length?s[s.length-1]:{};
    const inst=lastConfig?lastConfig.instances.find(x=>x.model===model):null;
    const online=inst?inst.online:true;
    const kind=inst?inst.kind:"vllm";
    const th=(lastConfig&&lastConfig.thresholds)||{kv:90,temp:85,err:0};
    const kv=last.kv||0, wait=last.waiting||0, err=last.error_ps||0, temp=last.gpu_temp||0;
    const kvBad=kv>th.kv, errBad=err>th.err, tempBad=temp>th.temp;
    const offMin=inst&&!online&&inst.age!=null?Math.floor(inst.age/60):null;
    if(!online)alerts.push(shortModel(model)+": offline"+(offMin!=null?" seit "+durTxt(inst.age):""));
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
    el.innerHTML=`<h3><span class="grip" title="Ziehen zum Verschieben">⠿</span><span class="dot ${online?"on":"off"}"></span>${shortModel(model)}
        <input type="color" class="cpick" value="${colorFor(model)}" title="Diagramm-Farbe wählen">
        <span style="font-size:11px;color:var(--muted)">${online?"online":("offline"+(offMin!=null?" · seit "+durTxt(inst.age):""))}</span></h3>
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
  makeSortable(wrap,()=>saveOrder(wrap,"vllm_kpi_order"),".grip");
  window._alerts=alerts;maybeNotify(alerts);
}

function renderInstances(){
  const tb=document.querySelector("#insttable tbody");tb.innerHTML="";
  if(!lastConfig)return;
  lastConfig.instances.forEach(i=>{
    if(hostFilter && i.host!==hostFilter)return;
    const tr=document.createElement("tr");
    let capcell="–";
    if(i.capacity_tokens){capcell=Math.round(i.capacity_tokens).toLocaleString("de-DE")+" Tok"
      +(i.kv_cache_dtype?` <span style="color:var(--muted)">(${i.kv_cache_dtype})</span>`:"");}
    else if(i.vram_bytes){capcell=(i.vram_bytes/1e9).toFixed(2)+" GB VRAM";}
    const statusTxt = i.online ? "online" : (i.configured && i.age==null ? "nicht erreichbar" : "offline");
    tr.innerHTML=`<td><span class="dot ${i.online?"on":"off"}"></span> ${statusTxt}</td>
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
  redrawCharts(j.models);
  renderKPIs();
  renderEfficiency();
  const n=Object.values(j.models).reduce((a,s)=>a+s.length,0);
  document.getElementById("status").textContent="Stand "+new Date(j.now).toLocaleTimeString("de-DE")+" · "+n+" Punkte";
}

function renderCollector(){
  const el=document.getElementById("collstat"); if(!el)return;
  const c=lastConfig&&lastConfig.collector;
  if(!c){ el.textContent=""; return; }
  const dot='<span class="dot '+(c.ok?"on":"off")+'" style="margin-right:4px"></span>';
  el.innerHTML=dot+(c.ok?("Collector aktiv · "+durTxt(c.age)):("Collector inaktiv – letzter Scrape vor "+durTxt(c.age)))
    +(c.errors?(" · "+c.errors+" Fehler"):"");
  el.style.color = c.ok?"var(--muted)":"var(--bad)";
}
async function fetchConfig(){try{lastConfig=await(await fetch("/api/config")).json();renderHostFilter();renderInstances();renderKPIs();renderCollector();}catch(e){}}
async function fetchOnce(){try{applySeries(await(await fetch("/api/series?"+seriesQuery())).json());}catch(e){document.getElementById("status").textContent="Fehler: "+e;}}

// --- Refresh-Steuerung: Live (SSE) oder Intervall ---
let es=null, remaining=0, period=0, lastMsg=Date.now();
const rangeSel=()=>document.getElementById("range").value;   // Roh-Auswahl (auch "today")
const rangeVal=()=>{ const v=rangeSel();
  if(v==="today"){ const d=new Date(); d.setHours(0,0,0,0);
    return String(Math.max(60, Math.floor((Date.now()-d.getTime())/1000))); }  // seit Mitternacht
  return v; };
// --- Absolutes Zeitfenster (Von/Bis mit Datum+Uhrzeit) ---
const isAbs=()=>rangeSel()==="custom";
function absSecs(id){ const el=document.getElementById(id);
  if(!el||!el.value)return null; const t=new Date(el.value).getTime();
  return isNaN(t)?null:Math.floor(t/1000); }
function absWindow(){ const fr=absSecs("absfrom"), to=absSecs("absto");
  if(fr==null||to==null||to<=fr)return null; return {from:fr,to:to}; }
function seriesQuery(){ if(isAbs()){ const w=absWindow();
    if(w)return "from="+w.from+"&to="+w.to; } return "range="+rangeVal(); }
function windowSpan(){ if(isAbs()){ const w=absWindow(); return w?(w.to-w.from):0; }
  return parseInt(rangeVal(),10)||0; }
function pad2(n){return String(n).padStart(2,"0");}
function toLocalInput(d){ return d.getFullYear()+"-"+pad2(d.getMonth()+1)+"-"+pad2(d.getDate())
  +"T"+pad2(d.getHours())+":"+pad2(d.getMinutes()); }
function ensureAbsDefaults(){ const f=document.getElementById("absfrom"), t=document.getElementById("absto");
  if(!t.value) t.value=toLocalInput(new Date());
  if(!f.value){ const d=new Date(); d.setHours(0,0,0,0); f.value=toLocalInput(d); } }
function applyAbs(){ store.set("vllm_absfrom",document.getElementById("absfrom").value);
  store.set("vllm_absto",document.getElementById("absto").value);
  startRefresh(); fetchCompare(); fetchAnnotations(); }
function rangeLabel(){ const sel=document.getElementById("range");
  if(sel.value==="custom"){ const w=absWindow();
    return w ? new Date(w.from*1000).toLocaleString()+" – "+new Date(w.to*1000).toLocaleString()
             : "benutzerdefiniert"; }
  return sel.options[sel.selectedIndex].text; }
const cd=document.getElementById("countdown");
function setCd(t,cls){cd.className=cls||"";cd.textContent=t;}
function stopAll(){if(es){es.close();es=null;}}

function startRefresh(){
  stopAll();
  if(isAbs()){   // fester Zeitraum: kein Live/Intervall, einmalig laden
    const w=absWindow();
    setCd(w?"📅 fester Zeitraum":"⚠ Von/Bis unvollständig", "paused");
    if(w)fetchOnce();
    return;
  }
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
  if(isAbs())return;   // fester Zeitraum aktualisiert sich nicht selbst
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
  const btns=`<div class="cardbtns"><button class="cbtn analyze" title="Analyse & KI-Auswertung">🔍</button>`+
             `<button class="cbtn max" title="Maximieren (Esc schließt)">⛶</button>`+
             `<button class="cbtn close" title="Kachel ausblenden">×</button></div>`;
  orderBy(CHARTS,saved,s=>s.id).forEach(spec=>{
    const d=document.createElement("div");d.className="card";d.dataset.id=spec.id;
    d.innerHTML=btns+`<h2 title="${spec.desc||""}"><span class="grip" title="Ziehen zum Verschieben">⠿</span>${spec.title}</h2><canvas id="c_${spec.id}"></canvas>`;
    g.appendChild(d);
  });
  makeSortable(g,()=>saveOrder(g,"vllm_chart_order"),".grip");
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
  const cv=card.querySelector("canvas");
  if(on){ window.scrollTo(0,0);
    const hdr=document.querySelector("header");
    const top=(hdr?hdr.offsetHeight:56)+8;
    card.style.top=top+"px";                               // unter der Titelleiste beginnen
    // Canvas exakt an den verbleibenden Platz einpassen (echte Maße messen) ->
    // Achsenbeschriftung ohne Scrollen. clientHeight enthält Padding, aber nicht Rand/Scrollbar.
    const ccs=getComputedStyle(card);
    const pad=parseFloat(ccs.paddingTop)+parseFloat(ccs.paddingBottom);
    const h2=card.querySelector("h2");
    let h2h=0; if(h2){ h2h=h2.offsetHeight+(parseFloat(getComputedStyle(h2).marginBottom)||0); }
    const avail=card.clientHeight - pad - h2h - 6;          // 6px Puffer
    if(cv) cv.style.maxHeight=Math.max(140,avail)+"px";
  } else { card.style.top=""; if(cv) cv.style.maxHeight=""; }
  const c=charts[id]; if(c) setTimeout(()=>{try{c.resize();}catch(e){}},60);
}
function wireCardButtons(container){
  if(container._btnwired)return; container._btnwired=true;
  container.addEventListener("click",e=>{
    const b=e.target.closest(".cbtn"); if(!b)return;
    const card=b.closest("[data-id]"); if(!card)return;
    if(b.classList.contains("analyze")) openAnalysis(card.dataset.id);
    else if(b.classList.contains("max")) toggleMax(card,card.dataset.id);
    else if(b.classList.contains("close")){ const h=loadHidden(); if(!h.includes(card.dataset.id)){h.push(card.dataset.id);saveHidden(h);} if(card.classList.contains("maximized"))toggleMax(card,card.dataset.id); applyHidden(); }
  });
}
// Esc beendet die Maximierung
document.addEventListener("keydown",e=>{
  if(e.key==="Escape"){
    const an=document.getElementById("analysis");
    if(an&&an.classList.contains("open")){closeAnalysis();return;}
    const m=document.querySelector(".card.maximized");if(m)toggleMax(m,m.dataset.id);}
});

// --- KI-Auswertung & Analyse-Panel ---
// KI-Auswertung wird ausschließlich server-seitig konfiguriert (Env VLLM_AI_*).
// Frühere browser-seitige Overrides aufräumen.
["vllm_ai_key","vllm_ai_url","vllm_ai_model","vllm_ai_on"].forEach(k=>store.del(k));
const fmt=v=>{ if(v==null||isNaN(v))return "–"; const a=Math.abs(v);
  return a>=100?v.toFixed(0):a>=1?v.toFixed(1):v.toFixed(2); };
function chartStats(spec){
  if(!lastData)return [];
  return datasets(lastData.models,spec).map(d=>{
    let n=0,min=Infinity,max=-Infinity,sum=0,first=null,last=null;
    d.data.forEach(p=>{const v=p.y; if(v==null||isNaN(v))return;
      n++; if(v<min)min=v; if(v>max)max=v; sum+=v; if(first===null)first=v; last=v;});
    return n?{label:d.label,color:d.borderColor,n,min,max,avg:sum/n,last,trend:last-first}
            :{label:d.label,color:d.borderColor,n:0};
  });
}
function unitOf(spec){ const m=spec.title.match(/\(([^)]+)\)\s*$/); return m?m[1]:""; }
function renderStats(stats){
  let h='<table class="antab"><thead><tr><th>Serie</th><th>Ø</th><th>Min</th><th>Max</th><th>Aktuell</th><th>Trend</th></tr></thead><tbody>';
  stats.forEach(s=>{
    const sw='<span class="sw" style="background:'+s.color+'"></span>';
    if(!s.n){ h+='<tr><td>'+sw+s.label+'</td><td colspan="5" style="text-align:left;color:var(--muted)">keine Daten</td></tr>'; return; }
    const arrow=s.trend>0?"▲":s.trend<0?"▼":"–";
    h+='<tr><td>'+sw+s.label+'</td><td>'+fmt(s.avg)+'</td><td>'+fmt(s.min)+'</td><td>'+fmt(s.max)+
       '</td><td>'+fmt(s.last)+'</td><td>'+arrow+' '+fmt(Math.abs(s.trend))+'</td></tr>';
  });
  return h+"</tbody></table>";
}
function statsAsText(stats){
  return stats.map(s=> s.n
    ? "- "+s.label+": Ø "+fmt(s.avg)+", Min "+fmt(s.min)+", Max "+fmt(s.max)+", aktuell "+fmt(s.last)+", Trend "+(s.trend>=0?"+":"")+fmt(s.trend)
    : "- "+s.label+": keine Daten").join("\n");
}
// --- Anomalie-Erkennung (robust, ohne KI): Median ± k·MAD ---
function detectAnomalies(data,k){
  k=k||3.5;
  const ys=data.map(p=>p.y).filter(v=>v!=null&&!isNaN(v));
  if(ys.length<8)return {count:0,items:[]};
  const srt=[...ys].sort((a,b)=>a-b), med=srt[srt.length>>1];
  const dev=ys.map(v=>Math.abs(v-med)).sort((a,b)=>a-b);
  let scale=(dev[dev.length>>1]||0)*1.4826;
  if(scale<=1e-9){ const mean=ys.reduce((a,b)=>a+b,0)/ys.length;
    scale=Math.sqrt(ys.reduce((a,b)=>a+(b-mean)*(b-mean),0)/ys.length); }
  if(scale<=1e-9)return {count:0,items:[],med};
  const items=[];
  data.forEach(p=>{ if(p.y==null||isNaN(p.y))return; if(Math.abs(p.y-med)/scale>k) items.push({t:p.x,y:p.y}); });
  return {count:items.length,items,med};
}
function chartAnoms(spec){
  if(!lastData)return [];
  return datasets(lastData.models,spec).map(d=>{
    const a=detectAnomalies(d.data);
    return {label:d.label,color:d.borderColor,count:a.count,items:a.items};
  });
}
function renderAnoms(anoms){
  const withA=anoms.filter(a=>a.count>0);
  if(!withA.length) return '<div style="color:var(--muted);font-size:12px">Keine Ausreißer im Zeitfenster (robuste MAD-Analyse).</div>';
  let h='<table class="antab"><thead><tr><th>Serie</th><th>Ausreißer</th><th>zuletzt</th><th>Wert</th></tr></thead><tbody>';
  withA.forEach(a=>{ const l=a.items[a.items.length-1];
    h+='<tr><td><span class="sw" style="background:'+a.color+'"></span>'+a.label+'</td><td>'+a.count+
       '</td><td>'+new Date(l.t).toLocaleTimeString("de-DE")+'</td><td>'+fmt(l.y)+'</td></tr>'; });
  return h+'</tbody></table>';
}
function anomsAsText(anoms){
  const w=anoms.filter(a=>a.count>0);
  return w.length ? w.map(a=>"- "+a.label+": "+a.count+" Ausreißer (zuletzt "+fmt(a.items[a.items.length-1].y)+")").join("\n")
                  : "keine Ausreißer";
}
// --- Prognose: lineare Regression je Serie (Steigung pro Minute + ETA) ---
function linfit(data){
  const p=data.filter(d=>d.y!=null&&!isNaN(d.y)); const n=p.length; if(n<3)return null;
  const t0=p[0].x; let sx=0,sy=0,sxx=0,sxy=0;
  p.forEach(d=>{const x=(d.x-t0)/60000,y=d.y; sx+=x;sy+=y;sxx+=x*x;sxy+=x*y;});
  const den=n*sxx-sx*sx; if(Math.abs(den)<1e-9)return null;
  return {slopePerMin:(n*sxy-sx*sy)/den, last:p[n-1].y};
}
function chartForecast(spec){
  if(!lastData)return [];
  const target=spec.threshold||spec.max||null;
  return datasets(lastData.models,spec).map(d=>{
    const f=linfit(d.data); if(!f)return {label:d.label,color:d.borderColor,none:true};
    let eta="–";
    if(target && f.slopePerMin>0.01 && f.last<target){
      const mins=(target-f.last)/f.slopePerMin;
      if(mins>0 && mins<60*24) eta="erreicht "+fmt(target)+" in ~"+durTxt(mins*60);
    } else if(target && f.slopePerMin<-0.01){ eta="fällt (kein Sättigungsrisiko)"; }
    else if(Math.abs(f.slopePerMin)<=0.01){ eta="stabil"; }
    return {label:d.label,color:d.borderColor,perMin:f.slopePerMin,eta};
  });
}
function renderForecast(fc){
  const r=fc.filter(x=>!x.none);
  if(!r.length) return '<div style="color:var(--muted);font-size:12px">Zu wenige Punkte für eine Prognose.</div>';
  let h='<table class="antab"><thead><tr><th>Serie</th><th>Trend/min</th><th>Prognose</th></tr></thead><tbody>';
  r.forEach(x=>{ h+='<tr><td><span class="sw" style="background:'+x.color+'"></span>'+x.label+'</td><td>'+
    (x.perMin>=0?"+":"")+fmt(x.perMin)+'</td><td>'+(x.eta||"–")+'</td></tr>'; });
  return h+'</tbody></table>';
}
function forecastAsText(fc){
  const r=fc.filter(x=>!x.none && x.eta && x.eta!=="stabil" && x.eta!=="–");
  return r.length ? r.map(x=>"- "+x.label+": "+(x.perMin>=0?"+":"")+fmt(x.perMin)+"/min, "+x.eta).join("\n") : "keine kritische Entwicklung";
}
function aiPrompt(c){
  const rt=rangeLabel();
  return ["Diagramm: "+c.spec.title,
    c.spec.desc?("Bedeutung: "+c.spec.desc.replace(/\n/g," ")):"",
    "Zeitfenster: "+rt+" · Einheit: "+(c.unit||"—"), "",
    "Kennzahlen je Serie (Ø / Min / Max / Aktuell / Trend seit Fensterbeginn):",
    statsAsText(c.stats), "",
    "Erkannte Ausreißer (robuste MAD-Analyse):", anomsAsText(c.anoms), "",
    "Prognose (lineare Extrapolation):", forecastAsText(c.fc), "",
    "Werte das aus: (1) Zustand einordnen, (2) Ausreißer/Trends bewerten, "+
    "(3) bei mehreren Serien ein kurzer Vergleich, (4) Risiko/Sättigung aus der Prognose, "+
    "(5) konkrete Handlungsempfehlung falls nötig. Maximal 6 Sätze, Zahlen nicht bloß wiederholen."
    ].filter(Boolean).join("\n");
}
let anCur=null;
function openAnalysis(id){
  const spec=CHARTS.find(c=>c.id===id); if(!spec)return;
  const stats=chartStats(spec), unit=unitOf(spec), anoms=chartAnoms(spec), fc=chartForecast(spec);
  anCur={spec,stats,unit,anoms,fc};
  document.getElementById("an_title").textContent=spec.title;
  document.getElementById("an_extra").style.display="";
  document.getElementById("an_stats").innerHTML=renderStats(stats);
  document.getElementById("an_anom").innerHTML=renderAnoms(anoms);
  document.getElementById("an_fc").innerHTML=renderForecast(fc);
  document.getElementById("an_ai").textContent="Noch keine Auswertung generiert.";
  document.getElementById("an_aimeta").textContent="";
  const gen=document.getElementById("an_gen"); gen.disabled=false; gen.textContent="KI-Auswertung generieren";
  document.getElementById("analysis").classList.add("open");
}
function closeAnalysis(){ document.getElementById("analysis").classList.remove("open"); }
function buildReportPrompt(){
  const rt=rangeLabel();
  const lines=["Gesamt-Report über alle Monitoring-Diagramme.","Zeitfenster: "+rt,""];
  CHARTS.forEach(spec=>{
    const stats=chartStats(spec); if(!stats.some(s=>s.n))return;
    lines.push("### "+spec.title, statsAsText(stats));
    const an=anomsAsText(chartAnoms(spec)); if(an!=="keine Ausreißer") lines.push("Ausreißer: "+an.replace(/\n/g,"; "));
    const fc=forecastAsText(chartForecast(spec)); if(fc!=="keine kritische Entwicklung") lines.push("Prognose: "+fc.replace(/\n/g,"; "));
    lines.push("");
  });
  lines.push("Erstelle einen kompakten Betriebs-Report auf Deutsch: (1) Gesamtzustand in 1–2 Sätzen, "+
    "(2) wichtigste Auffälligkeiten/Risiken über alle Metriken, (3) kurzer Vergleich der Modelle, "+
    "(4) konkrete Handlungsempfehlungen. Kurze Absätze, maximal ~12 Sätze.");
  return lines.join("\n");
}
function openReport(){
  if(!lastData){ return; }
  anCur={report:true};
  document.getElementById("an_title").textContent="KI-Gesamt-Report";
  document.getElementById("an_stats").innerHTML='<div style="color:var(--muted);font-size:12px">Aggregiert Kennzahlen, Ausreißer und Prognosen <b>aller</b> Diagramme und lässt sie von der KI bewerten.</div>';
  document.getElementById("an_extra").style.display="none";
  document.getElementById("an_ai").textContent="Noch keine Auswertung generiert.";
  document.getElementById("an_aimeta").textContent="";
  const gen=document.getElementById("an_gen"); gen.disabled=false; gen.textContent="KI-Report generieren";
  document.getElementById("analysis").classList.add("open");
}
async function runAI(){
  if(!anCur)return;
  const out=document.getElementById("an_ai"), meta=document.getElementById("an_aimeta"), gen=document.getElementById("an_gen");
  const serverConfigured=lastConfig&&lastConfig.ai&&lastConfig.ai.configured;
  if(!serverConfigured){ out.textContent='Kein KI-Endpunkt konfiguriert. Bitte server-seitig VLLM_AI_URL / VLLM_AI_MODEL setzen (z. B. über setup.sh).'; return; }
  gen.disabled=true; out.textContent="KI wertet aus …"; meta.textContent=""; const t0=Date.now();
  try{
    const user=anCur.report?buildReportPrompt():aiPrompt(anCur);
    const bd=anCur.report?{user,max_tokens:3000}:{user};
    const r=await fetch("/api/analyze",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify(bd)});
    const j=await r.json();
    if(j.error){ out.textContent="⚠️ "+j.error; }
    else { out.textContent=j.text||"(leere Antwort)"; meta.textContent="Modell "+(j.model||"")+" · "+((Date.now()-t0)/1000).toFixed(1)+" s"; }
  }catch(e){ out.textContent="⚠️ Fehler: "+e; }
  gen.disabled=false; gen.textContent="Neu generieren";
}
document.getElementById("an_gen").onclick=runAI;
document.getElementById("reportbtn").onclick=openReport;
document.getElementById("an_close").onclick=closeAnalysis;
document.getElementById("analysis").addEventListener("click",e=>{ if(e.target.id==="analysis")closeAnalysis(); });
document.getElementById("an_copy").onclick=()=>{
  if(!anCur)return;
  const ai=document.getElementById("an_ai").textContent;
  const txt = anCur.report
    ? "KI-Gesamt-Report\n\n"+ai
    : anCur.spec.title+"\n\n"+statsAsText(anCur.stats)+
      "\n\nAusreißer:\n"+anomsAsText(anCur.anoms)+
      "\n\nPrognose:\n"+forecastAsText(anCur.fc)+
      "\n\nKI-Auswertung:\n"+ai;
  if(navigator.clipboard)navigator.clipboard.writeText(txt).catch(()=>{});
};

buildGrid();
applyTheme(store.get("vllm_theme")||"dark");
// Anomalie-Marker in allen Diagrammen (Umschalter, Zustand im Cookie)
window._anomOn = store.get("vllm_anom")==="1";
(function(){
  const b=document.getElementById("anombtn");
  const sync=()=>b.classList.toggle("activebtn",window._anomOn);
  sync();
  b.onclick=()=>{ window._anomOn=!window._anomOn; store.set("vllm_anom",window._anomOn?"1":"0"); sync();
    if(lastData) redrawCharts(lastData.models); };
})();
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
document.getElementById("range").onchange=()=>{store.set("vllm_range",rangeSel());
  document.getElementById("absrange").style.display=isAbs()?"":"none";
  if(isAbs())ensureAbsDefaults();
  fetchConfig();startRefresh();fetchCompare();fetchAnnotations();};
document.getElementById("absapply").onclick=applyAbs;
["absfrom","absto"].forEach(id=>document.getElementById(id).addEventListener("change",()=>{ if(isAbs())applyAbs(); }));
document.getElementById("annbtn").onclick=addAnnotation;
document.getElementById("compare").onchange=()=>{store.set("vllm_compare",document.getElementById("compare").value);fetchCompare();};
// --- Instanzen verwalten (targets.json über /api/targets) ---
let _editId=null;
function tgtResetForm(){
  _editId=null;
  document.getElementById("tgt-add").textContent="Hinzufügen";
  document.getElementById("tgt-host").value=""; document.getElementById("tgt-port").value=""; document.getElementById("tgt-label").value="";
}
async function loadTargets(){
  const tb=document.querySelector("#tgttable tbody"); if(!tb)return;
  tgtResetForm();
  try{
    const j=await(await fetch("/api/targets")).json();
    tb.innerHTML="";
    const ts=j.targets||[];
    if(!ts.length){ tb.innerHTML='<tr><td colspan="6" class="placeholder">Noch keine Instanzen.</td></tr>'; return; }
    ts.forEach(t=>{
      const tr=document.createElement("tr");
      tr.innerHTML='<td>'+t.kind+'</td><td>'+t.host+'</td><td>'+t.port+'</td><td>'+(t.label||"")+'</td>'+
        '<td style="text-align:center"><input type="checkbox" '+(t.enabled!==false?"checked":"")+'></td>'+
        '<td style="white-space:nowrap;text-align:right"><button class="cbtn edit" title="Bearbeiten">✎</button> '+
        '<button class="cbtn close" title="Entfernen">×</button></td>';
      tr.querySelector('input[type=checkbox]').onchange=e=>saveTarget(Object.assign({},t,{enabled:e.target.checked}));
      tr.querySelector('.cbtn.edit').onclick=()=>editTarget(t);
      tr.querySelector('.cbtn.close').onclick=()=>delTarget(t);
      tb.appendChild(tr);
    });
  }catch(e){}
}
function editTarget(t){
  document.getElementById("tgt-kind").value=t.kind;
  document.getElementById("tgt-host").value=t.host;
  document.getElementById("tgt-port").value=t.port;
  document.getElementById("tgt-label").value=t.label||"";
  _editId=t.kind+":"+t.host+":"+t.port;
  document.getElementById("tgt-add").textContent="Speichern";
  document.getElementById("tgt-msg").textContent="Bearbeiten – Werte anpassen und 'Speichern'.";
  document.getElementById("tgt-host").focus();
}
async function saveTarget(t){
  try{ await fetch("/api/targets",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(t)}); }catch(e){}
  loadTargets();
}
async function delTarget(t){
  try{ const r=await(await fetch("/api/targets?id="+encodeURIComponent(t.kind+":"+t.host+":"+t.port),{method:"DELETE"})).json();
    if(r&&r.error){ document.getElementById("tgt-msg").textContent="⚠️ "+r.error; return; } }catch(e){}
  loadTargets();
}
document.getElementById("targetsbtn").onclick=()=>{ document.getElementById("targetmodal").style.display="flex"; loadTargets(); };
document.getElementById("tgt-close").onclick=()=>document.getElementById("targetmodal").style.display="none";
document.getElementById("targetmodal").onclick=e=>{ if(e.target===e.currentTarget) e.currentTarget.style.display="none"; };
document.getElementById("tgt-add").onclick=async()=>{
  const kind=document.getElementById("tgt-kind").value;
  const host=document.getElementById("tgt-host").value.trim();
  const port=document.getElementById("tgt-port").value.trim();
  const label=document.getElementById("tgt-label").value.trim();
  const msg=document.getElementById("tgt-msg");
  if(!host||!port){ msg.textContent="Host und Port sind erforderlich."; return; }
  const editing=_editId, newId=kind+":"+host+":"+port;
  try{
    const r=await(await fetch("/api/targets",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({kind,host,port,label,enabled:true})})).json();
    if(r.error){ msg.textContent="⚠️ "+r.error; return; }
    // Bei geänderter Host/Port-Kombination den alten Eintrag entfernen
    if(editing && editing!==newId){
      try{ await fetch("/api/targets?id="+encodeURIComponent(editing),{method:"DELETE"}); }catch(e){}
    }
    msg.textContent=(editing?"Gespeichert":"Hinzugefügt")+" – wird beim nächsten Scrape (≤ 15 s) übernommen.";
    loadTargets();
  }catch(e){ msg.textContent="Fehler: "+e; }
};
document.getElementById("hostfilter").onchange=()=>{hostFilter=document.getElementById("hostfilter").value;store.set("vllm_host",hostFilter);
  renderInstances();renderKPIs();if(lastData)redrawCharts(lastData.models);};
document.getElementById("pct").onchange=()=>{if(lastData)applySeries(lastData);};
document.getElementById("mode").onchange=startRefresh;
document.getElementById("reload").onclick=()=>{fetchConfig();fetchOnce();};
document.getElementById("resetzoom").onclick=()=>Object.values(charts).forEach(c=>c.resetZoom&&c.resetZoom());
document.getElementById("export").onclick=exportCSV;
document.getElementById("exportjson").onclick=()=>lastData&&download("vllm_metrics.json",JSON.stringify(lastData,null,2),"application/json");
document.getElementById("theme").onclick=()=>applyTheme(document.body.dataset.theme==="dark"?"light":"dark");
document.getElementById("restore").onclick=()=>{ saveHidden([]); applyHidden(); };
// KPI-Karten (Modelle & GPU) einklappbar (Default aufgeklappt)
(function(){
  const kc=document.getElementById("kpicard"), kt=document.getElementById("kpitoggle");
  const sync=()=>{ kt.textContent = kc.classList.contains("collapsed") ? "▸" : "▾"; };
  if(store.get("vllm_kpi_collapsed")==="1") kc.classList.add("collapsed");
  sync();
  kt.onclick=()=>{ store.set("vllm_kpi_collapsed", kc.classList.toggle("collapsed")?"1":"0"); sync(); };
})();
// Diagramm-Container: Kacheldichte-Buttons aus der Titelleiste in die Überschrift,
// Container einklappbar (Default aufgeklappt)
(function(){
  const slot=document.getElementById("densslot"), dg=document.querySelector(".densgroup");
  if(slot&&dg){ slot.appendChild(dg);
    // Klick auf die Rasterbuttons darf weder Umordnen noch Auf-/Zuklappen auslösen
    ["pointerdown","mousedown","click"].forEach(ev=>dg.addEventListener(ev,e=>e.stopPropagation())); }
  const cc=document.getElementById("chartcard"), ct=document.getElementById("charttoggle");
  const sync=()=>{ ct.textContent = cc.classList.contains("collapsed") ? "▸" : "▾"; };
  if(store.get("vllm_chart_collapsed")==="1") cc.classList.add("collapsed");
  sync();
  ct.onclick=()=>{ const now=cc.classList.toggle("collapsed"); store.set("vllm_chart_collapsed", now?"1":"0"); sync();
    if(!now) setTimeout(()=>Object.values(charts).forEach(c=>{try{c.resize();}catch(e){}}),60); };
})();
// Reihenfolge der Bereiche (Container) per Drag & Drop – Griff = Bereichs-Überschrift
(function(){
  const cont=document.getElementById("sections"); if(!cont)return;
  const saved=JSON.parse(store.get("vllm_section_order")||"null");
  if(saved&&saved.length) saved.forEach(id=>{
    const el=cont.querySelector(':scope > [data-id="'+id+'"]'); if(el)cont.appendChild(el);
  });
  makeSortable(cont,()=>{ saveOrder(cont,"vllm_section_order");
    setTimeout(()=>Object.values(charts).forEach(c=>{try{c.resize();}catch(e){}}),80); },".sgrip",true);
  // Klick auf die Bereichs-Überschrift (nicht auf den Griff/Rasterbuttons) klappt auf/zu
  cont.querySelectorAll(":scope > .card > h2").forEach(h=>{
    h.addEventListener("click",e=>{ if(e.target.closest(".sgrip,.densgroup"))return;
      const btn=h.parentElement.querySelector(".cardbtns .cbtn"); if(btn)btn.click(); });
  });
})();
// Instanzen-Karte einklappbar (Zustand im Cookie)
(function(){
  const ic=document.getElementById("instcard"), it=document.getElementById("insttoggle");
  const sync=()=>{ it.textContent = ic.classList.contains("collapsed") ? "▸" : "▾"; };
  if(store.get("vllm_inst_collapsed")==="1") ic.classList.add("collapsed");
  sync();
  it.onclick=()=>{ store.set("vllm_inst_collapsed", ic.classList.toggle("collapsed")?"1":"0"); sync(); };
})();
// Alarm-Historie: einklappbar (Default eingeklappt) + Laden/Rendern
(function(){
  const ac=document.getElementById("alertcard"), at=document.getElementById("alerttoggle");
  const sync=()=>{ at.textContent = ac.classList.contains("collapsed") ? "▸" : "▾"; };
  if(store.get("vllm_alert_collapsed")!=="0") ac.classList.add("collapsed"); else ac.classList.remove("collapsed");
  sync();
  at.onclick=()=>{ store.set("vllm_alert_collapsed", ac.classList.toggle("collapsed")?"1":"0"); sync(); };
})();
const EV_LABEL={offline:"Offline",kv:"KV-Cache",temp:"GPU-Temp",error:"Fehler"};
function renderAlerts(j){
  const tb=document.querySelector("#alerttable tbody"); if(!tb)return;
  const ev=(j&&j.events)||[]; tb.innerHTML="";
  const cnt=document.getElementById("alertcount");
  const active=ev.filter(e=>e.state==="raised").length;
  if(cnt) cnt.textContent = ev.length ? "· "+ev.length+" Ereignisse" : "· keine";
  if(!ev.length){ tb.innerHTML='<tr><td colspan="5" class="placeholder">Noch keine Alarm-Ereignisse.</td></tr>'; return; }
  ev.forEach(e=>{
    const t=new Date(e.ts).toLocaleString("de-DE");
    const stCls="ev-"+e.state+(e.severity==="crit"?" ev-crit":"");
    const stTxt=e.state==="raised"?"⬤ ausgelöst":"○ behoben";
    const who=(e.model?shortModel(e.model):("Port "+e.port));
    tb.innerHTML+=`<tr><td>${t}</td><td class="${stCls}">${stTxt}</td>`+
      `<td><span class="evbadge">${EV_LABEL[e.kind]||e.kind}</span></td>`+
      `<td>${who}</td><td>${e.message||""}</td></tr>`;
  });
}
async function fetchAlerts(){try{renderAlerts(await(await fetch("/api/alerts?limit=100")).json());}catch(e){}}
// --- Zeitachsen-Annotationen (Deploy/Restart …) ---
async function fetchAnnotations(){
  try{ const q=isAbs()?(()=>{const w=absWindow();return w?"from="+w.from+"&to="+w.to:"range="+rangeVal();})():"range="+rangeVal();
    const j=await(await fetch("/api/annotations?"+q)).json();
    annotations=j.annotations||[]; Object.values(charts).forEach(o=>o.draw()); }catch(e){}
}
async function addAnnotation(){
  const label=prompt('Annotation für den aktuellen Zeitpunkt (z. B. „Deploy v0.22.2"):');
  if(!label||!label.trim())return;
  try{ await fetch("/api/annotations",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({label:label.trim()})}); fetchAnnotations(); }catch(e){}
}
async function delAnnotation(id){
  try{ await fetch("/api/annotations?id="+id,{method:"DELETE"}); fetchAnnotations(); }catch(e){}
}
// Effizienz-Karte einklappbar
(function(){
  const ec=document.getElementById("effcard"), et=document.getElementById("efftoggle");
  const sync=()=>{ et.textContent = ec.classList.contains("collapsed") ? "▸" : "▾"; };
  if(store.get("vllm_eff_collapsed")!=="0") ec.classList.add("collapsed"); else ec.classList.remove("collapsed");
  sync();
  et.onclick=()=>{ store.set("vllm_eff_collapsed", ec.classList.toggle("collapsed")?"1":"0"); sync(); };
})();
function avgField(series,key){ let s=0,n=0; series.forEach(p=>{const v=p[key]; if(v!=null&&!isNaN(v)){s+=v;n++;}}); return n?s/n:null; }
function fmtBig(v){ if(v==null)return "–"; const a=Math.abs(v);
  if(a>=1e9)return (v/1e9).toFixed(1)+" Mrd"; if(a>=1e6)return (v/1e6).toFixed(1)+" Mio";
  if(a>=1e3)return (v/1e3).toFixed(0)+" Tsd"; return Math.round(v).toString(); }
function renderEfficiency(){
  const body=document.getElementById("effbody"); if(!body||!lastData)return;
  let totTps=0, gpuUtil=null, gpuPow=null;
  Object.keys(lastData.models).forEach(m=>{
    const inst=lastConfig?lastConfig.instances.find(x=>x.model===m):null;
    const kind=inst?inst.kind:"vllm"; const s=lastData.models[m];
    if(kind==="gpu"){ gpuUtil=avgField(s,"gpu_util"); gpuPow=avgField(s,"gpu_power"); return; }
    totTps += avgField(s,"gen_tps")||0;
  });
  const M=(v,l)=>'<div class="metric"><b>'+v+'</b>'+l+'</div>';
  let h="";
  h+=M(fmtBig(totTps*86400),"Tokens/Tag (gesamt)");
  h+=M(num(totTps,1),"gen tok/s Ø (gesamt)");
  if(gpuUtil!=null) h+=M(num(gpuUtil,0)+" %","GPU-Auslastung Ø");
  if(gpuUtil!=null) h+=M(num(gpuUtil/100*24,1)+" h","GPU-Vollast-Std./Tag");
  if(gpuPow!=null) h+=M(num(gpuPow,0)+" W","GPU-Leistung Ø");
  if(gpuPow) h+=M(num(totTps/gpuPow,2),"tok/s pro Watt");
  body.innerHTML=h||'<span class="placeholder">Keine Daten.</span>';
}
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
// Zuletzt gewählten Zeitraum + Vergleich aus dem Cookie wiederherstellen
(function(){
  const saved=store.get("vllm_range"), sel=document.getElementById("range");
  if(saved && [...sel.options].some(o=>o.value===saved)) sel.value=saved;
  const af=store.get("vllm_absfrom"), at=store.get("vllm_absto");
  if(af) document.getElementById("absfrom").value=af;
  if(at) document.getElementById("absto").value=at;
  if(sel.value==="custom"){ ensureAbsDefaults(); document.getElementById("absrange").style.display=""; }
  const sc=store.get("vllm_compare"), cs=document.getElementById("compare");
  if(sc && [...cs.options].some(o=>o.value===sc)) cs.value=sc;
})();
// --- Dashboard erst nach erfolgreicher Anmeldung starten ---
let _booted=false;
function bootDashboard(){
  if(_booted)return; _booted=true;
  fetchConfig(); startRefresh(); fetchAlerts(); fetchCompare(); fetchAnnotations();
  setInterval(fetchConfig,30000); setInterval(fetchAlerts,30000); setInterval(fetchAnnotations,30000);
}

// ===================== Authentifizierung =====================
function _esc(s){return String(s==null?"":s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));}
async function authInit(){
  let me; try{ me=await(await fetch("/api/me")).json(); }catch(e){ me={authenticated:false}; }
  applyAuthState(me);
}
function applyAuthState(me){
  window._me=me;
  const ov=document.getElementById("authov");
  if(!me.authenticated){ showLogin(); return; }
  if(me.must_change){ showPasswordChange(); return; }
  ov.classList.remove("show");
  document.getElementById("logincard").style.display="";
  document.getElementById("pwcard").style.display="none";
  document.body.classList.toggle("is-admin", me.role==="admin");
  const uc=document.getElementById("userchip"); uc.style.display="";
  document.getElementById("logoutbtn").style.display="";
  document.getElementById("username").textContent=me.username;
  const rb=document.getElementById("userrole");
  rb.textContent=me.role==="admin"?"Admin":"Read-only";
  rb.className="rolebadge"+(me.role==="admin"?" admin":"");
  bootDashboard();
}
function showLogin(){
  const ov=document.getElementById("authov");
  document.getElementById("logincard").style.display="";
  document.getElementById("pwcard").style.display="none";
  ov.classList.add("show");
  setTimeout(()=>{try{document.getElementById("li-user").focus();}catch(e){}},50);
}
function showPasswordChange(){
  const ov=document.getElementById("authov");
  document.getElementById("logincard").style.display="none";
  document.getElementById("pwcard").style.display="";
  ov.classList.add("show");
  setTimeout(()=>{try{document.getElementById("pw-old").focus();}catch(e){}},50);
}
async function doLogin(){
  const u=document.getElementById("li-user").value.trim();
  const p=document.getElementById("li-pass").value;
  const msg=document.getElementById("li-msg"); msg.textContent="";
  if(!u||!p){ msg.textContent="Benutzer und Passwort eingeben."; return; }
  let r; try{ r=await fetch("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({username:u,password:p})}); }catch(e){ msg.textContent="Netzwerkfehler."; return; }
  document.getElementById("li-pass").value="";
  if(!r.ok){ msg.textContent="Anmeldung fehlgeschlagen – Benutzer/Passwort prüfen."; return; }
  const j=await r.json();
  if(j.must_change){ showPasswordChange(); return; }
  authInit();
}
async function doPassword(){
  const o=document.getElementById("pw-old").value, n=document.getElementById("pw-new").value, n2=document.getElementById("pw-new2").value;
  const msg=document.getElementById("pw-msg"); msg.textContent="";
  if(n.length<6){ msg.textContent="Neues Passwort muss mindestens 6 Zeichen haben."; return; }
  if(n!==n2){ msg.textContent="Die neuen Passwörter stimmen nicht überein."; return; }
  let j; try{ j=await(await fetch("/api/password",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({old:o,new:n})})).json(); }catch(e){ msg.textContent="Netzwerkfehler."; return; }
  if(j.error){ msg.textContent=j.error; return; }
  document.getElementById("pw-old").value=document.getElementById("pw-new").value=document.getElementById("pw-new2").value="";
  authInit();
}
async function doLogout(){ try{ await fetch("/api/logout",{method:"POST"}); }catch(e){} location.reload(); }
document.getElementById("li-submit").onclick=doLogin;
document.getElementById("li-pass").addEventListener("keydown",e=>{if(e.key==="Enter")doLogin();});
document.getElementById("li-user").addEventListener("keydown",e=>{if(e.key==="Enter")document.getElementById("li-pass").focus();});
document.getElementById("pw-submit").onclick=doPassword;
document.getElementById("pw-new2").addEventListener("keydown",e=>{if(e.key==="Enter")doPassword();});
document.getElementById("logoutbtn").onclick=doLogout;

// ---- Benutzer- & Zugriffsverwaltung (nur Admins) ----
function umsg(t,ok){ const e=document.getElementById("usr-msg"); e.textContent=t||""; e.style.color=ok?"var(--good)":"var(--bad)"; }
function openUsers(){ document.getElementById("usermodal").style.display="flex"; loadUsers(); }
document.getElementById("usersbtn").onclick=openUsers;
document.getElementById("usr-close").onclick=()=>document.getElementById("usermodal").style.display="none";
document.getElementById("usermodal").onclick=e=>{ if(e.target===e.currentTarget) e.currentTarget.style.display="none"; };
async function loadUsers(){
  let j; try{ j=await(await fetch("/api/users")).json(); }catch(e){ umsg("Laden fehlgeschlagen."); return; }
  if(j.error){ umsg(j.error); return; }
  const lt=document.querySelector("#localtable tbody"); lt.innerHTML="";
  (j.users||[]).forEach(u=>{
    const tr=document.createElement("tr");
    tr.innerHTML=`<td>${_esc(u.username)}</td>
      <td><select class="uinput r"><option value="admin"${u.role==="admin"?" selected":""}>Admin</option>
        <option value="readonly"${u.role==="readonly"?" selected":""}>Read-only</option></select></td>
      <td style="color:var(--muted)">${u.must_change?"Passwortwechsel offen":"aktiv"}</td>
      <td style="text-align:right;white-space:nowrap">
        <button class="cbtn pw" title="Passwort zurücksetzen">🔑</button>
        <button class="cbtn del" title="Löschen">🗑</button></td>`;
    const role=()=>tr.querySelector("select.r").value;
    tr.querySelector("select.r").onchange=()=>saveRole("local",u.username,role());
    tr.querySelector("button.del").onclick=()=>delUser("local",u.username);
    tr.querySelector("button.pw").onclick=()=>resetPw("local",u.username,role());
    lt.appendChild(tr);
  });
  const at=document.querySelector("#adtable tbody"); at.innerHTML="";
  (j.ad_users||[]).forEach(u=>{
    const tr=document.createElement("tr");
    tr.innerHTML=`<td>${_esc(u.username)}</td>
      <td><select class="uinput r"><option value="admin"${u.role==="admin"?" selected":""}>Admin</option>
        <option value="readonly"${u.role==="readonly"?" selected":""}>Read-only</option></select></td>
      <td style="text-align:right"><button class="cbtn del" title="Löschen">🗑</button></td>`;
    tr.querySelector("select.r").onchange=()=>saveRole("ad",u.username,tr.querySelector("select.r").value);
    tr.querySelector("button.del").onclick=()=>delUser("ad",u.username);
    at.appendChild(tr);
  });
  const L=j.ldap||{};
  document.getElementById("ld-enabled").checked=!!L.enabled;
  document.getElementById("ld-host").value=L.host||"";
  document.getElementById("ld-domain").value=L.domain||"";
  document.getElementById("ld-tls").value=L.tls||"auto";
  document.getElementById("ld-base").value=L.base_dn||"";
  document.getElementById("ld-gadmin").value=L.group_admin||"";
  document.getElementById("ld-gro").value=L.group_readonly||"";
  document.getElementById("ld-defrole").value=L.default_role||"";
  umsg("");
}
async function postUsers(body){
  const j=await(await fetch("/api/users",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify(body)})).json();
  if(j.error){ umsg(j.error); } else { umsg("Gespeichert.",true); }
  return j;
}
async function saveRole(kind,username,role){ const j=await postUsers({kind,username,role}); if(!j.error)loadUsers(); }
async function resetPw(kind,username,role){ const p=prompt("Neues Passwort für "+username+":"); if(!p)return;
  const j=await postUsers({kind,username,role,password:p,must_change:false}); if(!j.error)loadUsers(); }
async function delUser(kind,username){ if(!confirm(username+" wirklich löschen?"))return;
  const j=await(await fetch("/api/users?username="+encodeURIComponent(username)+"&kind="+kind,{method:"DELETE"})).json();
  if(j.error)umsg(j.error); else { umsg("Gelöscht.",true); loadUsers(); } }
document.getElementById("nu-add").onclick=async()=>{
  const name=document.getElementById("nu-name").value.trim(), pass=document.getElementById("nu-pass").value;
  if(!name||!pass){ umsg("Name und Passwort angeben."); return; }
  const j=await postUsers({kind:"local",username:name,password:pass,role:document.getElementById("nu-role").value,
    must_change:document.getElementById("nu-mc").checked});
  if(!j.error){ document.getElementById("nu-name").value=document.getElementById("nu-pass").value=""; loadUsers(); }
};
document.getElementById("na-add").onclick=async()=>{
  const name=document.getElementById("na-name").value.trim();
  if(!name){ umsg("Benutzername angeben."); return; }
  const j=await postUsers({kind:"ad",username:name,role:document.getElementById("na-role").value});
  if(!j.error){ document.getElementById("na-name").value=""; loadUsers(); }
};
function ldapFormBody(){ return {
  enabled:document.getElementById("ld-enabled").checked,
  host:document.getElementById("ld-host").value.trim(),
  domain:document.getElementById("ld-domain").value.trim(),
  tls:document.getElementById("ld-tls").value,
  base_dn:document.getElementById("ld-base").value.trim(),
  group_admin:document.getElementById("ld-gadmin").value.trim(),
  group_readonly:document.getElementById("ld-gro").value.trim(),
  default_role:document.getElementById("ld-defrole").value }; }
document.getElementById("ld-save").onclick=async()=>{
  const j=await(await fetch("/api/ldap",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify(ldapFormBody())})).json();
  if(j.error)umsg(j.error); else umsg("LDAP-Konfiguration gespeichert.",true);
};
document.getElementById("ld-test").onclick=async()=>{
  const b=ldapFormBody(); b.username=document.getElementById("ld-tuser").value.trim();
  b.password=document.getElementById("ld-tpass").value;
  if(!b.username||!b.password){ umsg("Test-Benutzer und -Passwort angeben."); return; }
  umsg("Teste Verbindung …"); document.getElementById("usr-msg").style.color="var(--muted)";
  let j; try{ j=await(await fetch("/api/ldap/test",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify(b)})).json(); }catch(e){ umsg("Netzwerkfehler."); return; }
  if(j.ok){ umsg("✓ Bind erfolgreich – Rolle: "+j.role+((j.groups&&j.groups.length)?(" · "+j.groups.length+" Gruppe(n)"):""),true); }
  else umsg("✗ "+(j.error||"Test fehlgeschlagen."));
};
// ---- Verzeichnissuche (AD-Benutzer/-Gruppen) ----
async function doDirSearch(){
  const kind=document.getElementById("ds-kind").value;
  const q=document.getElementById("ds-q").value.trim();
  const box=document.getElementById("ds-results");
  const b=ldapFormBody(); b.kind=kind; b.q=q;
  b.username=document.getElementById("ld-tuser").value.trim();
  b.password=document.getElementById("ld-tpass").value;
  if(!b.username||!b.password){ umsg("Für die Suche Test-Benutzer/-Passwort oben eingeben."); return; }
  if(!q){ umsg("Suchbegriff eingeben."); return; }
  box.innerHTML='<span style="color:var(--muted);font-size:12px">Suche …</span>';
  let j; try{ j=await(await fetch("/api/ldap/search",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify(b)})).json(); }catch(e){ box.innerHTML=""; umsg("Netzwerkfehler."); return; }
  if(j.error){ box.innerHTML=""; umsg(j.error); return; }
  umsg("");
  const rs=j.results||[];
  if(!rs.length){ box.innerHTML='<span style="color:var(--muted);font-size:12px">Keine Treffer.</span>'; return; }
  box.innerHTML="";
  rs.forEach(r=>{
    const row=document.createElement("div");
    row.style.cssText="display:flex;gap:6px;align-items:center;padding:4px 0;border-bottom:1px solid var(--grid);font-size:13px";
    if(kind==="group"){
      row.innerHTML=`<span style="flex:1;min-width:0">${_esc(r.name)}<span style="color:var(--muted);font-size:11px"> ${_esc(r.dn||"")}</span></span>`;
      const bA=document.createElement("button"); bA.className="cbtn"; bA.title="Als Admin-Gruppe übernehmen"; bA.textContent="→ Admin";
      bA.onclick=()=>{ document.getElementById("ld-gadmin").value=r.name; umsg("Admin-Gruppe gesetzt: "+r.name+" (noch 'LDAP speichern')",true); };
      const bR=document.createElement("button"); bR.className="cbtn"; bR.title="Als Read-only-Gruppe übernehmen"; bR.textContent="→ RO";
      bR.onclick=()=>{ document.getElementById("ld-gro").value=r.name; umsg("Read-only-Gruppe gesetzt: "+r.name+" (noch 'LDAP speichern')",true); };
      row.appendChild(bA); row.appendChild(bR);
    } else {
      row.innerHTML=`<span style="flex:1;min-width:0">${_esc(r.display||r.name)}<span style="color:var(--muted);font-size:11px"> ${_esc(r.name)}</span></span>`;
      const bU=document.createElement("button"); bU.className="cbtn"; bU.title="In AD-Freigabe übernehmen"; bU.textContent="→ Freigabe";
      bU.onclick=()=>{ document.getElementById("na-name").value=r.name; umsg("Übernommen: "+r.name+" – Rolle wählen und 'Freigeben'.",true); };
      row.appendChild(bU);
    }
    box.appendChild(row);
  });
}
document.getElementById("ds-go").onclick=doDirSearch;
document.getElementById("ds-q").addEventListener("keydown",e=>{if(e.key==="Enter")doDirSearch();});

// ---- Alarm-Schwellwerte (nur Admins) ----
function openThresh(){
  const th=(lastConfig&&lastConfig.thresholds)||{};
  document.getElementById("th-temp").value=th.temp!=null?th.temp:85;
  document.getElementById("th-kv").value=th.kv!=null?th.kv:90;
  document.getElementById("th-err").value=th.err!=null?th.err:0;
  document.getElementById("th-offline").value=th.offline_min!=null?th.offline_min:1;
  document.getElementById("th-msg").textContent="";
  document.getElementById("threshmodal").style.display="flex";
}
document.getElementById("threshbtn").onclick=openThresh;
document.getElementById("th-close").onclick=()=>document.getElementById("threshmodal").style.display="none";
document.getElementById("threshmodal").onclick=e=>{ if(e.target===e.currentTarget) e.currentTarget.style.display="none"; };
document.getElementById("th-save").onclick=async()=>{
  const body={temp:parseFloat(document.getElementById("th-temp").value),
    kv:parseFloat(document.getElementById("th-kv").value),
    err:parseFloat(document.getElementById("th-err").value),
    offline_min:parseFloat(document.getElementById("th-offline").value)};
  const msg=document.getElementById("th-msg");
  for(const k in body){ if(isNaN(body[k])){ msg.style.color="var(--bad)"; msg.textContent="Bitte alle Felder gültig ausfüllen."; return; } }
  let j; try{ j=await(await fetch("/api/thresholds",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify(body)})).json(); }catch(e){ msg.style.color="var(--bad)"; msg.textContent="Netzwerkfehler."; return; }
  if(j.error){ msg.style.color="var(--bad)"; msg.textContent=j.error; return; }
  msg.style.color="var(--good)"; msg.textContent="Gespeichert – greift beim nächsten Scrape (≤ 15 s).";
  if(lastConfig) lastConfig.thresholds=j.thresholds;
  fetchConfig();
};

authInit();

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


_REPORT_FIELDS = [
    ("kv", "KV-Cache %"), ("running", "aktiv"), ("waiting", "wartend"),
    ("gen_tps", "gen tok/s"), ("prompt_tps", "prompt tok/s"),
    ("ttft_p95", "TTFT p95 ms"), ("e2e_p95", "E2E p95 s"), ("itl_p95", "ITL p95 ms"),
    ("hit_rate", "Prefix-Hit %"), ("error_ps", "Fehler/s"),
    ("gpu_util", "GPU %"), ("gpu_temp", "GPU °C"), ("gpu_power", "GPU W"),
]


def _summarize_series(range_s):
    models = build_series(range_s).get("models", {})
    lines = []
    for model in sorted(models):
        pts = models[model]
        if not pts:
            continue
        rows = []
        for key, label in _REPORT_FIELDS:
            vals = [p[key] for p in pts if isinstance(p.get(key), (int, float))]
            if not vals:
                continue
            rows.append("- %s: Ø %.2f, min %.2f, max %.2f, aktuell %.2f"
                        % (label, sum(vals) / len(vals), min(vals), max(vals), vals[-1]))
        if rows:
            lines.append("### %s" % model)
            lines.extend(rows)
            lines.append("")
    return "\n".join(lines)


def build_report(range_s=None):
    range_s = range_s or REPORT_RANGE
    stats = _summarize_series(range_s)
    ev = build_alerts(300).get("events", [])
    since = (int(time.time()) - range_s) * 1000
    evw = [e for e in ev if e["ts"] >= since]
    raised = sum(1 for e in evw if e["state"] == "raised")
    alert_txt = ("%d Ereignisse (%d ausgelöst)" % (len(evw), raised)) if evw else "keine Alarme"
    hours = round(range_s / 3600.0, 1)
    prompt = ("Betriebs-Report für die letzten %s Stunden eines vLLM-Servers.\n\n"
              "Kennzahlen je Modell:\n%s\n\nAlarme im Zeitraum: %s\n\n"
              "Erstelle einen kompakten deutschen Schicht-Report: (1) Gesamtzustand, "
              "(2) Auffälligkeiten/Alarme, (3) Modellvergleich, (4) Handlungsempfehlungen. "
              "Kurze Absätze, maximal ~12 Sätze." % (hours, stats or "keine Daten", alert_txt))
    ai = ai_analyze({"user": prompt, "max_tokens": 3000})
    return {"range_s": range_s, "hours": hours, "stats": stats,
            "alerts": alert_txt, "ai": ai.get("text") or ("[KI] " + ai.get("error", "")),
            "generated": int(time.time())}


def write_report(range_s=None):
    rep = build_report(range_s)
    os.makedirs(REPORT_DIR, exist_ok=True)
    path = os.path.join(REPORT_DIR, "report-%s.txt" % time.strftime("%Y%m%d-%H%M%S"))
    body = ("vLLM-Schicht-Report  %s  (Zeitfenster %sh)\n%s\n\n%s\n\n%s\nKennzahlen:\n%s\nAlarme: %s\n"
            % (time.strftime("%Y-%m-%d %H:%M"), rep["hours"], "=" * 60,
               rep["ai"], "-" * 60, rep["stats"] or "keine Daten", rep["alerts"]))
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)
    return path, body


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
    au = load_auth()
    n_local = len(au.get("users", []))
    default_admin = any(u.get("username") == "admin" and u.get("must_change") for u in au.get("users", []))
    ldap_on = bool(au.get("ldap", {}).get("enabled"))
    print("  [i] Authentifizierung aktiv: %d lokale(r) Nutzer, LDAP %s"
          % (n_local, "an (DC %s)" % au["ldap"].get("host", "?") if ldap_on else "aus"))
    if default_admin:
        print("  [!] Standard-Login admin/admin ist noch aktiv – bei der ersten Anmeldung im Browser ändern!")
    if scheme != "https":
        print("  [!] ACHTUNG: Login ohne HTTPS – Zugangsdaten gehen im Klartext übers Netz. TLS aktivieren!")
    print("DB: %s   (Strg+C zum Beenden)" % DB_PATH)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nDashboard beendet.")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "report":
        rng = None
        if len(sys.argv) > 2:
            try:
                rng = int(sys.argv[2])
            except ValueError:
                rng = None
        p, body = write_report(rng)
        print(body)
        print("\n[i] Report gespeichert: %s" % p)
    elif len(sys.argv) > 1 and sys.argv[1] == "annotate":
        # vllm_dashboard.sh annotate "Label" [ts_sekunden]   – z. B. aus Deploy-Skripten
        label = sys.argv[2] if len(sys.argv) > 2 else ""
        ts = None
        if len(sys.argv) > 3:
            try:
                ts = int(sys.argv[3])
            except ValueError:
                ts = None
        res = add_annotation(ts, label)
        print("Annotation angelegt: %s" % res if res.get("ok") else "Fehler: %s" % res.get("error"))
    else:
        main()
