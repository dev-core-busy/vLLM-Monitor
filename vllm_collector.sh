#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vllm_collector.sh – Dauerhafter Metrik-Sammler für vLLM-Server
==============================================================
Pullt in festem Intervall die Prometheus-/metrics-Endpunkte mehrerer
vLLM-Instanzen, parst die relevanten Kennzahlen (pro Modell) und schreibt
sie in eine lokale SQLite-Zeitreihen-Datenbank. Zusätzlich werden je Instanz
die statische Engine-Konfiguration (KV-Kapazität etc.) und der Health-Status
gepflegt. Alte Daten werden nach RETENTION_DAYS automatisch entfernt.

Datenquelle:  http://<HOST>:<PORT>/metrics   (OpenAI/vLLM, Prometheus-Format)
Ablage:       vllm_metrics.db  (SQLite, im selben Verzeichnis)

Bedienung:
  python3 vllm_collector.sh          – Dauerlauf (pullt alle INTERVAL Sekunden)
  python3 vllm_collector.sh once     – genau ein Scrape (zum Testen)
  python3 vllm_collector.sh status   – letzte gespeicherte Werte anzeigen

Konfiguration per Umgebungsvariablen:
  VLLM_HOST, VLLM_TARGETS="port:label,...", VLLM_INTERVAL,
  VLLM_RETENTION_DAYS, VLLM_HTTP_TIMEOUT

