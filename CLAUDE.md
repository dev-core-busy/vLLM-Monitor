# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

A toolkit of standalone Python 3 CLI tools for discovering and inspecting LLM
servers (vLLM, Ollama, LM Studio, llama.cpp, text-generation-webui, LocalAI,
KoboldCpp, TGI, …) on the network. Two tools form a discover → inspect pipeline:

- **`scan_for_llms.sh`** — *discovery*. Scans a target IP's ports and identifies
  which LLM service (if any) is behind each open port.
- **`monitor.sh`** — *deep inspection*. Given an IP (and optionally a port),
  extracts the maximum amount of information from a running LLM server: health,
  models, GPU/cache/token Prometheus metrics, endpoint support, and an
  interactive prompt test.

A second, standalone pair implements **continuous time-series monitoring** of
one or more vLLM instances (host via `VLLM_HOST`, ports/labels via
`VLLM_TARGETS`, e.g. `"8000:modelA,8001:modelB"`):

- **`vllm_collector.sh`** — long-running collector. Pulls both `/metrics`
  endpoints every 15 s, parses the Prometheus text, and appends per-model rows
  to a local SQLite DB (`vllm_metrics.db`). Purges data older than 30 days.
- **`vllm_dashboard.sh`** — `http.server` on `127.0.0.1:8899` serving an HTML +
  Chart.js dashboard and a `/api/series` JSON endpoint. Computes rates
  (tokens/s, requests/s), average latencies (TTFT/E2E/ITL from histogram
  `Δsum/Δcount`), and prefix-cache hit rate from the stored cumulative counters,
  graphed **per model over time**.

Both files are named `*.sh` but are **Python 3** (shebang `#!/usr/bin/env
python3`) and use **only the standard library** — no `pip install` needed.

## Running

```bash
python3 scan_for_llms.sh          # interactive menu (discovery)
python3 monitor.sh                # interactive menu (inspection)

# monitor.sh also has a non-interactive CLI:
python3 monitor.sh <IP>                 # full scan, auto-detects port
python3 monitor.sh <IP> <PORT>          # full scan on a specific port
python3 monitor.sh <IP> <PORT> health   # modes: health | models | metrics | prompt | json | all
python3 monitor.sh <IP> 8000 json       # machine-readable JSON export

# Continuous monitoring (two long-running processes):
python3 vllm_collector.sh               # permanent 15 s pull -> vllm_metrics.db
python3 vllm_collector.sh once          # single scrape (test)
python3 vllm_collector.sh status        # summary of stored series
python3 vllm_dashboard.sh               # dashboard on http://127.0.0.1:8899
python3 vllm_dashboard.sh 8080          # custom port
```

The collector and dashboard share `vllm_metrics.db` (SQLite, wide `samples`
table keyed by `(ts, port)`, one row per model per scrape storing raw gauges +
cumulative counters + histogram sum/count). Rates and averages are derived at
query time in the dashboard, never pre-aggregated — so counter resets (server
restart) are handled by dropping negative deltas.

**TODO (deferred):** true GPU-hardware metrics (SM %, VRAM, temperature, watts)
are **not** yet collected — vLLM's `/metrics` only exposes engine-level data,
and a read-only SSH user on the target host may have no `nvidia-smi` access. Add a
DCGM/node exporter on the target (or a privileged probe) and a second collector
source when that becomes available.

`session.sh` is not a tool — it is a one-line helper that resumes a specific
Claude Code session (`claude --resume <uuid>`).

## Conventions (apply to all new code and output)

- **All UI strings, comments, prompts, and output are in German** — keep new
  output consistent. (Note: `scan_for_llms.sh` avoids umlauts in output;
  `monitor.sh` uses them freely.)
- **Standard library only.** Do not introduce third-party dependencies.
- Last-used IP is persisted per-tool: `~/.scan_for_llms_last_ip` and
  `~/.monitor_last_ip`.
- TLS verification is intentionally disabled (`SSL_CTX` with `CERT_NONE`) so the
  tools can probe self-signed HTTPS endpoints.
- Both tools share the same known-LLM-port list (kept in sync manually):
  `STANDARD_PORTS` in `scan_for_llms.sh:39` and `ALL_LLM_PORTS` in
  `monitor.sh:60`. **Update both when adding a port.**

## Architecture: `scan_for_llms.sh` (discovery)

