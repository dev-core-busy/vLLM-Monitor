#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vllm_collector.sh – Dauerhafter Metrik-Sammler für vLLM-Server
==============================================================
Pullt in festem Intervall die Prometheus-/metrics-Endpunkte mehrerer
vLLM-Instanzen, parst die relevanten Kennzahlen (pro Modell) und schreibt
sie in eine lokale SQLite-Zeitreihen-Datenbank. Alte Daten werden nach
RETENTION_DAYS automatisch entfernt.

Datenquelle:  http://<HOST>:<PORT>/metrics   (OpenAI/vLLM, Prometheus-Format)
Ablage:       vllm_metrics.db  (SQLite, im selben Verzeichnis)

Bedienung:
  python3 vllm_collector.sh          – Dauerlauf (pullt alle INTERVAL Sekunden)
  python3 vllm_collector.sh once     – genau ein Scrape (zum Testen)
  python3 vllm_collector.sh status   – letzte gespeicherte Werte anzeigen

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

__version__ = "0.8.1"

# ---------------------------------------------------------------------------
# Konfiguration  (alles per Umgebungsvariable überschreibbar)
# ---------------------------------------------------------------------------

# Host der vLLM-Instanz(en)
HOST = os.environ.get("VLLM_HOST", "127.0.0.1")


def _parse_targets(spec):
    """"9081:Qwen,9082:Gemma" -> [{"port":9081,"label":"Qwen"}, ...]

    Das Label dient nur als Fallback; der echte Modellname wird zur Laufzeit
    aus den Metriken (Label model_name) übernommen.
    """
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


# vLLM-Instanzen, die überwacht werden – z.B. VLLM_TARGETS="9081:Qwen,9082:Gemma"
TARGETS = _parse_targets(os.environ.get("VLLM_TARGETS", "8000:default"))

INTERVAL = int(os.environ.get("VLLM_INTERVAL", "15"))           # Sek. zwischen Scrapes
RETENTION_DAYS = int(os.environ.get("VLLM_RETENTION_DAYS", "30"))  # Aufbewahrung
HTTP_TIMEOUT = float(os.environ.get("VLLM_HTTP_TIMEOUT", "15"))    # /metrics kann dauern
PURGE_EVERY = 240        # Aufräumen alle N Scrapes (240*15s = 1h)

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vllm_metrics.db")

# Prometheus-Metriknamen -> Spaltennamen in der DB.
# Für Counter/Gauges wird EIN Wert pro Modell erwartet bzw. über alle
# Label-Kombinationen summiert (z.B. request_success_total je finished_reason).
GAUGE_COUNTER = {
    "vllm:num_requests_running":        "requests_running",
    "vllm:num_requests_waiting":        "requests_waiting",
    "vllm:kv_cache_usage_perc":         "kv_cache_usage",
    "vllm:prompt_tokens_total":         "prompt_tokens_total",
    "vllm:generation_tokens_total":     "generation_tokens_total",
    "vllm:prefix_cache_queries_total":  "prefix_queries_total",
    "vllm:prefix_cache_hits_total":     "prefix_hits_total",
    "vllm:num_preemptions_total":       "preemptions_total",
}

# Histogramme -> (sum-Spalte, count-Spalte); Durchschnitt = Δsum/Δcount
HISTOGRAMS = {
    "vllm:time_to_first_token_seconds": ("ttft_sum", "ttft_count"),
    "vllm:e2e_request_latency_seconds": ("e2e_sum", "e2e_count"),
    "vllm:inter_token_latency_seconds": ("itl_sum", "itl_count"),
}

# Alle Spalten der samples-Tabelle (Reihenfolge frei, PK = ts+port)
COLUMNS = [
    "requests_running", "requests_waiting", "kv_cache_usage",
    "prompt_tokens_total", "generation_tokens_total",
    "prefix_queries_total", "prefix_hits_total", "preemptions_total",
    "requests_success_total", "requests_error_total",
    "ttft_sum", "ttft_count", "e2e_sum", "e2e_count", "itl_sum", "itl_count",
]

_running = True


# ---------------------------------------------------------------------------
# Datenbank
# ---------------------------------------------------------------------------

def _ddl(name):
    cols = ",\n            ".join("%s REAL" % c for c in COLUMNS)
    return ("CREATE TABLE IF NOT EXISTS %s (\n"
            "            ts    INTEGER NOT NULL,\n"
            "            port  INTEGER NOT NULL,\n"
            "            model TEXT    NOT NULL,\n"
            "            %s,\n"
            "            PRIMARY KEY (ts, port, model)\n"
            "        )" % (name, cols))


def init_db(conn):
    conn.execute(_ddl("samples"))
    # Migration: alter PK (ts, port) -> (ts, port, model), damit mehrere
    # Modelle auf demselben Port nicht dieselbe Zeile überschreiben.
    info = conn.execute("PRAGMA table_info(samples)").fetchall()
    pk = {row[1] for row in info if row[5] > 0}   # row[5] = pk-Position
    if pk and pk != {"ts", "port", "model"}:
        conn.execute("ALTER TABLE samples RENAME TO _samples_old")
        conn.execute(_ddl("samples"))
        conn.execute("INSERT OR IGNORE INTO samples SELECT * FROM _samples_old")
        conn.execute("DROP TABLE _samples_old")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_model_ts ON samples(model, ts)")
    conn.commit()


