#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_monitor.sh – LLM / vLLM Monitoring-Tool
=========================================

Ziel: maximale Informationen aus einem laufenden vLLM-/LLM-Server herausholen.
Sammelt alles was via HTTP-Schnittstelle verfügbar ist:

vLLM-spezifisch:
  - /health              – Health-Check
  - /version             – Server-Version
  - /v1/models            – Modell-Liste (OpenAI-kompatibel)
  - /v1/model_served_models – Detaillierte Modell-Infos (vLLM-Extra-Endpoint)
  - /metrics              – Prometheus-Metriken (GPU, Cache, Requests, Tokens …)
  - /v1/ingest/ping       – (ggf. weitere Extra-Endpoints)
  - /v1/rerank, /v1/embeddings – weitere API-Endpunkte prüfen

Generisch (Ollama, LM Studio, TGI, …):
  - /api/version, /api/tags (Ollama)
  - Server-Header, TLS/SSL-Info
  - Response-Zeiten
  - HTTP-Methoden-Support (OPTIONS)

Bedienung:
  python3 monitor.sh <IP> [PORT]   – Voll-Scan (alle verfügbaren Infos)
  python3 monitor.sh <IP> [PORT] health  – Nur Health-Check
  python3 monitor.sh <IP> [PORT] models   – Nur Modell-Infos
  python3 monitor.sh <IP> [PORT] metrics  – Roh-Metriken (Prometheus)
  python3 monitor.sh <IP> [PORT] prompt   – Interaktiver Test-Prompt

Beispiel:
  python3 monitor.sh 192.168.1.100 8000
  python3 monitor.sh 10.0.0.5 11434 health