Nur Python-Standardbibliothek – keine externen Abhängigkeiten.
"""

import os
import re
import sys
import time
import json
import socket
import sqlite3
import signal
from urllib import request, error

__version__ = "0.19.0"

# ---------------------------------------------------------------------------
# Konfiguration  (alles per Umgebungsvariable überschreibbar)
# ---------------------------------------------------------------------------

HOST = os.environ.get("VLLM_HOST", "127.0.0.1")


def _parse_targets(spec):
    """"[host:]port[:label]" -> [{"host":.., "port":9081, "label":"Qwen"}, ...]

    Rückwärtskompatibel: "9081:Qwen" bleibt port:label (erstes Feld numerisch);
    "host:9081[:label]" (erstes Feld nicht-numerisch) ist host:port[:label].
    Ohne Host wird VLLM_HOST verwendet – so lassen sich mehrere Hosts mischen."""
    targets = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        bits = part.split(":")
        host = HOST
        if len(bits) == 1:
            port, label = bits[0], bits[0]
        elif len(bits) == 2:
            if bits[0].strip().isdigit():
                port, label = bits[0], bits[1]
            else:
                host, port, label = bits[0], bits[1], bits[1]
        else:
            host, port, label = bits[0], bits[1], ":".join(bits[2:])
        targets.append({"host": host.strip(), "port": int(port), "label": label.strip()})
    return targets


TARGETS = _parse_targets(os.environ.get("VLLM_TARGETS", "8000:default"))

INTERVAL = int(os.environ.get("VLLM_INTERVAL", "15"))
RETENTION_DAYS = int(os.environ.get("VLLM_RETENTION_DAYS", "30"))
HTTP_TIMEOUT = float(os.environ.get("VLLM_HTTP_TIMEOUT", "15"))
# Kurzer Timeout für Ollama-/STT-Erreichbarkeitsprüfungen (toter Host darf den
# Sammler nicht je Scrape ausbremsen).
OLLAMA_TIMEOUT = float(os.environ.get("VLLM_OLLAMA_TIMEOUT", "3"))
# Begrenzter Timeout für die Ollama-Generierungs-Probe. Die Probe läuft nur gegen
# BEREITS geladene Modelle (siehe scrape_ollama), damit kein Kalt-Ladevorgang eines
# großen Modells den ganzen Scrape-Loop blockiert und alle Instanzen „flackern".
OLLAMA_PROBE_TIMEOUT = float(os.environ.get("VLLM_OLLAMA_PROBE_TIMEOUT", "15"))
PURGE_EVERY = 240

# --- Schwellwerte für Alarme (Env = Default; im Dashboard editierbar -> settings.json) ---
ALERT_KV = float(os.environ.get("VLLM_ALERT_KV", "90"))                    # KV-Cache % (>)
ALERT_TEMP = float(os.environ.get("VLLM_ALERT_TEMP", "85"))               # GPU-Temperatur °C (>)
ALERT_ERR = float(os.environ.get("VLLM_ALERT_ERR", "0"))                  # neue Fehler je Scrape (>)
ALERT_OFFLINE_MIN = float(os.environ.get("VLLM_ALERT_OFFLINE_MIN", "1"))  # Minuten offline bis Alarm
# Entprellung: erst nach so vielen Sekunden ununterbrochener Nichterreichbarkeit
# wird eine Instanz als offline (up=0) angezeigt – vermeidet Rot/Grün-Flackern bei
# kurzen Netz-/Lastspitzen (z. B. ausgelasteter Ollama-Host).
OFFLINE_GRACE = float(os.environ.get("VLLM_OFFLINE_GRACE", "60"))

DB_PATH = os.environ.get("VLLM_DB") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "vllm_metrics.db")

# Über die Oberfläche verwaltete Zusatz-Instanzen (persistent, zur Laufzeit neu
# geladen) – ergänzen die per Env/Unit definierten Targets.
TARGETS_FILE = os.environ.get("VLLM_TARGETS_FILE") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "targets.json")

# Im Dashboard editierbare Schwellwerte (settings.json überschreibt die Env-Defaults;
# bei jedem Scrape neu gelesen, sodass Änderungen ohne Neustart greifen).
SETTINGS_FILE = os.environ.get("VLLM_SETTINGS_FILE") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "settings.json")
THRESH = {"kv": ALERT_KV, "temp": ALERT_TEMP, "err": ALERT_ERR, "offline_min": ALERT_OFFLINE_MIN}


def refresh_thresholds():
    """Lädt die Alarm-Schwellwerte aus settings.json (Fallback: Env-Defaults)."""
    defaults = {"kv": ALERT_KV, "temp": ALERT_TEMP, "err": ALERT_ERR, "offline_min": ALERT_OFFLINE_MIN}
    try:
        with open(SETTINGS_FILE) as f:
            t = json.load(f).get("thresholds", {})
    except (OSError, ValueError):
        t = {}
    for k, dv in defaults.items():
        try:
            THRESH[k] = float(t[k]) if k in t else dv
        except (ValueError, TypeError):
            THRESH[k] = dv


def _read_targets_file():
    try:
        with open(TARGETS_FILE) as f:
            data = json.load(f)
        return data.get("targets", []) if isinstance(data, dict) else []
    except (OSError, ValueError):
        return []


def _write_targets_file(targets):
    tmp = TARGETS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"targets": targets}, f, indent=2)
    os.replace(tmp, TARGETS_FILE)


def seed_vllm_from_env():
    """Übernimmt die per Env/Unit definierten vLLM-Instanzen EINMALIG in
    targets.json, damit sie im Dashboard verwaltet (bearbeitet/pausiert/gelöscht)
    werden können. Läuft nur, solange die Datei noch keinen vLLM-Eintrag hat."""
    existing = _read_targets_file()
    if any(t.get("kind") == "vllm" for t in existing) or not TARGETS:
        return
    have = {(t.get("host"), t.get("port")) for t in existing}
    seeded = list(existing)
    for t in TARGETS:
        key = (t.get("host", HOST), t["port"])
        if key in have:
            continue
        seeded.append({"kind": "vllm", "host": t.get("host", HOST), "port": t["port"],
                       "label": t.get("label") or "vLLM", "enabled": True})
    if len(seeded) != len(existing):
        try:
            _write_targets_file(seeded)
            print("  [i] %d vLLM-Instanz(en) aus der Unit nach %s übernommen "
                  "(jetzt im Dashboard verwaltbar)." % (len(seeded) - len(existing), TARGETS_FILE))
        except OSError as e:
            print("  [!] Konnte targets.json nicht seeden: %s" % e)


def _file_has_vllm():
    """True, sobald targets.json überhaupt einen vLLM-Eintrag hat (auch pausiert).
    Dann ist die Datei maßgeblich und die Env-Targets dienen nur noch als Seed."""
    return any(t.get("kind") == "vllm" for t in _read_targets_file())


def load_extra_targets():
    """Liest targets.json (vom Dashboard gepflegt). Nur aktivierte Einträge."""
    out = {"vllm": [], "ollama": [], "stt": [], "dcgm": [], "lmstudio": []}
    try:
        with open(TARGETS_FILE) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return out
    for t in data.get("targets", []):
        if not t.get("enabled", True):
            continue
        kind, host, port = t.get("kind"), t.get("host"), t.get("port")
        if not host or port is None or kind not in out:
            continue
        try:
            port = int(port)
        except (ValueError, TypeError):
            continue
        if kind == "dcgm":
            out["dcgm"].append((host, port))
        elif kind == "vllm":
            out["vllm"].append({"host": host, "port": port})
        else:  # ollama / stt / lmstudio
            out[kind].append({"host": host, "port": port, "label": t.get("label") or kind})
    return out


# --- Ollama (anderes API als vLLM: kein Prometheus /metrics) ---
def _parse_ollama(spec):
    """"127.0.0.1:11434:llama3, 11434:mistral" -> [{host,port,label}, ...]"""
    out = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        bits = part.split(":")
        if len(bits) >= 3:
            host, port, label = bits[0], int(bits[1]), ":".join(bits[2:])
        elif len(bits) == 2:
            host, port, label = HOST, int(bits[0]), bits[1]
        else:
            host, port, label = HOST, int(bits[0]), "ollama"
        out.append({"host": host, "port": port, "label": label.strip()})
    return out


OLLAMA_TARGETS = _parse_ollama(os.environ.get("VLLM_OLLAMA_TARGETS", ""))
OLLAMA_PROBE = os.environ.get("VLLM_OLLAMA_PROBE", "1").lower() not in ("0", "false", "no", "off")
OLLAMA_PROMPT = os.environ.get("VLLM_OLLAMA_PROMPT", "Antworte knapp in einem Satz: Hallo.")
OLLAMA_NUM_PREDICT = int(os.environ.get("VLLM_OLLAMA_NUM_PREDICT", "24"))

# le-Grenzen (Sekunden) für synthetische Latenz-Histogramme der Ollama-Probes
OLL_LE = {
    "ttft": [.001, .005, .01, .02, .04, .06, .08, .1, .25, .5, .75, 1, 2.5, 5, 7.5, 10, 20, 40, 80, 160, 640, 2560],
    "e2e":  [.3, .5, .8, 1, 1.5, 2, 2.5, 5, 10, 15, 20, 30, 40, 50, 60, 120, 240, 480, 960, 1920, 7680],
    "itl":  [.01, .025, .05, .075, .1, .15, .2, .3, .4, .5, .75, 1, 2.5, 5, 7.5, 10, 20, 40, 80],
}
_oll_acc = {}   # (host,port,model) -> laufende Summen/Buckets der Probes

# STT-Server (z.B. faster-whisper) – nur /health (Status + aktive Sessions)
STT_TARGETS = _parse_ollama(os.environ.get("VLLM_STT_TARGETS", ""))

# LM Studio (OpenAI-kompatibel, kein Prometheus /metrics – REST-API /api/v0)
LMSTUDIO_TARGETS = _parse_ollama(os.environ.get("VLLM_LMSTUDIO_TARGETS", ""))
LMSTUDIO_PROBE = os.environ.get("VLLM_LMSTUDIO_PROBE", "1").lower() not in ("0", "false", "no", "off")
LMSTUDIO_PROMPT = os.environ.get("VLLM_LMSTUDIO_PROMPT", "Antworte knapp in einem Satz: Hallo.")
LMSTUDIO_MAX_TOKENS = int(os.environ.get("VLLM_LMSTUDIO_MAX_TOKENS", "24"))


def _parse_hostports(spec):
    out = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            h, p = part.rsplit(":", 1)
            out.append((h, int(p)))
        else:
            out.append((part, 11434))
    return out


# Ollama-Autoscan: diese host:port werden bei jedem Scrape geprüft und – falls
# ein Ollama antwortet – automatisch mitüberwacht ("" schaltet es ab).
OLLAMA_AUTOSCAN = _parse_hostports(
    os.environ.get("VLLM_OLLAMA_AUTOSCAN", "%s:11434,127.0.0.1:11434" % HOST))

# NVIDIA DCGM-Exporter (GPU-Hardware): host:port,... (Default-Port 9400)
DCGM_TARGETS = _parse_hostports(os.environ.get("VLLM_DCGM_TARGETS", ""))
DCGM_METRICS = {
    "DCGM_FI_DEV_GPU_UTIL":      "gpu_util",       # %
    "DCGM_FI_DEV_MEM_COPY_UTIL": "gpu_mem_util",   # %
    "DCGM_FI_DEV_GPU_TEMP":      "gpu_temp",       # °C
    "DCGM_FI_DEV_POWER_USAGE":   "gpu_power",      # W
    "DCGM_FI_DEV_FB_USED":       "_fb_used",       # MiB
    "DCGM_FI_DEV_FB_FREE":       "_fb_free",       # MiB
}

# Einfache Gauges/Counter (ein Wert je Modell bzw. über Serien summiert)
GAUGE_COUNTER = {
    "vllm:num_requests_running":        "requests_running",
    "vllm:num_requests_waiting":        "requests_waiting",
    "vllm:kv_cache_usage_perc":         "kv_cache_usage",   # wird gemittelt
    "vllm:prompt_tokens_total":         "prompt_tokens_total",
    "vllm:generation_tokens_total":     "generation_tokens_total",
    "vllm:prefix_cache_queries_total":  "prefix_queries_total",
    "vllm:prefix_cache_hits_total":     "prefix_hits_total",
    "vllm:num_preemptions_total":       "preemptions_total",
}

# Histogramme -> (sum-Spalte, count-Spalte, bucket-Spalte)
HISTOGRAMS = {
    "vllm:time_to_first_token_seconds": ("ttft_sum", "ttft_count", "ttft_buckets"),
    "vllm:e2e_request_latency_seconds": ("e2e_sum", "e2e_count", "e2e_buckets"),
    "vllm:inter_token_latency_seconds": ("itl_sum", "itl_count", "itl_buckets"),
}

FINISHED_REASONS = ["stop", "length", "abort", "error", "repetition"]

# Numerische Spalten der samples-Tabelle
NUM_COLUMNS = [
    "requests_running", "requests_waiting", "kv_cache_usage",
    "waiting_capacity", "waiting_deferred",
    "prompt_tokens_total", "generation_tokens_total",
    "prefix_queries_total", "prefix_hits_total", "preemptions_total",
    "requests_success_total", "requests_error_total",
] + ["req_%s" % r for r in FINISHED_REASONS] + [
    "ttft_sum", "ttft_count", "e2e_sum", "e2e_count", "itl_sum", "itl_count",
    "vram_bytes",
    "gpu_util", "gpu_mem_util", "gpu_temp", "gpu_power", "vram_total_mb",
]
# JSON-Textspalten (Histogramm-Buckets als {le: kumulativ})
JSON_COLUMNS = ["ttft_buckets", "e2e_buckets", "itl_buckets"]

_running = True


# ---------------------------------------------------------------------------
# Datenbank
# ---------------------------------------------------------------------------

def _ddl(name):
    cols = ",\n            ".join(["%s REAL" % c for c in NUM_COLUMNS]
                                  + ["%s TEXT" % c for c in JSON_COLUMNS])
    return ("CREATE TABLE IF NOT EXISTS %s (\n"
            "            ts    INTEGER NOT NULL,\n"
            "            host  TEXT    NOT NULL,\n"
            "            port  INTEGER NOT NULL,\n"
            "            model TEXT    NOT NULL,\n"
            "            %s,\n"
            "            PRIMARY KEY (ts, host, port, model)\n"
            "        )" % (name, cols))


def init_db(conn):
    conn.execute(_ddl("samples"))
    # Migration von älterem Schema (ohne host / mit anderem PK)
    info = conn.execute("PRAGMA table_info(samples)").fetchall()
    names = {row[1] for row in info}
    pk = {row[1] for row in info if row[5] > 0}
    needs_rebuild = ("host" not in names) or (pk != {"ts", "host", "port", "model"})
    if info and needs_rebuild:
        old_cols = [r[1] for r in info]
        conn.execute("ALTER TABLE samples RENAME TO _samples_old")
        conn.execute(_ddl("samples"))
        common = [c for c in old_cols if c in set(["ts", "port", "model"] + NUM_COLUMNS + JSON_COLUMNS)]
        host_expr = "host" if "host" in old_cols else "'%s' AS host" % HOST
        conn.execute("INSERT OR IGNORE INTO samples (ts, host, port, model, %s) "
                     "SELECT ts, %s, port, model, %s FROM _samples_old"
                     % (",".join(c for c in common if c not in ("ts", "port", "model")),
                        host_expr,
                        ",".join(c for c in common if c not in ("ts", "port", "model"))))
        conn.execute("DROP TABLE _samples_old")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_model_ts ON samples(model, ts)")

    # Statische Engine-Konfiguration + Health je Instanz
    conn.execute("""
        CREATE TABLE IF NOT EXISTS config (
            host  TEXT NOT NULL,
            port  INTEGER NOT NULL,
            model TEXT NOT NULL,
            updated INTEGER,
            up INTEGER,
            num_gpu_blocks REAL,
            block_size REAL,
            max_model_len REAL,
            gpu_memory_utilization REAL,
            kv_cache_dtype TEXT,
            enable_prefix_caching TEXT,
            version TEXT,
            PRIMARY KEY (host, port, model)
        )
    """)
    # Additive Migration: fehlende Spalten nachrüsten (z.B. vram_bytes, kind)
    have = {r[1] for r in conn.execute("PRAGMA table_info(samples)")}
    for c in NUM_COLUMNS:
        if c not in have:
            conn.execute("ALTER TABLE samples ADD COLUMN %s REAL" % c)
    for c in JSON_COLUMNS:
        if c not in have:
            conn.execute("ALTER TABLE samples ADD COLUMN %s TEXT" % c)
    have_c = {r[1] for r in conn.execute("PRAGMA table_info(config)")}
    if "kind" not in have_c:
        conn.execute("ALTER TABLE config ADD COLUMN kind TEXT")
    # Alarm-Historie: ein Ereignis je Zustandswechsel (raised/cleared)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            model TEXT,
            kind TEXT NOT NULL,        -- offline|kv|temp|error
            state TEXT NOT NULL,       -- raised|cleared
            severity TEXT,             -- warn|crit
            value REAL,
            message TEXT
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)")
    # Self-Monitoring: Herzschlag des Collectors (eine Zeile, id=1)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS collector_status (
            id INTEGER PRIMARY KEY CHECK(id=1),
            ts INTEGER, scrapes INTEGER, errors INTEGER, stored INTEGER,
            interval INTEGER, version TEXT, host TEXT
        )
    """)
    conn.commit()


