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
import sqlite3
import signal
from urllib import request, error

__version__ = "0.9.3"

# ---------------------------------------------------------------------------
# Konfiguration  (alles per Umgebungsvariable überschreibbar)
# ---------------------------------------------------------------------------

HOST = os.environ.get("VLLM_HOST", "127.0.0.1")


def _parse_targets(spec):
    """"9081:Qwen,9082:Gemma" -> [{"port":9081,"label":"Qwen"}, ...]"""
    targets = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            port, label = part.split(":", 1)
        else:
            port, label = part, part
        targets.append({"port": int(port), "label": label.strip()})
    return targets


TARGETS = _parse_targets(os.environ.get("VLLM_TARGETS", "8000:default"))

INTERVAL = int(os.environ.get("VLLM_INTERVAL", "15"))
RETENTION_DAYS = int(os.environ.get("VLLM_RETENTION_DAYS", "30"))
HTTP_TIMEOUT = float(os.environ.get("VLLM_HTTP_TIMEOUT", "15"))
PURGE_EVERY = 240

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vllm_metrics.db")

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
    conn.commit()


def store_sample(conn, ts, port, model, values):
    cols = ["ts", "host", "port", "model"] + NUM_COLUMNS + JSON_COLUMNS
    row = [ts, HOST, port, model] + [values.get(c) for c in (NUM_COLUMNS + JSON_COLUMNS)]
    conn.execute(
        "INSERT OR REPLACE INTO samples (%s) VALUES (%s)"
        % (",".join(cols), ",".join("?" for _ in cols)),
        row,
    )


def store_config(conn, port, model, cfg):
    conn.execute("""
        INSERT OR REPLACE INTO config
        (host, port, model, updated, up, num_gpu_blocks, block_size, max_model_len,
         gpu_memory_utilization, kv_cache_dtype, enable_prefix_caching, version)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    """, (HOST, port, model, int(time.time()), cfg.get("up", 1),
          cfg.get("num_gpu_blocks"), cfg.get("block_size"), cfg.get("max_model_len"),
          cfg.get("gpu_memory_utilization"), cfg.get("kv_cache_dtype"),
          cfg.get("enable_prefix_caching"), cfg.get("version")))


def mark_down(conn, port, label):
    conn.execute("UPDATE config SET up=0, updated=? WHERE host=? AND port=?",
                 (int(time.time()), HOST, port))


def purge_old(conn):
    cutoff = int(time.time()) - RETENTION_DAYS * 86400
    conn.execute("DELETE FROM samples WHERE ts < ?", (cutoff,))
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


def fetch_text(port, path):
    url = "http://%s:%d%s" % (HOST, port, path)
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
# Scrape-Zyklus
# ---------------------------------------------------------------------------

def scrape_once(conn, verbose=True):
    ts = int(time.time())
    total = 0
    for tgt in TARGETS:
        port = tgt["port"]
        text = fetch_text(port, "/metrics")
        if text is None:
            mark_down(conn, port, tgt["label"])
            continue
        samples = parse_prometheus(text)
        per_model = extract(samples)
        cfg = extract_config(samples)

        # max_model_len + version je Modell aus der API
        models_doc = fetch_text(port, "/v1/models")
        maxlen = {}
        if models_doc:
            try:
                for m in json.loads(models_doc).get("data", []):
                    maxlen[m.get("id")] = _num(m.get("max_model_len"))
            except ValueError:
                pass
        ver_doc = fetch_text(port, "/version")
        version = None
        if ver_doc:
            try:
                version = json.loads(ver_doc).get("version")
            except ValueError:
                pass

        if not per_model:
            if verbose:
                print("  [!] Port %d: keine model_name-Metriken." % port)
            continue
        for model, values in per_model.items():
            store_sample(conn, ts, port, model, values)
            mc = dict(cfg)
            mc["up"] = 1
            mc["max_model_len"] = maxlen.get(model)
            mc["version"] = version
            store_config(conn, port, model, mc)
            total += 1
            if verbose:
                print("  [+] %-40s run=%s kv=%s gen=%s"
                      % (model, _fmt(values.get("requests_running")),
                         _fmt(values.get("kv_cache_usage")),
                         _fmt(values.get("generation_tokens_total"))))
    conn.commit()
    return total


def _fmt(v):
    if v is None:
        return "-"
    return str(int(v)) if v == int(v) else "%.3f" % v


def run_loop():
    conn = sqlite3.connect(DB_PATH)
    init_db(conn)
    print("vllm_collector %s – Ziel %s, Ports %s, Intervall %ds"
          % (__version__, HOST, [t["port"] for t in TARGETS], INTERVAL))
    n = 0
    while _running:
        start = time.time()
        print("[%s] Scrape #%d" % (time.strftime("%Y-%m-%d %H:%M:%S"), n))
        try:
            scrape_once(conn)
        except Exception as e:
            print("  [!] Scrape-Fehler: %s" % e)
        n += 1
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