Detection happens inside `identify_service()` (`scan_for_llms.sh:162`) in
priority order:

1. **SSH** — raw TCP banner starts with `SSH-`.
2. **HTTP/HTTPS probe** — tries `http` then `https` on `/`; if neither responds,
   marks the port `"offen (unbekannt)"`.
3. **Squid proxy** — `Server:` header contains `squid`.
4. **OpenAI-compatible** — `GET /v1/models` returns `{"data": [...]}` (matches
   vLLM, llama.cpp, LocalAI, LM Studio); sub-classified via `owned_by` and the
   `Server` header (vLLM vs. uvicorn/FastAPI vs. generic).
5. **Ollama** — `GET /api/version` or `GET /api/tags` responds.
6. **Generic HTTP** — fallback when no LLM API is detected.

Key functions:
- `scan_ports()` (`scan_for_llms.sh:288`): parallel TCP scanner via
  `ThreadPoolExecutor` (`MAX_WORKERS = 200`).
- `report()` (`scan_for_llms.sh:346`): iterates open ports, calls
  `identify_service()`, prints results.
- `menu()` (`scan_for_llms.sh:427`): interactive loop — `1` standard scan,
  `2` full range scan, `3` change IP, `0` quit.

Tunable constants at the top of the file: `CONNECT_TIMEOUT = 2.0`,
`HTTP_TIMEOUT = 6.0`, `MAX_WORKERS = 200`.

Note: `host_alive()` (`scan_for_llms.sh:303`) is defined but never called.

## Architecture: `monitor.sh` (inspection)

The inspection flow is a **collect → parse → display** pipeline, orchestrated by
`full_monitor()` (`monitor.sh:1002`), which dispatches on `mode`:

1. **Port selection** — uses the given port, or `find_llm_ports()` /
   `guess_port()` to auto-discover one from `ALL_LLM_PORTS` (falls back to 8000).
2. **`detect_schemes()`** (`monitor.sh:172`) — determines whether the port
   speaks `http`, `https`, or both.
3. **`detect_server()`** (`monitor.sh:262`) — classifies the server type
   (vLLM / Ollama / generic OpenAI-compatible / …).
4. **`collect_vllm_info()`** (`monitor.sh:361`) — fires a broad set of probes in
   parallel via `fetch_all()`: `/v1/models`, `/v1/model_served_models`,
   `/health`, `/version`, `/metrics`, plus `OPTIONS /` for CORS/method support
   and existence checks for `/v1/embeddings`, `/v1/rerank`, etc. Returns raw
   per-endpoint results keyed by path.
5. **`parse_vllm_results()`** (`monitor.sh:423`) — interprets the raw results
   into a display-ready structure.
6. **Display** — `display_vllm_info()` (`monitor.sh:523`),
   `display_metrics()` (`monitor.sh:633`, parses Prometheus text into
   GPU/cache/request/token stats), or `display_ollama_info()`
   (`monitor.sh:836`) depending on server type.

Other entry points: `run_prompt_test()` (`monitor.sh:932`) sends a live
chat/generate request; `export_json()` (`monitor.sh:1106`) emits a cleaned JSON
document (timestamp, target, server, per-endpoint data) for external monitoring.

`monitor.sh` has both an interactive `menu()` (`monitor.sh:1145`) and the
non-interactive CLI in `main()` (`monitor.sh:1193`, `argv = ip [port] [mode]`).

Tunable constants: `CONNECT_TIMEOUT = 3.0`, `HTTP_TIMEOUT = 10.0`,
`METRICS_TIMEOUT = 15.0` (metrics can be slow), `MAX_WORKERS = 30`.

## Adding support for a new LLM service

1. Add its default port(s) to **both** `STANDARD_PORTS` (`scan_for_llms.sh:39`)
   and `ALL_LLM_PORTS` (`monitor.sh:60`).
2. In `scan_for_llms.sh`, add a detection block inside `identify_service()`,
   between the Ollama block and the generic-HTTP fallback. Follow the existing
   pattern: probe a characteristic endpoint, populate `result["type"]`,
   `result["models"]`, `result["api_base"]`, `result["endpoints"]`, then
   `return result`.
3. In `monitor.sh`, extend `detect_server()` to recognize it and, if its
   endpoints differ, add them to `collect_vllm_info()` and a corresponding
   `display_*` branch in `full_monitor()`.