def store_sample(conn, ts, host, port, model, values):
    cols = ["ts", "host", "port", "model"] + NUM_COLUMNS + JSON_COLUMNS
    row = [ts, host, port, model] + [values.get(c) for c in (NUM_COLUMNS + JSON_COLUMNS)]
    conn.execute(
        "INSERT OR REPLACE INTO samples (%s) VALUES (%s)"
        % (",".join(cols), ",".join("?" for _ in cols)),
        row,
    )


def store_config(conn, host, port, model, cfg):
    conn.execute("""
        INSERT OR REPLACE INTO config
        (host, port, model, updated, up, num_gpu_blocks, block_size, max_model_len,
         gpu_memory_utilization, kv_cache_dtype, enable_prefix_caching, version, kind)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    """, (host, port, model, int(time.time()), cfg.get("up", 1),
          cfg.get("num_gpu_blocks"), cfg.get("block_size"), cfg.get("max_model_len"),
          cfg.get("gpu_memory_utilization"), cfg.get("kv_cache_dtype"),
          cfg.get("enable_prefix_caching"), cfg.get("version"), cfg.get("kind", "vllm")))


def mark_down(conn, host, port):
    """Nichterreichbarkeit vermerken – aber up=0 erst nach OFFLINE_GRACE Sekunden
    ununterbrochener Aussetzer setzen (Entprellung gegen kurzes Flackern)."""
    ts = int(time.time())
    since = _down_since.setdefault((host, port), ts)
    if ts - since >= OFFLINE_GRACE:
        conn.execute("UPDATE config SET up=0, updated=? WHERE host=? AND port=?",
                     (ts, host, port))