def store(conn, ts, port, model, values):
    cols = ["ts", "port", "model"] + COLUMNS
    placeholders = ",".join("?" for _ in cols)
    row = [ts, port, model] + [values.get(c) for c in COLUMNS]
    conn.execute(
        "INSERT OR REPLACE INTO samples (%s) VALUES (%s)" % (",".join(cols), placeholders),
        row,
    )
    conn.commit()


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
    """Liefert Liste von (name, labels_dict, float_value); ignoriert Kommentare."""
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


def fetch_metrics(port):
    url = "http://%s:%d/metrics" % (HOST, port)
    req = request.Request(url, headers={"User-Agent": "vllm_collector/1.0"})
    try:
        resp = request.urlopen(req, timeout=HTTP_TIMEOUT)
        return resp.read().decode("utf-8", "replace")
    except (error.URLError, OSError) as e:
        print("  [!] %s nicht erreichbar: %s" % (url, e))
        return None


def extract(samples):
    """Verdichtet die geparsten Metriken je Modell zu einem Wert-Dict.

    Rückgabe: { model_name: {spalte: wert, ...}, ... }
    """
    per_model = {}
    kv_acc = {}   # model -> [summe, anzahl] für Mittelwert der KV-Cache-Auslastung

    def bucket(model):
        return per_model.setdefault(model, {c: None for c in COLUMNS})

    for name, labels, val in samples:
        model = labels.get("model_name")
        if not model:
            continue

        if name in GAUGE_COUNTER:
            col = GAUGE_COUNTER[name]
            b = bucket(model)
            if col == "kv_cache_usage":
                # Prozentwert: über mehrere Engines mitteln, nicht summieren
                acc = kv_acc.setdefault(model, [0.0, 0])
                acc[0] += val
                acc[1] += 1
            else:
                b[col] = (b[col] or 0.0) + val   # Counter/Requests: summieren

        elif name == "vllm:request_success_total":
            b = bucket(model)
            reason = labels.get("finished_reason", "")
            b["requests_success_total"] = (b["requests_success_total"] or 0.0) + val
            if reason == "error":
                b["requests_error_total"] = (b["requests_error_total"] or 0.0) + val

        else:
            for base, (sum_col, cnt_col) in HISTOGRAMS.items():
                if name == base + "_sum":
                    b = bucket(model); b[sum_col] = (b[sum_col] or 0.0) + val
                elif name == base + "_count":
                    b = bucket(model); b[cnt_col] = (b[cnt_col] or 0.0) + val

    for model, (s, c) in kv_acc.items():
        if c:
            bucket(model)["kv_cache_usage"] = s / c

    return per_model


# ---------------------------------------------------------------------------
# Scrape-Zyklus
# ---------------------------------------------------------------------------

def scrape_once(conn, verbose=True):
    ts = int(time.time())
    total = 0
    for tgt in TARGETS:
        port = tgt["port"]
        text = fetch_metrics(port)
        if text is None:
            continue
        per_model = extract(parse_prometheus(text))
        if not per_model:
            if verbose:
                print("  [!] Port %d: keine model_name-Metriken gefunden." % port)
            continue
        # In der Regel genau ein Modell pro Port
        for model, values in per_model.items():
            store(conn, ts, port, model, values)
            total += 1
            if verbose:
                run = values.get("requests_running")
                kv = values.get("kv_cache_usage")
                gen = values.get("generation_tokens_total")
                print("  [+] %-40s running=%s kv=%s gen_tok=%s"
                      % (model, _fmt(run), _fmt(kv), _fmt(gen)))
    return total


def _fmt(v):
    if v is None:
        return "-"
    if v == int(v):
        return str(int(v))
    return "%.3f" % v


def run_loop():
    conn = sqlite3.connect(DB_PATH)
    init_db(conn)
    print("vllm_collector – Ziel %s, Ports %s, Intervall %ds, DB %s"
          % (HOST, [t["port"] for t in TARGETS], INTERVAL, DB_PATH))
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
            print("  [i] Retention-Aufräumung (> %d Tage) ausgeführt." % RETENTION_DAYS)
        # driftfreies Warten
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
    cur = conn.execute("SELECT model, COUNT(*) n, MIN(ts) mn, MAX(ts) mx FROM samples GROUP BY model")
    rows = cur.fetchall()
    if not rows:
        print("Datenbank ist leer.")
        return
    print("Gespeicherte Zeitreihen:")
    for r in rows:
        span = (r["mx"] - r["mn"]) / 3600.0
        print("  %-40s %6d Punkte  über %.1f h  (letzter: %s)"
              % (r["model"], r["n"], span, time.strftime("%H:%M:%S", time.localtime(r["mx"]))))
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
