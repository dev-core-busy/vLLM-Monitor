# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.
Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
die Versionierung an [Semantic Versioning](https://semver.org/lang/de/).

## [0.9.3] – 2026-07-10

### Neu
- **HTTPS** direkt im Dashboard (stdlib `ssl`, ohne Reverse-Proxy) über
  `VLLM_TLS_CERT` + `VLLM_TLS_KEY`. Der TLS-Handshake läuft pro Verbindung im
  Handler-Thread, damit langlebige SSE-Verbindungen die Annahme neuer
  Verbindungen nicht blockieren.
- **`setup.sh`**: Option „HTTPS aktivieren?" mit Erzeugung eines self-signed
  Zertifikats (SAN = Dashboard-Adresse + `127.0.0.1` + `localhost`), separater
  Menüpunkt zum (Neu-)Erzeugen, `openssl` in der Abhängigkeitsprüfung,
  Deinstallation kann Zertifikat mitentfernen.
- **Zertifikats-Handling im Dashboard**: Sicherheits-Badge (🔒/⚠️), Warnbanner
  bei HTTP, Endpoint `GET /api/cert` (Download) und Install-Modal mit Anleitung
  für Windows/Linux/Firefox. Download per `fetch`→Blob, um Chromes Sperre für
  Downloads über noch nicht vertrauenswürdige (self-signed) Verbindungen zu
  umgehen.
- **Pro Kachel**: Buttons zum **Maximieren** (Vollbild-Overlay, Esc schließt)
  und **Ausblenden**; ausgeblendete Kacheln lassen sich per Toolbar-Button wieder
  einblenden (gemerkt via localStorage).

## [0.9.2] – 2026-07-09

### Behoben
- **Kacheln verschiebbar:** komplette Neuimplementierung als *schwebendes* Ziehen
  (Kachel hebt sich an und folgt der Maus) mit Platzhalter-Lücke; Landepunkt per
  Treffer-Test statt Nächste-Mitte-Distanz → kein zufälliges Springen mehr.
- **Alarm-Glocke / Statuszeile:** fehlendes `#status`-Element ergänzt (führte zu
  einem stillen Fehler bei jedem Klick/Update); Glocke gibt jetzt klare
  Rückmeldung. Sichere-Herkunft-Erkennung via `window.isSecureContext` – über
  http/LAN erscheint ein verständlicher Hinweis statt „nicht erlaubt".
- **Live-Countdown:** zeigt „aktualisiert vor N s" (zählt hoch, springt bei jedem
  SSE-Push zurück) statt bei 0 s einzufrieren.

### Geändert
- Mouseover-Tooltips für alle Bedienelemente der oberen Leiste.
- `Cache-Control: no-store`, damit kein veralteter Stand aus dem Browser-Cache läuft.
- Effizienz: Fadenkreuz zeichnet nur bei Positionsänderung neu; `capacityOf`
  einmal je Reihe statt je Datenpunkt.

## [0.9.1] – 2026-07-09

### Geändert
- **`setup.sh` ist jetzt menügeführt** (keine Parameter mehr): Abhängigkeitsprüfung
  (python3 ≥ 3.8, Standardmodule, systemd-User-Bus, Dateien), interaktive
  Installation mit Abfrage von Ziel-IP/Instanzen/Bind/Port und gemerkten
  Vorgaben, sowie vollständige Deinstallation (optional inkl. Datenbank,
  Einstellungen und Linger).

## [0.9.0] – 2026-07-09

Großer Dashboard-Ausbau.

### Neu
- **KPI-Statuskarten** je Instanz mit Farbampeln und **Schwellwert-Alarmen**
  (KV %, Fehler, offline) inkl. optionaler Browser-Benachrichtigung.
- **Latenz-Perzentile P50/P95/P99** (TTFT/E2E/ITL) aus Histogramm-Buckets,
  umschaltbar; ersetzt die reinen Mittelwerte.
- Neue Panels: **Preemptions/s**, **Wartend nach Grund** (capacity/deferred),
  **Requests nach Ergebnis** (stop/error/abort/length), **KV-Belegung in Tokens**
  relativ zur Kapazität.
- **Instanz-Übersicht** (Health, vLLM-Version, KV-Kapazität, max_model_len,
  gpu_mem, Prefix-Cache) über die neue `config`-Tabelle und `/api/config`.
- **Live-Push per Server-Sent-Events** (`/api/stream`) statt reinem Polling;
  Aktualisierungsmodus wählbar (Live / 5 / 15 / 60 s / Aus).
- **Zoom & Pan** (Mausrad/Drag), **synchrones Fadenkreuz** über alle Charts,
  **Counter-Reset-Marker** (vLLM-Neustart).
- **CSV-/JSON-Export**, **Hell/Dunkel-Umschalter**, **Modell-Toggle** (Legende),
  responsives Layout, GPU-Hardware-Platzhalter (DCGM-Roadmap).
- Collector: `host`-Spalte (Multi-Host-fähig), Histogramm-Buckets,
  `waiting_by_reason`, `request_success` nach `finished_reason`, `config`-Tabelle
  mit Health – inkl. automatischer Schema-Migration.

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
