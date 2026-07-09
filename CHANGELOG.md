# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.
Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
die Versionierung an [Semantic Versioning](https://semver.org/lang/de/).

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
