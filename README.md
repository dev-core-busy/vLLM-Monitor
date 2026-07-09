# vLLM Monitor

![Version](https://img.shields.io/badge/version-0.8.1-blue)
![Python](https://img.shields.io/badge/python-3.8%2B-blue)
![Lizenz](https://img.shields.io/badge/license-MIT-green)
![Abhängigkeiten](https://img.shields.io/badge/dependencies-stdlib--only-brightgreen)

Ein schlankes Toolkit zum **Aufspüren, Inspizieren und dauerhaften Überwachen**
von LLM-Servern im Netzwerk – mit Fokus auf **vLLM**, aber auch für Ollama,
LM Studio, llama.cpp, LocalAI, text-generation-webui u. a.

Das Herzstück ist ein **Monitoring-Stack**, der die Prometheus-Metriken eines
oder mehrerer vLLM-Server periodisch abholt, in einer lokalen SQLite-Datenbank
als Zeitreihe ablegt und **pro Modell grafisch über die Zeit** auswertet –
KV-Cache-Auslastung, Requests, Token-Durchsatz, Latenzen und Cache-Hit-Rate.

> **Ausschließlich Python-Standardbibliothek** – kein `pip install`, keine
> externen Dienste. Chart.js wird im Browser per CDN geladen.

---

## Inhaltsverzeichnis

- [Features](#features)
- [Architektur](#architektur)
- [Komponenten](#komponenten)
- [Installation](#installation)
- [Schnellstart](#schnellstart)
- [Konfiguration](#konfiguration)
- [Dashboard](#dashboard)
- [Als Dienst betreiben (systemd)](#als-dienst-betreiben-systemd)
- [Datenbank](#datenbank)
- [Discovery- und Inspektions-Tools](#discovery--und-inspektions-tools)
- [Einschränkungen & Roadmap](#einschränkungen--roadmap)
- [Sicherheit](#sicherheit)
- [Lizenz](#lizenz)

---

## Features

- 📈 **Zeitreihen-Monitoring pro Modell** – jede vLLM-Instanz getrennt, über
  frei wählbare Zeiträume (15 min bis 7 Tage).
- 🗃️ **Eigene SQLite-DB** – kein Prometheus/Grafana nötig; Raten und Latenzen
  werden aus den kumulativen Countern zur Abfragezeit berechnet.
- 🖥️ **Web-Dashboard** – acht Panels (Chart.js), Auto-Refresh mit
  Sekunden-Countdown, netzwerkweit erreichbar.
- 🔍 **Discovery** – Portscan einer Ziel-IP mit automatischer Erkennung des
  LLM-Diensttyps.
- 🩺 **Tiefeninspektion** – Health, Modelle, Prometheus-Metriken, Prompt-Test
  und JSON-Export für eine einzelne Instanz.
- 🧰 **Null Abhängigkeiten** – reine Standardbibliothek, läuft überall wo
  Python 3.8+ vorhanden ist.

## Architektur

```
   ┌─ vLLM :port /metrics ┐        ┌─────────────┐     ┌──────────────┐
   │  (Modell A)          ├─pull──▶│  Collector  │────▶│  SQLite      │
   └─ vLLM :port /metrics ┘  15 s  │  (Python)   │     │  Zeitreihe   │
      (Modell B)                   └─────────────┘     └──────┬───────┘
                                                             │
                                       ┌─────────────────────▼────────┐
                                       │  Dashboard (http.server)      │
                                       │  Raten/Latenzen je Modell,    │
                                       │  Chart.js über die Zeit       │
                                       └───────────────────────────────┘
```

Der **Collector** verdichtet beim Scrapen die roh gelabelten Prometheus-Serien
je Modell zu einer Zeile. Das **Dashboard** liest dieselbe DB und berechnet
daraus die anzeigefertigen Kurven – Counter-Resets (Server-Neustart) werden
durch Verwerfen negativer Deltas abgefangen.

## Komponenten

| Datei | Rolle |
|-------|-------|
| `vllm_collector.sh` | Dauer-Pull der `/metrics`-Endpunkte → SQLite (mit Retention) |
| `vllm_dashboard.sh` | Web-Dashboard + JSON-API (`/api/series`) |
| `scan_for_llms.sh`  | Discovery: Ziel-IP nach LLM-Servern scannen |
| `monitor.sh`        | Tiefeninspektion einer einzelnen LLM-Instanz |

> **Hinweis zur Dateiendung:** Die Tools tragen aus historischen Gründen die
> Endung `.sh`, sind aber **Python-3-Skripte** (Shebang `#!/usr/bin/env python3`).
> Aufruf daher mit `python3 <datei>.sh`.

## Installation

```bash
git clone git@github.com:dev-core-busy/vLLM-Monitor.git
cd vLLM-Monitor
python3 --version   # 3.8 oder neuer
```

Mehr ist nicht nötig – es gibt keine Abhängigkeiten zu installieren.

## Schnellstart

```bash
# 1) Zielserver konfigurieren und Collector starten (sammelt permanent)
export VLLM_HOST=10.0.0.5
export VLLM_TARGETS="8000:mixtral,8001:llama3"
python3 vllm_collector.sh            # Strg+C zum Beenden

# In einem zweiten Terminal:
python3 vllm_collector.sh once       # einmaliger Test-Scrape
python3 vllm_collector.sh status     # Überblick der gespeicherten Reihen

# 2) Dashboard starten und im Browser öffnen
python3 vllm_dashboard.sh            # http://127.0.0.1:8899
```

## Konfiguration

Der Collector wird vollständig über **Umgebungsvariablen** gesteuert:

| Variable | Default | Bedeutung |
|----------|---------|-----------|
| `VLLM_HOST` | `127.0.0.1` | Host/IP der vLLM-Instanz(en) |
| `VLLM_TARGETS` | `8000:default` | Kommagetrennte Liste `port:label[,port:label…]`. Das Label ist nur Fallback – der echte Modellname kommt aus den Metriken. |
| `VLLM_INTERVAL` | `15` | Sekunden zwischen zwei Scrapes |
| `VLLM_RETENTION_DAYS` | `30` | Aufbewahrungsdauer; ältere Daten werden gelöscht |
| `VLLM_HTTP_TIMEOUT` | `15` | Timeout pro `/metrics`-Abruf (Sekunden) |

Dashboard:

| Variable | Default | Bedeutung |
|----------|---------|-----------|
| `VLLM_LABEL` | *(leer)* | Untertitel in der Kopfzeile (z. B. Host/Standort) |
| `VLLM_DASH_BIND` | `127.0.0.1` | Bind-Adresse; `0.0.0.0` = netzwerkweit erreichbar |

CLI-Aufruf des Dashboards: `python3 vllm_dashboard.sh [PORT] [BIND]`
(z. B. `python3 vllm_dashboard.sh 8899 0.0.0.0`).

## Dashboard

Acht Panels, jeweils **eine Linie pro Modell**:

| Panel | Quelle |
|-------|--------|
| KV-Cache-Auslastung (%) | `vllm:kv_cache_usage_perc` |
| Aktive / wartende Requests | `vllm:num_requests_running` / `…_waiting` |
| Generierung (Tokens/s) | Rate aus `vllm:generation_tokens_total` |
| Prompt-Durchsatz (Tokens/s) | Rate aus `vllm:prompt_tokens_total` |
| Time-to-First-Token Ø (ms) | `vllm:time_to_first_token_seconds` (Δsum/Δcount) |
| E2E-Latenz Ø (s) | `vllm:e2e_request_latency_seconds` |
| Inter-Token-Latenz Ø (ms) | `vllm:inter_token_latency_seconds` |
| Prefix-Cache-Hit-Rate (%) | `vllm:prefix_cache_hits` / `…_queries` |

Zeitraum wählbar (15 min – 7 Tage), Auto-Refresh alle 15 s mit Countdown in der
Kopfzeile (`0` = wird gerade aktualisiert). Die JSON-API unter
`GET /api/series?range=<sekunden>` liefert die aufbereiteten Reihen direkt.

## Als Dienst betreiben (systemd)

**Am einfachsten** über das mitgelieferte `setup.sh`:

```bash
./setup.sh install <ZIEL-IP> "9081:Qwen,9082:Gemma" 0.0.0.0 8899
./setup.sh status
./setup.sh uninstall
```

Das legt beide systemd-**User**-Services an, startet sie und aktiviert Linger
(Autostart nach Reboot). Alternativ von Hand — Beispiel für den Collector:

```ini
# ~/.config/systemd/user/vllm-collector.service
[Unit]
Description=vLLM Metrik-Collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/pfad/zu/vLLM-Monitor
Environment=VLLM_HOST=10.0.0.5
Environment=VLLM_TARGETS=8000:mixtral,8001:llama3
ExecStart=/usr/bin/python3 /pfad/zu/vLLM-Monitor/vllm_collector.sh loop
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now vllm-collector.service
loginctl enable-linger "$USER"     # Start auch ohne aktive Sitzung / nach Reboot
```

Das Dashboard analog mit `ExecStart=… vllm_dashboard.sh 8899 0.0.0.0` und
`Environment=VLLM_LABEL=…`.

## Datenbank

SQLite-Datei `vllm_metrics.db` (wird automatisch angelegt). Eine breite Tabelle
`samples`, Primärschlüssel `(ts, port)`, eine Zeile pro Modell und Scrape:

- **Gauges** (Momentanwerte): `requests_running`, `requests_waiting`, `kv_cache_usage`
- **Counter** (kumulativ): `prompt_tokens_total`, `generation_tokens_total`,
  `prefix_queries_total`, `prefix_hits_total`, `preemptions_total`,
  `requests_success_total`, `requests_error_total`
- **Histogramme** (Summe/Anzahl): `ttft_*`, `e2e_*`, `itl_*`

Raten und Durchschnitte werden **nicht** vorberechnet, sondern bei der Abfrage
aus den Deltas gebildet – so bleiben die Rohdaten flexibel auswertbar.

## Discovery- und Inspektions-Tools

```bash
# Ziel-IP nach LLM-Servern scannen (interaktives Menü)
python3 scan_for_llms.sh

# Eine Instanz tief inspizieren (nicht-interaktiv)
python3 monitor.sh <IP>                 # Voll-Scan, Port-Autoerkennung
python3 monitor.sh <IP> <PORT> health   # health | models | metrics | prompt | json | all
python3 monitor.sh <IP> <PORT> json     # maschinenlesbarer Export
```

`monitor.sh` läuft eine **collect → parse → display**-Pipeline: es sammelt breit
alle verfügbaren Endpunkte (`/v1/models`, `/health`, `/version`, `/metrics`,
CORS/OPTIONS, Embeddings/Rerank …) und stellt sie je nach erkanntem Servertyp
(vLLM / Ollama / generisch OpenAI-kompatibel) dar.

## Einschränkungen & Roadmap

- ⚠️ **Keine echten GPU-Hardware-Metriken.** vLLM `/metrics` liefert nur
  Engine-Ebene (KV-Cache, Requests, Token, Latenz). SM-Auslastung, VRAM,
  Temperatur und Leistungsaufnahme sind **nicht** enthalten.
  *Geplant:* optionaler zweiter Collector-Datenquelle über einen
  DCGM-/node-Exporter auf dem Zielhost.
- Alerting/Schwellwerte, CSV-Export und Perzentil-Kurven (P95/P99 statt Ø) sind
  angedacht.

## Sicherheit

- Das **Dashboard hat keine Authentifizierung**. Standardmäßig lauscht es nur
  auf `127.0.0.1`. Wird es an `0.0.0.0` gebunden, ist es (lesend) für jeden im
  Netz sichtbar – dann per Firewall/Reverse-Proxy absichern.
- Die Tools senden **keine** Daten nach außen; alle Metriken bleiben lokal in
  der SQLite-DB.

## Lizenz

[MIT](LICENSE) © 2026 Andreas Bender
