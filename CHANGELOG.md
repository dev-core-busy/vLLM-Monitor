# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.
Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
die Versionierung an [Semantic Versioning](https://semver.org/lang/de/).

## [0.8.1] – 2026-07-09

### Behoben
- **Dashboard:** NaN/Inf-Metrikwerte machten die JSON-API ungültig → jetzt auf
  `null` normalisiert.
- **Dashboard:** erster Punkt jedes Zeitfensters hatte keine Rate mehr
  (fehlender Vorgänger) → Ankerpunkt vor dem Fenster wird mitgeladen.
- **Collector:** Primärschlüssel `(ts, port)` → `(ts, port, model)`, damit
  mehrere Modelle auf einem Port nicht dieselbe Zeile überschreiben
  (inkl. automatischer DB-Migration).
- **Collector:** KV-Cache-Auslastung wird über mehrere Engines gemittelt statt
  summiert.
- **monitor.sh:** `/metrics` wurde als JSON geparst und schlug immer fehl → jetzt
  als Prometheus-Rohtext geholt; doppelte Endpunkt-Abfragen entfernt.

### Geändert
- **Dashboard:** Downsampling in SQL (Ziel ~800 Punkte/Reihe) für schnelle
  Abfragen über lange Zeiträume; `VLLM_LABEL` wird HTML-escaped.
- `scan_for_llms.sh`: toter Code (`host_alive`) entfernt.
- Neues `setup.sh` zum Installieren/Deinstallieren der systemd-Dienste inkl.
  Angabe der Ziel-IP.

## [0.8.0] – 2026-07-09

Erste öffentliche Version.

### Enthalten
- **`vllm_collector.sh`** – Dauerhafter Prometheus-Metrik-Sammler für vLLM-Server;
  schreibt pro Modell in eine SQLite-Zeitreihen-DB, mit automatischer Retention.
  Vollständig per Umgebungsvariablen konfigurierbar (`VLLM_HOST`, `VLLM_TARGETS`,
  `VLLM_INTERVAL`, `VLLM_RETENTION_DAYS`).
- **`vllm_dashboard.sh`** – Web-Dashboard (stdlib `http.server` + Chart.js) mit
  Auswertung pro Modell über die Zeit: KV-Cache, Requests, Token-Durchsatz,
  Latenz-Ø (TTFT/E2E/ITL), Prefix-Cache-Hit-Rate. Sekunden-Countdown bis zur
  nächsten Aktualisierung, konfigurierbare Bind-Adresse.
- **`scan_for_llms.sh`** – Discovery: scannt eine Ziel-IP nach LLM-Servern
  (vLLM, Ollama, LM Studio, llama.cpp, LocalAI, …).
- **`monitor.sh`** – Tiefeninspektion einer einzelnen LLM-Instanz (Health,
  Modelle, Metriken, Prompt-Test, JSON-Export).

### Bekannt / offen
- Echte GPU-Hardware-Metriken (SM %, VRAM, Temperatur, Watt) werden noch nicht
  erfasst – vLLM `/metrics` liefert nur Engine-Ebene. Geplant über einen
  DCGM-/node-Exporter auf dem Zielhost.
- Das Dashboard hat keine Authentifizierung; bei Netzwerk-Bindung ggf. per
  Firewall absichern.