"""

import socket
import ssl
import json
import os
import sys
import time
import ipaddress
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib import request, error
from datetime import datetime, timezone

__version__ = "0.9.4"

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

LAST_IP_FILE = os.path.join(os.path.expanduser("~"), ".monitor_last_ip")

CONNECT_TIMEOUT = 3.0
HTTP_TIMEOUT = 10.0
METRICS_TIMEOUT = 15.0  # /metrics kann langsam sein
MAX_WORKERS = 30

# Alle Ports aus scan_for_llms.sh – damit finden wir vLLM auch auf 9081/9082 etc.
ALL_LLM_PORTS = [
    22, 3128, 1234, 1235, 3000, 4000, 5000, 5001, 7860,
    8000, 8001, 8080, 8081, 8443, 8888, 9000, 9081, 9082,
    11434, 11435,
]

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

def load_last_ip():
    try:
        with open(LAST_IP_FILE, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def save_last_ip(ip):
    try:
        with open(LAST_IP_FILE, "w", encoding="utf-8") as fh:
            fh.write(ip.strip())
    except OSError:
        pass


def valid_ip(text):
    try:
        ipaddress.ip_address(text.strip())
        return True
    except ValueError:
        return False


def guess_port(ip, port=None):
    """Finde den Port mit einem LLM-Server – scannt alle bekannten LLM-Ports."""
    if port:
        return port

    # Schneller TCP-Scan über alle LLM-Ports
    for p in ALL_LLM_PORTS:
        if port_open(ip, p, timeout=1.0):
            print(f" [!] Port nicht angegeben – gefunden: {p}")
            return p

    # Fallback: 80/443
    for p in (80, 443):
        if port_open(ip, p, timeout=1.0):
            print(f" [!] Port nicht angegeben – gefunden: {p} (HTTP)")
            return p

    print(" [!] Kein LLM-Port gefunden – versuche 8000 (vLLM Default)")
    return 8000


def port_open(ip, port, timeout=CONNECT_TIMEOUT):
    """Reines TCP-Connect."""
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except (OSError, socket.timeout):
        return False


def http_request(scheme, ip, port, path, method="GET", timeout=HTTP_TIMEOUT, body=None, headers=None):
    """HTTP(S)-Request. Gibt (code, headers_dict, body_text, elapsed_ms) zurück."""
    url = f"{scheme}://{ip}:{port}{path}"
    req_headers = {"User-Agent": "monitor_llm/1.0"}
    if headers:
        req_headers.update(headers)
    data = body.encode("utf-8") if body else None
    req = request.Request(url, headers=req_headers, data=data, method=method)
    t0 = time.monotonic()
    try:
        if scheme == "https":
            resp = request.urlopen(req, timeout=timeout, context=SSL_CTX)
        else:
            resp = request.urlopen(req, timeout=timeout)
        elapsed = (time.monotonic() - t0) * 1000
        try:
            resp_body = resp.read(262144).decode("utf-8", "replace")
        except Exception:
            resp_body = ""
        return resp.getcode(), dict(resp.headers), resp_body, elapsed
    except error.HTTPError as e:
        elapsed = (time.monotonic() - t0) * 1000
        body = ""
        try:
            body = e.read(262144).decode("utf-8", "replace")
        except Exception:
            pass
        return e.code, dict(e.headers), body, elapsed
    except Exception as e:
        elapsed = (time.monotonic() - t0) * 1000
        return None, {}, str(e), elapsed


def http_json(scheme, ip, port, path, method="GET", timeout=HTTP_TIMEOUT, body=None):
    code, headers, text, elapsed = http_request(scheme, ip, port, path, method, timeout, body)
    if code == 200 and text:
        try:
            return {"data": json.loads(text), "headers": headers, "elapsed_ms": elapsed}
        except (ValueError, json.JSONDecodeError):
            return {"data": None, "headers": headers, "elapsed_ms": elapsed}
    return {"data": None, "headers": {}, "elapsed_ms": elapsed, "error": f"HTTP {code}"}


def detect_schemes(ip, port):
    """Finde verfügbare Schemata (http, https)."""
    schemes = []
    for scheme in ("https", "http"):
        code, _, _, _ = http_request(scheme, ip, port, "/")
        if code is not None:
            schemes.append(scheme)
    return schemes


def fetch_all(schemes, ip, port, paths, label=""):
    """Paralleles Abfragen mehrerer Pfade. Gibt dict zurück."""
    results = {}
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futs = {}
        for path in paths:
            for s in schemes:
                key = f"{s}:{path}"
                futs[key] = pool.submit(http_json, s, ip, port, path)
        for key in futs:
            try:
                results[key] = futs[key].result()
            except Exception:
                results[key] = {"data": None, "error": "Exception"}
    return results


def fmt_bytes(n):
    if n is None:
        return "?"
    for u in ["B", "KB", "MB", "GB", "TB"]:
        if abs(n) < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"


def fmt_duration(s):
    try:
        s = float(s)
        if s < 1:
            return f"{s*1000:.1f} ms"
        if s < 60:
            return f"{s:.1f} s"
        m = int(s // 60)
        sec = s % 60
        return f"{m}m {sec:.0f}s"
    except (ValueError, TypeError):
        return str(s)


def fmt_number(n):
    if n is None:
        return "?"
    try:
        n = float(n)
        if n >= 1_000_000:
            return f"{n/1_000_000:.1f}M"
        if n >= 1_000:
            return f"{n/1_000:.1f}K"
        return f"{n:g}"
    except (ValueError, TypeError):
        return str(n)


def print_header(title):
    print()
    print("═" * 72)
    print(f"  {title}")
    print("═" * 72)


def print_section(title):
    print()
    print("─" * 72)
    print(f"  {title}")


def print_kv(key, value, indent=4):
    prefix = " " * indent
    if value is None or value == "" or value == {}:
        print(f"{prefix}{key}: (nicht verfügbar)")
    else:
        print(f"{prefix}{key}: {value}")


# ---------------------------------------------------------------------------
# Server-Erkennung
# ---------------------------------------------------------------------------

def detect_server(schemes, ip, port):
    """Bestimme Typ des Servers (vLLM, Ollama, TGI, …)."""
    info = {"type": "unbekannt", "name": "", "version": "", "schemes": schemes,
            "port": port, "ip": ip}

    # === 1) HTTP-Header prüfen ===
    for scheme in schemes:
        code, headers, body, _ = http_request(scheme, ip, port, "/")
        if code is not None:
            server_hdr = (headers.get("Server") or headers.get("server") or "").lower()
            info["server_header"] = headers.get("Server") or headers.get("server") or ""
            info["all_headers"] = {k: headers.get(k, "") for k in [
                "Server", "Content-Type", "X-Powered-By", "Access-Control-Allow-Origin",
                "Strict-Transport-Security", "Date", "Connection", "Keep-Alive"]}

            # vLLM erkennen (Header variiert: "vllm", "uvicorn", "hypercorn", …)
            # Ab v0.22.x sendet vLLM oft "uvicorn" als Server-Header
            # Wir prüfen später per Endpunkt

            # Ollama
            if "ollama" in server_hdr:
                info["type"] = "Ollama"
                break

            # TGI (text-generation-inference)
            if "huggingface" in server_hdr or "tgi" in server_hdr:
                info["type"] = "TGI"
                break

            # LM Studio
            if "lm studio" in server_hdr:
                info["type"] = "LM Studio"
                break

            # llama.cpp / KoboldCpp
            if "llama.cpp" in server_hdr or "koboldcpp" in server_hdr:
                info["type"] = "llama.cpp"
                break

            # Squid
            if "squid" in server_hdr:
                info["type"] = "Squid Proxy"
                break

    # === 2) Endpunkt-basierte Erkennung (auch wenn Header nicht eindeutig) ===
    if info["type"] == "unbekannt" or info["type"] == "OpenAI-kompatibel":
        for scheme in schemes:
            # a) /v1/models mit data[] = OpenAI-kompatibel (vLLM, LM Studio, TGI …)
            r = http_json(scheme, ip, port, "/v1/models")
            if r["data"] and isinstance(r["data"].get("data"), list):
                models = r["data"]["data"]
                if len(models) > 0:
                    owned_by = models[0].get("owned_by", "").lower()
                    # "vllm" als owned_by ist starkes vLLM-Indiz
                    if owned_by == "vllm":
                        info["type"] = "vLLM"
                        break
                    # Ansonsten: OpenAI-kompatibel
                    info["type"] = "OpenAI-kompatibel"
                    info["openai_compatible"] = True
                    break

            # b) /api/tags = Ollama
            r = http_json(scheme, ip, port, "/api/tags")
            if r["data"] is not None:
                info["type"] = "Ollama"
                break

            # c) /version = vLLM (200 mit version-Feld)
            r = http_json(scheme, ip, port, "/version")
            if r["data"] and isinstance(r["data"], dict) and r["data"].get("version"):
                info["version"] = r["data"]["version"]
                ver = r["data"]["version"].lower()
                if "vllm" in ver or "v0." in ver:
                    info["type"] = "vLLM"
                else:
                    info["type"] = "OpenAI-kompatibel"
                    info["openai_compatible"] = True
                break

            # d) /health mit JSON = TGI
            code, _, body, _ = http_request(scheme, ip, port, "/health")
            if code == 200 and body and body.strip().startswith("{"):
                try:
                    j = json.loads(body)
                    if "models" in j or "status" in j:
                        info["type"] = "TGI"
                        info["health_data"] = j
                        break
                except json.JSONDecodeError:
                    pass

    return info


# ---------------------------------------------------------------------------
# vLLM-spezifische Endpunkte
# ---------------------------------------------------------------------------

def collect_vllm_info(schemes, ip, port):
    """Sammelt ALLE verfügbaren vLLM-Informationen."""
    results = {}
    base_paths = []

    # Core Endpunkte
    base_paths.extend(["/v1/models", "/v1/model_served_models",
                        "/health", "/version", "/metrics"])

    # Extra Endpunkte (vLLM ab 0.3+)
    base_paths.extend([
        "/v1/chat/completions",   # OPTIONS prüfen
        "/v1/completions",
        "/v1/embeddings",
        "/v1/rerank",
        "/v1/sampling_capabilities",
    ])

    # Engine-Extra-Endpunkte (ggf. aktiviert)
    base_paths.extend([
        "/get_model",
        "/health",
        "/version",
        "/metrics",
    ])

    # Doppelte Pfade entfernen (Reihenfolge bleibt erhalten) -> keine doppelten Requests
    base_paths = list(dict.fromkeys(base_paths))

    data = fetch_all(schemes, ip, port, base_paths)

    # Ergebnisse strukturieren
    for scheme in schemes:
        for path in base_paths:
            key = f"{scheme}:{path}"
            if key in data:
                r = data[key]
                results[path] = {**r, "scheme": scheme}

    # /metrics ist Prometheus-TEXT, kein JSON -> roh holen (http_json liefert sonst data=None)
    for scheme in schemes:
        code, headers, body, elapsed = http_request(
            scheme, ip, port, "/metrics", timeout=METRICS_TIMEOUT)
        if code == 200 and body:
            results["/metrics"] = {
                "data": body, "headers": headers,
                "elapsed_ms": elapsed, "scheme": scheme, "raw": True,
            }
            break

    # Health direkt mit http_request (http_json verwarft leere Bodies – /health antwortet oft mit 200 + leer)
    for scheme in schemes:
        code, headers, body, elapsed = http_request(scheme, ip, port, "/health")
        results[f"{scheme}:/health"] = {
            "data": body,
            "headers": headers,
            "elapsed_ms": elapsed,
            "scheme": scheme,
            "raw": True,
        }

    # OPTIONS für CORS/Methoden
    for scheme in schemes:
        code, headers, body, elapsed = http_request(scheme, ip, port, "/", method="OPTIONS")
        results["/ OPTIONS /"] = {
            "data": {"allow": headers.get("Allow", ""),
                     "cors": headers.get("Access-Control-Allow-Origin", ""),
                     "body": body},
            "headers": headers,
            "elapsed_ms": elapsed,
            "scheme": scheme,
        }

    return results


def parse_vllm_results(results):
    """Interpretiert die Rohdaten und strukturiert sie für die Anzeige."""
    output = {}

    # --- Models (OpenAI-kompatibel) ---
    models_entry = None
    # results kann Keys wie "http:/v1/models" ODER "/v1/models" haben
    for key in ["http:/v1/models", "https:/v1/models", "/v1/models"]:
        if key in results and results[key].get("data"):
            models_entry = results[key]
            break

    if models_entry and models_entry["data"]:
        models = models_entry["data"].get("data", [])
        output["openai_models"] = {
            "count": len(models),
            "items": [],
            "total_size": None,
        }
        for m in models:
            entry = {
                "id": m.get("id", "?"),
                "object": m.get("object", ""),
                "owned_by": m.get("owned_by", ""),
                "created": m.get("created", ""),
                "max_model_len": m.get("max_model_len"),
                "root": m.get("root", ""),
            }
            output["openai_models"]["items"].append(entry)

    # --- Model Served Models (vLLM-spezifisch) ---
    mserved = None
    for key in ["http:/v1/model_served_models", "https:/v1/model_served_models", "/v1/model_served_models"]:
        if key in results and results[key].get("data"):
            mserved = results[key]
            break

    if mserved and mserved["data"]:
        models = mserved["data"] if isinstance(mserved["data"], list) else mserved["data"].get("models", [])
        output["model_served_models"] = {
            "count": len(models),
            "items": [],
        }
        for m in models:
            entry = {}
            for k in ["model_name", "model_sha", "gpu_memory_usage",
                       "num_transformer_units", "quantization_param_name",
                       "num_media", "num_blocks", "num_attention_heads",
                       "num_key_value_heads", "max_num_batched_tokens",
                       "max_num_seqs", "num_layer", "num_embed", "quantization_method",
                       "num_shards", "tensor_parallel_size", "rope_scaling"]:
                if k in m:
                    entry[k] = m[k]
            if "gpu_memory_usage" in entry and entry["gpu_memory_usage"]:
                entry["gpu_memory_usage"] = fmt_bytes(entry["gpu_memory_usage"])
            output["model_served_models"]["items"].append(entry)

    # --- Version ---
    ver = None
    for key in ["http:/version", "https:/version", "/version"]:
        if key in results and results[key].get("data") and isinstance(results[key].get("data"), dict) and results[key]["data"].get("version"):
            ver = results[key]["data"]
            break

    if ver:
        output["version"] = ver

    # --- Health ---
    health = None
    for key in ["http:/health", "https:/health", "/health"]:
        if key in results:
            h = results[key]
            if h.get("data") is not None or h.get("raw"):
                health = h
                break

    output["health"] = health

    # --- Metrics (Prometheus) ---
    metrics_raw = None
    for key in ["http:/metrics", "https:/metrics", "/metrics"]:
        if key in results:
            m = results[key]
            if m.get("data"):
                metrics_raw = m
                break

    if metrics_raw:
        output["metrics_raw"] = metrics_raw

    # --- Server-Header ---
    output["server_header"] = results.get("http:/", {}).get("headers", {}).get("Server") or \
                              results.get("https:/", {}).get("headers", {}).get("Server", "")

    # --- OPTIONS ---
    output["options"] = results.get("http: OPTIONS /", results.get("https: OPTIONS /", {}))

    return output


def display_vllm_info(info, server_info):
    """Zeigt die gesammelten vLLM-Informationen strukturiert an."""
    ip = server_info.get("ip", "?")
    port = server_info.get("port", "?")
    server_type = server_info.get("type", "unbekannt")

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print_header(f"vLLM / {server_type} Monitoring – {ip}:{port}  ({now})")

    # --- Server Header ---
    if info.get("server_header"):
        print_section("Server-Header")
        for k, v in info.get("all_headers", {}).items():
            if v:
                if k == "Date":
                    print(f"    {k}: {v}")
                else:
                    print(f"    {k}: {v[:200]}")

    # --- Health ---
    print_section("Health-Status")
    health = info.get("health")
    if health:
        elapsed = health.get("elapsed_ms", 0)
        raw = health.get("raw", False)
        data = health.get("data", "")
        if data is None:
            print(f"    Status: nicht verfügbar (Antwort: {elapsed:.0f} ms)")
        elif raw:
            # http_request-Rohdaten (kann leer sein = OK bei vLLM)
            if data.strip():
                try:
                    j = json.loads(data)
                    for k, v in j.items():
                        if v is not None and v != "":
                            print(f"    {k}: {v}")
                except json.JSONDecodeError:
                    print(f"    Body: {data[:200]}")
            else:
                print(f"    Status: OK (200, leerer Body) – {elapsed:.0f} ms")
        elif isinstance(data, dict):
            for k, v in data.items():
                if v is not None and v != "":
                    print(f"    {k}: {v}")
        else:
            print(f"    Body: {str(data)[:200]}")
    else:
        print("    Kein /health-Endpoint verfügbar")

    # --- Version ---
    if info.get("version"):
        print_section("Server-Version")
        ver = info["version"]
        for k, v in ver.items():
            if v:
                print(f"    {k}: {v}")

    # --- OpenAI Models ---
    if info.get("openai_models"):
        om = info["openai_models"]
        print_section(f"Modelle (OpenAI API) – {om['count']} gefunden")
        for m in om["items"]:
            print(f"    Modell: {m['id']}")
            print(f"      owned_by  : {m.get('owned_by', '?')}")
            print(f"      max_model_len : {m.get('max_model_len', '?')}")
            print(f"      root    : {m.get('root', '?')}")

    # --- Model Served Models (vLLM Core) ---
    if info.get("model_served_models"):
        ms = info["model_served_models"]
        print_section(f"Modell-Details (vLLM model_served_models) – {ms['count']} Modell(e)")
        for idx, m in enumerate(ms["items"]):
            print(f"    Modell [{idx}]:")
            for k, v in m.items():
                if v is not None and v != "":
                    if k == "gpu_memory_usage":
                        print(f"      {k:30s}: {v}")
                    elif isinstance(v, str) and len(v) > 200:
                        print(f"      {k:30s}: {v[:200]}…")
                    else:
                        print(f"      {k:30s}: {v}")

    # --- Prometheus Metrics ---
    if info.get("metrics_raw"):
        display_metrics(info["metrics_raw"])

    # --- OPTIONS / CORS ---
    opts = info.get("options", {})
    if opts:
        print_section("HTTP OPTIONS / CORS")
        allow = opts.get("data", {}).get("allow", "")
        cors = opts.get("data", {}).get("cors", "")
        if allow:
            print(f"    Allow     : {allow}")
        if cors:
            print(f"    CORS      : {cors}")

    # --- Unbekannte Endpunkte ---
    unknown_endpoints = []
    for key in info:
        if key not in ("server_header", "all_headers", "openai_models",
                       "model_served_models", "version", "health",
                       "metrics_raw", "options", "all_headers"):
            unknown_endpoints.append(key)
    if unknown_endpoints:
        print_section("Weitere Endpunkte")
        for ep in unknown_endpoints:
            print(f"    - /{ep}")


def display_metrics(metrics_entry):
    """Parst und zeigt Prometheus-Metriken lesbar an."""
    elapsed = metrics_entry.get("elapsed_ms", 0)
    raw = metrics_entry.get("data", "")
    if not raw:
        print_section("Prometheus-Metriken")
        print(f"    (keine Daten, HTTP-Status wurde bei Abfrage gemeldet)")
        return

    print_section(f"Prometheus-Metriken  ({elapsed:.0f} ms Antwortzeit)")

    lines = raw.strip().split("\n")

    # Gruppen
    gpu_metrics = []
    cache_metrics = []
    request_metrics = []
    token_metrics = []
    lora_metrics = []
    disk_metrics = []
    distributed_metrics = []
    spec_decode_metrics = []
    tp_metrics = []
    prompt_input_metrics = []
    other_metrics = []

    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            other_metrics.append(line)
            continue
        parts = line.split("{")
        name = parts[0].strip() if parts else line
        value_part = line[len(name):] if len(line) > len(name) else ""

        # Wert extrahieren
        value_str = value_part.split()[-1] if value_part else ""
        try:
            value = float(value_str)
        except (ValueError, IndexError):
            value = value_str

        label = ""
        if "{" in value_part:
            brace_end = value_part.find("}")
            if brace_end > 0:
                label = value_part[1:brace_end]

        if name.startswith("vllm:gpu"):
            gpu_metrics.append((label, value_str))
        elif "cache" in name.lower() or "kv" in name.lower():
            cache_metrics.append((label, value_str))
        elif "request" in name.lower() or "num_prompt" in name or "num_gen" in name or "time_to_first" in name:
            request_metrics.append((label, value_str))
        elif "token" in name.lower() or "speed" in name.lower():
            token_metrics.append((label, value_str))
        elif "lora" in name.lower():
            lora_metrics.append((label, value_str))
        elif "disk" in name.lower():
            disk_metrics.append((label, value_str))
        elif "distributed" in name.lower() or "world_size" in name or "rank" in name:
            distributed_metrics.append((label, value_str))
        elif "spec_decode" in name.lower():
            spec_decode_metrics.append((label, value_str))
        elif "num_total" in name or "num_active" in name or "num_cumulative" in name:
            token_metrics.append((label, value_str))
        elif "prompt" in name.lower() and "input" in name.lower():
            prompt_input_metrics.append((label, value_str))
        else:
            other_metrics.append(line)

    if gpu_metrics:
        print_section("GPU-Nutzung")
        for label, value in gpu_metrics:
            display = value
            try:
                if "memory_used_bytes" in label.lower() or "memory_allocated_bytes" in label.lower():
                    display = fmt_bytes(float(value) if isinstance(value, (int, float)) else 0)
            except (ValueError, TypeError):
                pass
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            print(f"    {lbl:50s} {display}")

    if cache_metrics:
        print_section("KV-Cache-Statistik")
        for label, value in cache_metrics:
            display = value
            try:
                if "used_ratio" in label.lower() or "utilization" in label.lower():
                    display = f"{float(value)*100:.1f}%"
                elif "num_tokens" in label.lower() or "capacity" in label.lower():
                    display = fmt_number(float(value))
            except (ValueError, TypeError):
                pass
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            print(f"    {lbl:50s} {display}")

    if request_metrics:
        print_section("Request-Statistik")
        for label, value in request_metrics:
            display = value
            try:
                if "time_to_first_token_seconds" in label or "time_per_output_seconds" in label:
                    display = fmt_duration(float(value))
                elif "time_waiting_seconds" in label:
                    display = fmt_duration(float(value))
                elif "num_running" in label or "num_swapped" in label or "num_waiting" in label:
                    display = str(int(float(value)))
            except (ValueError, TypeError):
                pass
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            print(f"    {lbl:50s} {display}")

    if token_metrics:
        print_section("Token-Statistik & Durchsatz")
        for label, value in token_metrics:
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            if "speed" in label.lower():
                try:
                    display = f"{float(value):.1f} Token/s"
                except (ValueError, TypeError):
                    display = value
            else:
                try:
                    display = fmt_number(float(value))
                except (ValueError, TypeError):
                    display = value
            print(f"    {lbl:50s} {display}")

    if lora_metrics:
        print_section("LoRA-Metriken")
        for label, value in lora_metrics:
            display = value
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            print(f"    {lbl:50s} {display}")

    if disk_metrics:
        print_section("Disk-Cache")
        for label, value in disk_metrics:
            display = value
            try:
                if "size_bytes" in label.lower():
                    display = fmt_bytes(float(value))
            except (ValueError, TypeError):
                pass
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            print(f"    {lbl:50s} {display}")

    if distributed_metrics:
        print_section("Distributed Serving")
        for label, value in distributed_metrics:
            display = value
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            print(f"    {lbl:50s} {display}")

    if spec_decode_metrics:
        print_section("Speculative Decoding")
        for label, value in spec_decode_metrics:
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            try:
                display = f"{float(value)*100:.1f}%" if isinstance(value, (int, float)) else value
            except (ValueError, TypeError):
                display = value
            print(f"    {lbl:50s} {display}")

    if prompt_input_metrics:
        print_section("Prompt Input Statistiken")
        for label, value in prompt_input_metrics:
            lbl = label.replace("{", "").replace("}", "").replace(",", ", ")[:60] if label else "—"
            try:
                display = fmt_number(float(value))
            except (ValueError, TypeError):
                display = value
            print(f"    {lbl:50s} {display}")

    # Header/Meta-Metriken
    header_lines = [l for l in other_metrics if l and l.startswith("# ")]
    if header_lines:
        print_section("Metadaten (Prometheus Header)")
        for h in header_lines:
            print(f"    {h}")

    remaining = [l for l in other_metrics if l and not l.startswith("# ")]
    if remaining:
        print_section("Weitere Metriken")
        for l in remaining[:50]:  # Limit Ausgabe
            print(f"    {l}")
        if len(remaining) > 50:
            print(f"    … ({len(remaining) - 50} weitere Metriken)")

    # Rohdaten-Anzeige am Ende
    print_section("Rohdaten (erste 50 Zeilen)")
    raw_lines = raw.strip().split("\n")
    for i, line in enumerate(raw_lines[:50]):
        print(f"    {line}")
    if len(raw_lines) > 50:
        print(f"    … ({len(raw_lines) - 50} weitere Zeilen)")


# ---------------------------------------------------------------------------
# Ollama-spezifisch
# ---------------------------------------------------------------------------

def display_ollama_info(results, server_info):
    ip = server_info.get("ip", "?")
    port = server_info.get("port", "?")
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    print_header(f"Ollama Monitoring – {ip}:{port}  ({now})")

    # Version
    for scheme in ["http", "https"]:
        key = f"{scheme}:/api/version"
        if key in results and results[key]["data"]:
            v = results[key]["data"]
            print_section("Version")
            for k, val in v.items():
                print(f"    {k}: {val}")

    # Tags / Models
    for scheme in ["http", "https"]:
        key = f"{scheme}:/api/tags"
        if key in results and results[key]["data"]:
            d = results[key]["data"]
            models = d.get("models", [])
            print_section(f"Modelle ({len(models)} gefunden)")
            for m in models:
                print(f"    Name   : {m.get('name', '?')}")
                print(f"    Mod_ID  : {m.get('model', '?')}")
                print(f"    Modified: {m.get('modified_at', '?')}")
                print(f"    Size    : {fmt_bytes(m.get('size', 0))}")
                det = m.get("details", {}) or {}
                if det:
                    print(f"    Parent  : {det.get('parent_model_name', '?')}")
                    print(f"    Format  : {det.get('format', '?')}")
                    print(f"    Family  : {det.get('family', '?')}")
                    print(f"    FType   : {det.get('ftype', '?')}")
                    print(f"    Quant   : {det.get('quantization_level', '?')}")
                    print(f"    Params  : {det.get('parameter_size', '?')}")
                    print(f"    Context : {det.get('context_length', '?')}")

    # Config
    for scheme in ["http", "https"]:
        key = f"{scheme}:/api/config"
        if key in results and results[key]["data"] is not None:
            cfg = results[key]["data"]
            print_section("Server-Konfiguration")
            for k, v in cfg.items():
                if isinstance(v, (dict, list)) and len(str(v)) < 500:
                    print(f"    {k}: {json.dumps(v, ensure_ascii=False)}")
                elif isinstance(v, (dict, list)):
                    print(f"    {k}: (Objekt, {len(str(v))} Zeichen)")
                else:
                    print(f"    {k}: {v}")

    # Show (model ausgeben – testet ob Modell im Speicher)
    if models and len(models) > 0:
        print_section("Modell im GPU-Speicher?")
        model_name = models[0].get("name", "")
        for scheme in ["http", "https"]:
            # /api/pull mit show=true
            show_key = f"{scheme}:/api/show/{model_name}"
            if show_key in results:
                sr = results[show_key]
                if sr.get("data"):
                    sd = sr["data"]
                    print(f"    Architektur      : {sd.get('architectures', [{}])[0].get('architectures', ['?'])[0] if sd.get('architectures') else '?'}")
                    arch = sd.get("architecture", "")
                    if arch:
                        print(f"    Architektur (raw): {arch}")
                    print(f"    Parameter        : {sd.get('parameter_size', '?')}")
                    print(f"    Quantisierung    : {sd.get('quantization_level', '?')}")
                    print(f"    Kontext-Länge    : {sd.get('context_length', '?')}")
                    print(f"    Embedding-Dim    : {sd.get('embedding_length', '?')}")
                    print(f"    Block-Anzahl     : {sd.get('block_count', '?')}")
                    mm = sd.get("message", "")
                    if mm:
                        print(f"    System Prompt    : {mm[:200]}")
                    break

    # Raw API endpoints
    print_section("Verfügbare API-Pfade")
    extra_paths = ["/api/embeddings", "/api/embed", "/api/embeddings/batch",
                   "/api/chat", "/api/generate", "/api/pull", "/api/cancel",
                   "/api/create", "/api/ps", "/api/progress"]
    for scheme in ["http", "https"]:
        available = []
        for p in extra_paths:
            key = f"{scheme}:{p}"
            if key in results and results[key].get("data") is not None:
                available.append(p)
        if available:
            print(f"    ({scheme}): {', '.join(available)}")


# ---------------------------------------------------------------------------
# Prompt-Test
# ---------------------------------------------------------------------------

def run_prompt_test(schemes, ip, port, server_type):
    """Sende einen Test-Prompt an den Server."""
    prompt = input("\n  Prompt eingeben (Enter für Standard): ").strip()
    if not prompt:
        prompt = "Schreibe einen kurzen Satz über KI."

    print(f"\n  Sende Prompt an {ip}:{port} …")
    t0 = time.monotonic()

    if server_type == "vLLM" or server_type == "OpenAI-kompatibel":
        payload = {
            "model": "",  # wird evtl. vom Server default gesetzt
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 256,
            "temperature": 0.7,
        }
        for scheme in schemes:
            code, headers, body, elapsed = http_request(
                scheme, ip, port, "/v1/chat/completions",
                method="POST", timeout=60,
                body=json.dumps(payload),
                headers={"Content-Type": "application/json"})
            print(f"    HTTP {code} | {elapsed:.0f} ms")
            print(f"    Response: {body[:500]}")
            if code == 200:
                return
    elif server_type == "Ollama":
        payload = {
            "model": "",
            "prompt": prompt,
            "stream": False,
            "max_tokens": 256,
        }
        for scheme in schemes:
            code, headers, body, elapsed = http_request(
                scheme, ip, port, "/api/generate",
                method="POST", timeout=60,
                body=json.dumps(payload),
                headers={"Content-Type": "application/json"})
            print(f"    HTTP {code} | {elapsed:.0f} ms")
            print(f"    Response: {body[:500]}")
            if code == 200:
                return

    print("    (Keine Antwort vom Chat/Generate-Endpoint)")


# ---------------------------------------------------------------------------
# Multi-Port-Entdeckung
# ---------------------------------------------------------------------------

def find_llm_ports(ip):
    """Scanne alle bekannten LLM-Ports und gib offene Ports zurück."""
    open_ports = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futs = {pool.submit(port_open, ip, p, 1.0): p for p in ALL_LLM_PORTS}
        for fut in as_completed(futs):
            p = futs[fut]
            try:
                if fut.result():
                    open_ports.append(p)
            except Exception:
                pass
    return sorted(open_ports)


# ---------------------------------------------------------------------------
# Voll-Scan
# ---------------------------------------------------------------------------

def full_monitor(ip, port, mode="all"):
    # 1) Alle offenen LLM-Ports finden
    if port:
        monitored_ports = [port]
        print(f"  Gegebener Port: {port}")
    else:
        print("  Scanne nach offenen LLM-Ports …")
        monitored_ports = find_llm_ports(ip)
        if not monitored_ports:
            print("  [!] Keine offenen LLM-Ports gefunden (Ports 22,1234,1235,3000,4000,5000,5001,")
            print("      7860,8000,8001,8080,8081,8443,8888,9000,9081,9082,11434,11435).")
            print("  Versuche 8000 als Fallback …")
            monitored_ports = [8000]

    if mode == "json":
        for p in monitored_ports:
            export_json(ip, p)
        return

    # 2) Jeder Port einzeln monitoren
    for port in monitored_ports:
        # Server-Erkennung
        schemes = detect_schemes(ip, port)
        if not schemes:
            print(f"\n  [!] {ip}:{port} nicht erreichbar (HTTP). Überspringe.")
            continue

        print_header(f"LLM Monitor – {ip}:{port}")
        print(f"  Schemata: {', '.join(schemes)}")

        server_info = detect_server(schemes, ip, port)
        server_type = server_info.get("type", "unbekannt")
        print(f"  Server-Typ: {server_type}")

        if mode == "health":
            collected = collect_vllm_info(schemes, ip, port)
            parsed = parse_vllm_results(collected)
            if server_type == "Ollama":
                display_ollama_info(collected, server_info)
            else:
                display_vllm_info(parsed, server_info)

        elif mode == "models":
            collected = collect_vllm_info(schemes, ip, port)
            parsed = parse_vllm_results(collected)
            if server_type == "Ollama":
                display_ollama_info(collected, server_info)
            else:
                display_vllm_info(parsed, server_info)

        elif mode == "metrics":
            collected = collect_vllm_info(schemes, ip, port)
            metrics = None
            for key in ["/metrics"]:
                if key in collected and collected[key].get("data"):
                    metrics = collected[key]
                    break
            if metrics:
                display_metrics(metrics)
            else:
                print("  Keine Prometheus-Metriken verfügbar.")

        elif mode == "prompt":
            run_prompt_test(schemes, ip, port, server_type)

        elif mode == "all":
            print("  Sammle alle verfügbaren Informationen …")
            collected = collect_vllm_info(schemes, ip, port)
            parsed = parse_vllm_results(collected)
            if server_type == "Ollama":
                display_ollama_info(collected, server_info)
            else:
                display_vllm_info(parsed, server_info)

        print()

    print_header("Monitor-Scan abgeschlossen.")
    print()


# ---------------------------------------------------------------------------
# IP-Abfrage
# ---------------------------------------------------------------------------

def ask_ip():
    last = load_last_ip()
    while True:
        if last:
            prompt = f" Ziel-IP [{last}]: "
        else:
            prompt = " Ziel-IP: "
        raw = input(prompt).strip()
        if not raw and last:
            raw = last
        if valid_ip(raw):
            save_last_ip(raw)
            return raw
        print("  Bitte eine gültige IP-Adresse eingeben.")


# ---------------------------------------------------------------------------
# Ausgabe-Formatierung (JSON-Export)
# ---------------------------------------------------------------------------

def export_json(ip, port):
    """Exportiert alle Infos als JSON (für externe Monitoring-Tools)."""
    port = guess_port(ip, port)
    schemes = detect_schemes(ip, port)
    if not schemes:
        print("Host nicht erreichbar.")
        return

    server_info = detect_server(schemes, ip, port)
    collected = collect_vllm_info(schemes, ip, port)

    output = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "target": {"ip": ip, "port": port},
        "server": {
            "type": server_info["type"],
            "server_header": server_info.get("server_header", ""),
        },
        "collected": {},
    }

    # Daten bereinigen (Headers etc. entfernen)
    for key, val in collected.items():
        clean = {}
        if isinstance(val, dict):
            clean["data"] = val.get("data")
            clean["elapsed_ms"] = val.get("elapsed_ms")
            clean["scheme"] = val.get("scheme")
        else:
            clean = val
        output["collected"][key] = clean

    print(json.dumps(output, indent=2, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Hauptmenü
# ---------------------------------------------------------------------------

def menu():
    print()
    print("█" * 72)
    print("█  LLM Monitor  –  _monitor.sh                                   █")
    print("█  Maximale Informationsgewinnung aus LLM-Servern                 █")
    print("█" * 72)

    ip = ask_ip()

    while True:
        print()
        print(f"  Ziel: {ip}")
        print("  ─────────────────────────────────────────")
        print("  1) Voll-Scan – alle Infos (Health, Modelle, GPU, Metriken)")
        print("  2) Health-Check")
        print("  3) Modell-Infos")
        print("  4) Prometheus-Metriken (Rohdaten + geparst)")
        print("  5) Prompt-Test (Chat/Generate)")
        print("  6) JSON-Export (für externe Tools)")
        print("  7) IP wechseln")
        print("  0) Beenden")
        choice = input("  Auswahl: ").strip()

        if choice == "1":
            full_monitor(ip, None, mode="all")
        elif choice == "2":
            full_monitor(ip, None, mode="health")
        elif choice == "3":
            full_monitor(ip, None, mode="models")
        elif choice == "4":
            full_monitor(ip, None, mode="metrics")
        elif choice == "5":
            full_monitor(ip, None, mode="prompt")
        elif choice == "6":
            full_monitor(ip, None, mode="json")
        elif choice == "7":
            ip = ask_ip()
        elif choice == "0":
            print("  Beendet.")
            return
        else:
            print("  Ungültige Auswahl.")


# ---------------------------------------------------------------------------
# CLI-Arguments
# ---------------------------------------------------------------------------

def main():
    try:
        if len(sys.argv) >= 2:
            ip = sys.argv[1]
            port = int(sys.argv[2]) if len(sys.argv) > 2 else None
            mode = sys.argv[3] if len(sys.argv) > 3 else "all"
            full_monitor(ip, port, mode=mode)
        else:
            menu()
    except (KeyboardInterrupt, EOFError):
        print("\n  Abgebrochen.")
        sys.exit(0)


if __name__ == "__main__":
    main()