# --- Alarm-Erkennung: nur Zustandswechsel werden als Ereignis protokolliert ---
_alert_state = {}   # (host, port, model, kind) -> {"since": ts}
_down_since = {}    # (host, port) -> ts, seit wann nicht erreichbar
_prev_err = {}      # (host, port, model) -> requests_error_total (für Delta)


def record_alert(conn, ts, host, port, model, kind, active,
                 value=None, msg="", severity="warn"):
    """Schreibt ein Ereignis nur beim Wechsel aktiv<->inaktiv."""
    key = (host, port, model or "", kind)
    if active and key not in _alert_state:
        _alert_state[key] = {"since": ts}
        conn.execute(
            "INSERT INTO events (ts,host,port,model,kind,state,severity,value,message) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (ts, host, port, model, kind, "raised", severity, value, msg))
    elif (not active) and key in _alert_state:
        since = _alert_state.pop(key)["since"]
        conn.execute(
            "INSERT INTO events (ts,host,port,model,kind,state,severity,value,message) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (ts, host, port, model, kind, "cleared", severity, value,
             "behoben nach %s" % _human_dur(ts - since)))


def _human_dur(sec):
    sec = int(sec)
    if sec < 60:
        return "%ds" % sec
    if sec < 3600:
        return "%dm" % (sec // 60)
    return "%dh%dm" % (sec // 3600, (sec % 3600) // 60)


def purge_old(conn):
    cutoff = int(time.time()) - RETENTION_DAYS * 86400
    conn.execute("DELETE FROM samples WHERE ts < ?", (cutoff,))
    conn.execute("DELETE FROM events WHERE ts < ?", (cutoff,))
    conn.commit()


# ---------------------------------------------------------------------------
# Prometheus-Parsing
# ---------------------------------------------------------------------------

_LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([^\s]+)\s*$')
_LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


def parse_prometheus(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _LINE.match(line)
        if not m:
            continue
        name, labelblock, raw = m.group(1), m.group(2), m.group(3)
        try:
            val = float(raw)
        except ValueError:
            continue
        labels = dict(_LABEL.findall(labelblock)) if labelblock else {}
        out.append((name, labels, val))
    return out


def fetch_text(host, port, path):
    url = "http://%s:%d%s" % (host, port, path)
    req = request.Request(url, headers={"User-Agent": "vllm_collector/%s" % __version__})
    try:
        resp = request.urlopen(req, timeout=HTTP_TIMEOUT)
        return resp.read().decode("utf-8", "replace")
    except (error.URLError, OSError) as e:
        print("  [!] %s nicht erreichbar: %s" % (url, e))
        return None


def _num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def extract(samples):
    """Verdichtet die geparsten Metriken je Modell zu einem Wert-Dict."""
    per_model = {}
    kv_acc = {}
    buckets = {}   # model -> {bucket_col: {le: val}}

    def bucket(model):
        return per_model.setdefault(model, {c: None for c in (NUM_COLUMNS + JSON_COLUMNS)})

    for name, labels, val in samples:
        model = labels.get("model_name")
        if not model:
            continue
        b = bucket(model)

        if name in GAUGE_COUNTER:
            col = GAUGE_COUNTER[name]
            if col == "kv_cache_usage":
                acc = kv_acc.setdefault(model, [0.0, 0]); acc[0] += val; acc[1] += 1
            else:
                b[col] = (b[col] or 0.0) + val

        elif name == "vllm:num_requests_waiting_by_reason":
            reason = labels.get("reason", "")
            if reason == "capacity":
                b["waiting_capacity"] = (b["waiting_capacity"] or 0.0) + val
            elif reason == "deferred":
                b["waiting_deferred"] = (b["waiting_deferred"] or 0.0) + val

        elif name == "vllm:request_success_total":
            reason = labels.get("finished_reason", "")
            b["requests_success_total"] = (b["requests_success_total"] or 0.0) + val
            if reason in FINISHED_REASONS:
                b["req_%s" % reason] = (b["req_%s" % reason] or 0.0) + val
            if reason == "error":
                b["requests_error_total"] = (b["requests_error_total"] or 0.0) + val

        else:
            for base, (sum_col, cnt_col, buck_col) in HISTOGRAMS.items():
                if name == base + "_sum":
                    b[sum_col] = (b[sum_col] or 0.0) + val
                elif name == base + "_count":
                    b[cnt_col] = (b[cnt_col] or 0.0) + val
                elif name == base + "_bucket":
                    le = labels.get("le")
                    if le is not None:
                        d = buckets.setdefault(model, {}).setdefault(buck_col, {})
                        d[le] = d.get(le, 0.0) + val

    for model, (s, c) in kv_acc.items():
        if c:
            bucket(model)["kv_cache_usage"] = s / c
    for model, cols in buckets.items():
        for buck_col, d in cols.items():
            bucket(model)[buck_col] = json.dumps(d)

    return per_model


def extract_config(samples):
    """Engine-Konfiguration aus cache_config_info (portweit, ohne model_name)."""
    cfg = {}
    for name, labels, _val in samples:
        if name == "vllm:cache_config_info":
            cfg["num_gpu_blocks"] = _num(labels.get("num_gpu_blocks"))
            cfg["block_size"] = _num(labels.get("block_size"))
            cfg["gpu_memory_utilization"] = _num(labels.get("gpu_memory_utilization"))
            cfg["kv_cache_dtype"] = labels.get("cache_dtype")
            cfg["enable_prefix_caching"] = labels.get("enable_prefix_caching")
            break
    return cfg


# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------

def http_get(host, port, path, timeout=None):
    url = "http://%s:%d%s" % (host, port, path)
    req = request.Request(url, headers={"User-Agent": "vllm_collector/%s" % __version__})
    try:
        resp = request.urlopen(req, timeout=timeout or HTTP_TIMEOUT)
        return resp.read().decode("utf-8", "replace")
    except (error.URLError, OSError):
        return None


def get_json(host, port, path, timeout=None):
    t = http_get(host, port, path, timeout)
    if not t:
        return None
    try:
        return json.loads(t)
    except ValueError:
        return None


def _oll_new():
    a = {"gen": 0.0, "prompt": 0.0, "req_ok": 0.0}
    for k in ("ttft", "e2e", "itl"):
        a[k + "_sum"] = 0.0
        a[k + "_n"] = 0.0
        h = {str(le): 0.0 for le in OLL_LE[k]}
        h["+Inf"] = 0.0
        a[k + "_h"] = h
    return a


def _oll_bump(acc, k, x):
    acc[k + "_sum"] += x
    acc[k + "_n"] += 1
    h = acc[k + "_h"]
    for le in OLL_LE[k]:
        if x <= le:
            h[str(le)] += 1
    h["+Inf"] += 1


def ollama_probe(host, port, model):
    """Kleiner /api/generate-Aufruf -> Latenz/Token-Kennzahlen (Ollama liefert ns)."""
    body = json.dumps({"model": model, "prompt": OLLAMA_PROMPT, "stream": False,
                       "options": {"num_predict": OLLAMA_NUM_PREDICT}}).encode("utf-8")
    req = request.Request("http://%s:%d/api/generate" % (host, port), data=body,
                          headers={"Content-Type": "application/json"}, method="POST")
    try:
        resp = request.urlopen(req, timeout=OLLAMA_PROBE_TIMEOUT)
        d = json.loads(resp.read().decode("utf-8", "replace"))
    except (error.URLError, OSError, ValueError):
        return None
    ec = d.get("eval_count") or 0
    ed = d.get("eval_duration") or 0
    ld = d.get("load_duration") or 0
    pd = d.get("prompt_eval_duration") or 0
    pc = d.get("prompt_eval_count") or 0
    td = d.get("total_duration") or 0
    ns = 1e9
    return {"eval_count": ec, "prompt_eval_count": pc,
            "ttft": (ld + pd) / ns, "e2e": td / ns,
            "itl": (ed / ns / ec) if ec else 0.0}


def scrape_ollama(conn, ts, tgt, verbose=True):
    host, port = tgt["host"], tgt["port"]
    # Kurzer Timeout für die Erreichbarkeits-/Metadaten-Aufrufe, damit ein toter
    # Host (z. B. Laptop im Standby) den Sammler nicht je Scrape blockiert.
    ver = get_json(host, port, "/api/version", timeout=OLLAMA_TIMEOUT)
    if ver is None:
        mark_down(conn, host, port)
        if verbose:
            print("  [!] Ollama %s:%d nicht erreichbar." % (host, port))
        return 0
    _down_since.pop((host, port), None)   # wieder erreichbar -> Entprellung zurücksetzen
    version = ver.get("version")
    ps = get_json(host, port, "/api/ps", timeout=OLLAMA_TIMEOUT) or {}
    tags = get_json(host, port, "/api/tags", timeout=OLLAMA_TIMEOUT) or {}
    loaded = ps.get("models") or []
    model, vram = None, None
    if loaded:
        m0 = loaded[0]
        model = m0.get("name") or m0.get("model")
        vram = m0.get("size_vram")
    elif tags.get("models"):
        model = tags["models"][0].get("name") or tags["models"][0].get("model")
    if not model:
        model = tgt["label"]

    values = {c: None for c in (NUM_COLUMNS + JSON_COLUMNS)}
    if vram is not None:
        values["vram_bytes"] = float(vram)

    # Nur proben, wenn tatsächlich ein Modell geladen ist – sonst würde die
    # Generierung ein großes Modell erst laden (Sekunden bis Minute) und den
    # gesamten Scrape-Loop blockieren (alle Instanzen „flackern" rot/grün).
    if OLLAMA_PROBE and loaded:
        pr = ollama_probe(host, port, model)
        if pr:
            acc = _oll_acc.setdefault((host, port, model), _oll_new())
            acc["gen"] += pr["eval_count"]
            acc["prompt"] += pr["prompt_eval_count"]
            acc["req_ok"] += 1
            _oll_bump(acc, "ttft", pr["ttft"])
            _oll_bump(acc, "e2e", pr["e2e"])
            if pr["itl"] > 0:
                _oll_bump(acc, "itl", pr["itl"])
            values["generation_tokens_total"] = acc["gen"]
            values["prompt_tokens_total"] = acc["prompt"]
            values["requests_success_total"] = acc["req_ok"]
            values["req_stop"] = acc["req_ok"]
            values["ttft_sum"], values["ttft_count"] = acc["ttft_sum"], acc["ttft_n"]
            values["e2e_sum"], values["e2e_count"] = acc["e2e_sum"], acc["e2e_n"]
            values["itl_sum"], values["itl_count"] = acc["itl_sum"], acc["itl_n"]
            values["ttft_buckets"] = json.dumps(acc["ttft_h"])
            values["e2e_buckets"] = json.dumps(acc["e2e_h"])
            values["itl_buckets"] = json.dumps(acc["itl_h"])

    store_sample(conn, ts, host, port, model, values)
    store_config(conn, host, port, model, {"up": 1, "version": version, "kind": "ollama"})
    if verbose:
        print("  [+] (ollama) %-32s vram=%s gen=%s" % (
            model, _fmt(values.get("vram_bytes")), _fmt(values.get("generation_tokens_total"))))
    return 1


# ---------------------------------------------------------------------------
# LM Studio (OpenAI-kompatibel; REST-API /api/v0 liefert Lade-Status + Stats)
# ---------------------------------------------------------------------------

def lmstudio_probe(host, port, model):
    """Kleiner /api/v0/chat/completions-Aufruf -> Token-/Latenz-Kennzahlen.
    LM Studio liefert ein 'stats'-Objekt (tokens_per_second, time_to_first_token,
    generation_time in Sekunden) und 'usage' (prompt/completion_tokens)."""
    body = json.dumps({"model": model,
                       "messages": [{"role": "user", "content": LMSTUDIO_PROMPT}],
                       "max_tokens": LMSTUDIO_MAX_TOKENS, "stream": False}).encode("utf-8")
    req = request.Request("http://%s:%d/api/v0/chat/completions" % (host, port), data=body,
                          headers={"Content-Type": "application/json"}, method="POST")
    try:
        resp = request.urlopen(req, timeout=OLLAMA_PROBE_TIMEOUT)
        d = json.loads(resp.read().decode("utf-8", "replace"))
    except (error.URLError, OSError, ValueError):
        return None
    st = d.get("stats") or {}
    us = d.get("usage") or {}
    cc = us.get("completion_tokens") or 0
    pc = us.get("prompt_tokens") or 0
    ttft = float(st.get("time_to_first_token") or 0.0)
    gt = float(st.get("generation_time") or 0.0)
    return {"gen": cc, "prompt": pc, "ttft": ttft, "e2e": ttft + gt,
            "itl": (gt / cc) if cc else 0.0}


def scrape_lmstudio(conn, ts, tgt, verbose=True):
    host, port = tgt["host"], tgt["port"]
    data = get_json(host, port, "/api/v0/models", timeout=OLLAMA_TIMEOUT)
    api_v0 = data is not None
    if data is None:                                # Fallback: OpenAI-kompatibel
        data = get_json(host, port, "/v1/models", timeout=OLLAMA_TIMEOUT)
    if data is None:
        mark_down(conn, host, port)
        if verbose:
            print("  [!] LM Studio %s:%d nicht erreichbar." % (host, port))
        return 0
    _down_since.pop((host, port), None)             # wieder erreichbar -> Entprellung zurücksetzen
    models = data.get("data") or []
    loaded = [m for m in models if m.get("state") == "loaded"]
    model, ctx = None, None
    if loaded:
        m0 = loaded[0]
        model = m0.get("id") or m0.get("model")
        ctx = m0.get("loaded_context_length") or m0.get("max_context_length")
    elif models:
        model = models[0].get("id") or models[0].get("model")
    if not model:
        model = tgt["label"]

    values = {c: None for c in (NUM_COLUMNS + JSON_COLUMNS)}
    cfg = {"up": 1, "version": ("api/v0" if api_v0 else "v1"), "kind": "lmstudio"}
    if ctx is not None:
        try:
            cfg["max_model_len"] = int(ctx)
        except (ValueError, TypeError):
            pass

    # Probe nur gegen ein tatsächlich GELADENES Modell (kein Kalt-Load auslösen);
    # der Lade-Status ist nur über die /api/v0-API bekannt.
    if LMSTUDIO_PROBE and loaded and api_v0:
        pr = lmstudio_probe(host, port, model)
        if pr:
            acc = _oll_acc.setdefault((host, port, model), _oll_new())
            acc["gen"] += pr["gen"]
            acc["prompt"] += pr["prompt"]
            acc["req_ok"] += 1
            _oll_bump(acc, "ttft", pr["ttft"])
            _oll_bump(acc, "e2e", pr["e2e"])
            if pr["itl"] > 0:
                _oll_bump(acc, "itl", pr["itl"])
            values["generation_tokens_total"] = acc["gen"]
            values["prompt_tokens_total"] = acc["prompt"]
            values["requests_success_total"] = acc["req_ok"]
            values["req_stop"] = acc["req_ok"]
            values["ttft_sum"], values["ttft_count"] = acc["ttft_sum"], acc["ttft_n"]
            values["e2e_sum"], values["e2e_count"] = acc["e2e_sum"], acc["e2e_n"]
            values["itl_sum"], values["itl_count"] = acc["itl_sum"], acc["itl_n"]
            values["ttft_buckets"] = json.dumps(acc["ttft_h"])
            values["e2e_buckets"] = json.dumps(acc["e2e_h"])
            values["itl_buckets"] = json.dumps(acc["itl_h"])

    store_sample(conn, ts, host, port, model, values)
    store_config(conn, host, port, model, cfg)
    if verbose:
        print("  [+] (lmstudio) %-30s gen=%s" % (model, _fmt(values.get("generation_tokens_total"))))
    return 1


def scrape_stt(conn, ts, tgt, verbose=True):
    """STT-Server (faster-whisper o.ä.): /health -> Status + aktive Sessions."""
    host, port = tgt["host"], tgt["port"]
    h = get_json(host, port, "/health", timeout=OLLAMA_TIMEOUT)
    if h is None:
        mark_down(conn, host, port)
        if verbose:
            print("  [!] STT %s:%d nicht erreichbar." % (host, port))
        return 0
    _down_since.pop((host, port), None)   # wieder erreichbar -> Entprellung zurücksetzen
    mp = h.get("modelPath") or ""
    model = os.path.basename(mp) or tgt["label"] or "stt"
    values = {c: None for c in (NUM_COLUMNS + JSON_COLUMNS)}
    values["requests_running"] = float(h.get("activeSessions") or 0)
    store_sample(conn, ts, host, port, model, values)
    ver = "/".join(x for x in (h.get("device"), h.get("computeType")) if x)
    up = 1 if h.get("status") == "ok" else 0
    store_config(conn, host, port, model, {"up": up, "version": ver, "kind": "stt"})
    if verbose:
        print("  [+] (stt)    %-32s sessions=%s" % (model, _fmt(values["requests_running"])))
    return 1


def discover_ollama():
    """Autoscan: erreichbare Ollama-Endpunkte finden, die nicht konfiguriert sind."""
    found = []
    for host, port in OLLAMA_AUTOSCAN:
        if any(t["host"] == host and t["port"] == port for t in OLLAMA_TARGETS):
            continue
        if get_json(host, port, "/api/version", timeout=1.5) is not None:
            found.append({"host": host, "port": port, "label": "ollama"})
    return found


def scrape_dcgm(conn, ts, host, port, verbose=True):
    """NVIDIA DCGM-Exporter (/metrics, Prometheus) -> GPU-Hardware je GPU."""
    text = http_get(host, port, "/metrics")
    if text is None:
        mark_down(conn, host, port)
        if verbose:
            print("  [!] DCGM %s:%d nicht erreichbar." % (host, port))
        return 0
    per_gpu = {}
    for name, labels, val in parse_prometheus(text):
        col = DCGM_METRICS.get(name)
        if not col:
            continue
        g = labels.get("gpu")
        if g is None:
            continue
        d = per_gpu.setdefault(g, {"modelName": labels.get("modelName")})
        d[col] = val
        if labels.get("modelName"):
            d["modelName"] = labels.get("modelName")
    count = 0
    for g, d in sorted(per_gpu.items()):
        model = "GPU %s" % g
        values = {c: None for c in (NUM_COLUMNS + JSON_COLUMNS)}
        values["gpu_util"] = d.get("gpu_util")
        values["gpu_mem_util"] = d.get("gpu_mem_util")
        values["gpu_temp"] = d.get("gpu_temp")
        values["gpu_power"] = d.get("gpu_power")
        used, free = d.get("_fb_used"), d.get("_fb_free")
        if used is not None:
            values["vram_bytes"] = used * 1048576.0
            if free is not None:
                values["vram_total_mb"] = used + free
        store_sample(conn, ts, host, port, model, values)
        store_config(conn, host, port, model,
                     {"up": 1, "version": d.get("modelName") or "GPU", "kind": "gpu"})
        temp = values.get("gpu_temp")
        if temp is not None:
            record_alert(conn, ts, host, port, model, "temp", temp > THRESH["temp"],
                         value=temp, msg="GPU %.0f °C" % temp, severity="crit")
        count += 1
        if verbose:
            print("  [+] (gpu)    %-8s util=%s%% vram=%s MiB temp=%s°C power=%sW"
                  % (model, _fmt(values["gpu_util"]), _fmt(used),
                     _fmt(values["gpu_temp"]), _fmt(values["gpu_power"])))
    if not per_gpu and verbose:
        print("  [!] DCGM %s:%d: keine DCGM_FI_DEV-Metriken gefunden." % (host, port))
    return count


# ---------------------------------------------------------------------------
# Scrape-Zyklus
# ---------------------------------------------------------------------------

def scrape_vllm_target(conn, ts, host, port, verbose=True):
    """Ein vLLM-Ziel scrapen (Metriken + Config + Alarme). Rückgabe: gespeicherte Modelle."""
    text = fetch_text(host, port, "/metrics")
    if text is None:
        mark_down(conn, host, port)
        _down_since.setdefault((host, port), ts)
        if ts - _down_since[(host, port)] >= THRESH["offline_min"] * 60:
            record_alert(conn, ts, host, port, None, "offline", True,
                         msg="Instanz offline", severity="crit")
        return 0
    _down_since.pop((host, port), None)
    record_alert(conn, ts, host, port, None, "offline", False, severity="crit")
    samples = parse_prometheus(text)
    per_model = extract(samples)
    cfg = extract_config(samples)

    models_doc = fetch_text(host, port, "/v1/models")
    maxlen = {}
    if models_doc:
        try:
            for m in json.loads(models_doc).get("data", []):
                maxlen[m.get("id")] = _num(m.get("max_model_len"))
        except ValueError:
            pass
    ver_doc = fetch_text(host, port, "/version")
    version = None
    if ver_doc:
        try:
            version = json.loads(ver_doc).get("version")
        except ValueError:
            pass

    if not per_model:
        if verbose:
            print("  [!] %s:%d: keine model_name-Metriken." % (host, port))
        return 0
    n = 0
    for model, values in per_model.items():
        store_sample(conn, ts, host, port, model, values)
        mc = dict(cfg)
        mc["up"] = 1
        mc["max_model_len"] = maxlen.get(model)
        mc["version"] = version
        mc["kind"] = "vllm"
        store_config(conn, host, port, model, mc)
        kv = values.get("kv_cache_usage")
        if kv is not None:
            record_alert(conn, ts, host, port, model, "kv", (kv * 100.0) > THRESH["kv"],
                         value=kv * 100.0, msg="KV-Cache %.0f%%" % (kv * 100.0))
        et = values.get("requests_error_total")
        if et is not None:
            prev = _prev_err.get((host, port, model))
            _prev_err[(host, port, model)] = et
            if prev is not None:
                new = et - prev
                record_alert(conn, ts, host, port, model, "error", new > THRESH["err"],
                             value=new, msg="%d neue Fehler" % int(new))
        n += 1
        if verbose:
            print("  [+] %-40s run=%s kv=%s gen=%s"
                  % (model, _fmt(values.get("requests_running")),
                     _fmt(values.get("kv_cache_usage")),
                     _fmt(values.get("generation_tokens_total"))))
    return n


def scrape_once(conn, verbose=True):
    ts = int(time.time())
    total = 0
    refresh_thresholds()           # im UI geänderte Schwellwerte übernehmen
    extra = load_extra_targets()   # über die Oberfläche verwaltete Zusatz-Instanzen

    # vLLM: sobald targets.json vLLM-Einträge enthält, ist die Datei maßgeblich
    # (Env/Unit dient dann nur noch als Erst-Seed). So gibt es kein Doppel-Scrape,
    # und im UI gelöschte/pausierte Instanzen verschwinden wirklich.
    if _file_has_vllm():
        vllm_list = [(t["host"], t["port"]) for t in extra["vllm"]]
    else:
        vllm_list = [(tgt.get("host", HOST), tgt["port"]) for tgt in TARGETS]
    for host, port in vllm_list:
        total += scrape_vllm_target(conn, ts, host, port, verbose)

    # Ollama-Instanzen (konfiguriert + automatisch entdeckt + Datei)
    for tgt in OLLAMA_TARGETS + discover_ollama() + extra["ollama"]:
        try:
            total += scrape_ollama(conn, ts, tgt, verbose)
        except Exception as e:
            print("  [!] Ollama-Fehler %s:%d: %s" % (tgt["host"], tgt["port"], e))

    # STT-Server (nur /health)
    for tgt in STT_TARGETS + extra["stt"]:
        try:
            total += scrape_stt(conn, ts, tgt, verbose)
        except Exception as e:
            print("  [!] STT-Fehler %s:%d: %s" % (tgt["host"], tgt["port"], e))

    # LM Studio (OpenAI-kompatibel, REST-API /api/v0)
    for tgt in LMSTUDIO_TARGETS + extra["lmstudio"]:
        try:
            total += scrape_lmstudio(conn, ts, tgt, verbose)
        except Exception as e:
            print("  [!] LM-Studio-Fehler %s:%d: %s" % (tgt["host"], tgt["port"], e))

    # NVIDIA DCGM-Exporter (GPU-Hardware)
    for host, port in DCGM_TARGETS + extra["dcgm"]:
        try:
            total += scrape_dcgm(conn, ts, host, port, verbose)
        except Exception as e:
            print("  [!] DCGM-Fehler %s:%d: %s" % (host, port, e))

    conn.commit()
    return total


def _fmt(v):
    if v is None:
        return "-"
    return str(int(v)) if v == int(v) else "%.3f" % v


def write_heartbeat(conn, ts, scrapes, errors, stored):
    """Herzschlag in die DB schreiben, damit das Dashboard den Collector-Status sieht."""
    conn.execute(
        "INSERT OR REPLACE INTO collector_status "
        "(id,ts,scrapes,errors,stored,interval,version,host) VALUES (1,?,?,?,?,?,?,?)",
        (ts, scrapes, errors, stored, INTERVAL, __version__, HOST))


def _sd_notify(state):
    """systemd sd_notify (READY/WATCHDOG) – no-op außerhalb von systemd. Nur stdlib."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    try:
        if addr[0] == "@":            # abstrakter Namensraum
            addr = "\0" + addr[1:]
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.connect(addr)
        s.sendall(state.encode())
        s.close()
    except OSError:
        pass


def run_loop():
    conn = sqlite3.connect(DB_PATH)
    init_db(conn)
    seed_vllm_from_env()               # Env-Instanzen einmalig ins UI übernehmen
    _sd_notify("READY=1")
    print("vllm_collector %s – Ziel %s, Ports %s, Intervall %ds"
          % (__version__, HOST, [t["port"] for t in TARGETS], INTERVAL))
    n = 0
    errors = 0
    while _running:
        start = time.time()
        print("[%s] Scrape #%d" % (time.strftime("%Y-%m-%d %H:%M:%S"), n))
        stored = 0
        try:
            stored = scrape_once(conn)
        except Exception as e:
            errors += 1
            print("  [!] Scrape-Fehler: %s" % e)
        n += 1
        try:
            write_heartbeat(conn, int(time.time()), n, errors, stored)
            conn.commit()
        except Exception as e:
            print("  [!] Heartbeat-Fehler: %s" % e)
        _sd_notify("WATCHDOG=1")       # systemd-Watchdog bei Leben halten
        if n % PURGE_EVERY == 0:
            purge_old(conn)
            print("  [i] Retention-Aufräumung (> %d Tage)." % RETENTION_DAYS)
        sleep = INTERVAL - (time.time() - start)
        while sleep > 0 and _running:
            step = min(sleep, 1.0)
            time.sleep(step)
            sleep -= step
    conn.close()
    print("Collector beendet.")


def show_status():
    if not os.path.exists(DB_PATH):
        print("Noch keine Datenbank (%s) vorhanden." % DB_PATH)
        return
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT model, COUNT(*) n, MIN(ts) mn, MAX(ts) mx "
                        "FROM samples GROUP BY model").fetchall()
    if not rows:
        print("Datenbank ist leer.")
        return
    print("Gespeicherte Zeitreihen:")
    for r in rows:
        span = (r["mx"] - r["mn"]) / 3600.0
        print("  %-40s %6d Punkte  über %.1f h  (letzter: %s)"
              % (r["model"], r["n"], span,
                 time.strftime("%H:%M:%S", time.localtime(r["mx"]))))
    print("\nInstanz-Konfiguration:")
    for c in conn.execute("SELECT * FROM config"):
        cap = (c["num_gpu_blocks"] or 0) * (c["block_size"] or 0)
        print("  %-40s up=%s  KV=%.0f Tok  max_len=%s  gpu_mem=%s"
              % (c["model"], c["up"], cap, c["max_model_len"], c["gpu_memory_utilization"]))
    conn.close()


def _sigterm(*_):
    global _running
    _running = False


def main():
    signal.signal(signal.SIGINT, _sigterm)
    signal.signal(signal.SIGTERM, _sigterm)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "loop"
    if cmd == "once":
        conn = sqlite3.connect(DB_PATH)
        init_db(conn)
        n = scrape_once(conn)
        conn.close()
        print("Einmaliger Scrape: %d Zeitreihen gespeichert." % n)
    elif cmd == "status":
        show_status()
    else:
        run_loop()


if __name__ == "__main__":
    main()
