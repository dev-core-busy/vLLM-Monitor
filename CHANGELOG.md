# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.
Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
die Versionierung an [Semantic Versioning](https://semver.org/lang/de/).

## [0.12.1] – 2026-07-11

### Geändert
- **Zentrale KI-Config statt pro-Browser:** Endpunkt/Modell/Key aus der
  Server-Env (`VLLM_AI_*`) gelten als Standard für **alle** Frontends und werden
  über `GET /api/config` bekanntgegeben. Endpunkt/Modell bleiben pro Browser
  (Cookie) überschreibbar.
- **API-Key nur noch server-seitig:** Der Key wird nicht mehr im Browser
  gespeichert oder mitgesendet und nie ausgeliefert – `/api/config` meldet nur,
  *ob* ein Key gesetzt ist. Das ⚙-Menü zeigt statt eines Eingabefelds den Status
  „server-seitig gesetzt". Ein evtl. alter `vllm_ai_key`-Cookie wird entfernt.

## [0.12.0] – 2026-07-11

### Neu
- **KI-Auswertung je Diagramm**: Der neue 🔍-Button (links vom Maximieren-Button)
  öffnet ein Analyse-Panel mit lokal berechneten Kennzahlen (Ø/Min/Max/Aktuell/
  Trend je Serie, Modellvergleich) und einer optionalen KI-Bewertung
  (Zustand, Auffälligkeiten, Vergleich, Handlungsempfehlung).
- Die KI läuft über einen frei konfigurierbaren **OpenAI-kompatiblen
  Chat-Endpunkt** – z. B. direkt eine der überwachten vLLM-Instanzen, sodass
  keine Daten das Netz verlassen. Konfiguration im ⚙-Menü (Endpunkt, Modell,
  API-Key, An/Aus) oder per Env (`VLLM_AI_URL`, `VLLM_AI_MODEL`, `VLLM_AI_KEY`,
  `VLLM_AI_MAX_TOKENS`); `setup.sh` fragt den Endpunkt beim Einrichten ab.
- Neuer Backend-Endpunkt `POST /api/analyze` als serverseitiger Proxy zum
  Chat-Endpunkt (kein CORS/Key im Browser, stdlib-only).

### Behoben / robust
- Endpunkt-Angabe ist tolerant: `host:port`, `…/v1` oder die volle
  `…/v1/chat/completions`-URL werden akzeptiert (Pfad wird ergänzt).
- Reasoning-Modelle (z. B. Qwen3): Token-Budget erhöht und Fallback auf das
  Reasoning-Feld, falls `content` leer bleibt.

## [0.11.2] – 2026-07-10

### Geändert
- Default-Farben angepasst: GPU = rot (`#B80F2E`), Qwen = blau (`#35628B`),
  faster-whisper = grau (`#9C9D9F`); Gemma bleibt grün.

### Behoben
- Gewählter **Zeitraum** wird jetzt im Cookie (`vllm_range`) gemerkt und beim
  nächsten Verbinden wiederhergestellt (statt immer auf 1 h zurückzuspringen).

## [0.11.1] – 2026-07-10

### Neu
- **Vierte Kacheldichte 6×5** (noch kleinere Kacheln) als weiteres
  Punktraster-Icon; Auswahl wie gehabt im Cookie gemerkt.
- **Feste Default-Farben je Instanz**: Qwen = blau, faster-whisper = rosa,
  Gemma = grün, GPU = gelb (namensbasiert statt nach Sortierung); weiterhin per
  Farbwähler überschreibbar.

## [0.11.0] – 2026-07-10

### Neu
- **GPU-Hardware-Metriken** über einen **NVIDIA DCGM-Exporter**
  (`VLLM_DCGM_TARGETS=host:port`, Standard-Port 9400): SM-/Speicher-Auslastung,
  VRAM (belegt/gesamt), Temperatur und Leistungsaufnahme je GPU werden
  mitgeschrieben. Dashboard zeigt eigene GPU-Panels (Auslastung, Temperatur,
  Leistung) und eine GPU-KPI-Karte mit Temperatur-Warnung (> 85 °C).
- **Farbwähler je Instanz**: In jeder KPI-Karte (Modelle **und** GPU) lässt sich
  über ein Farbfeld die Diagramm-Farbe frei wählen; sie wird sofort in
  gemeinsamer Legende und allen Diagrammen übernommen und im Cookie gemerkt.

## [0.10.1] – 2026-07-10

### Neu
- **Kacheldichte** über drei Punktraster-Icons (5×4 / 4×3 / 3×2) umschaltbar –
  kleinere Kacheln zeigen mehr gleichzeitig; Auswahl im Cookie gemerkt.
- **⚙-Menü** bündelt Latenz-Perzentil und CSV-/JSON-Export (spart Platz in der
  Toolbar).
- **Gemeinsame Modell-Legende** über den Diagrammen statt einer Legende je
  Kachel (spart besonders im dichten Modus Platz); Klick blendet ein Modell in
  allen Diagrammen aus/ein (im Cookie gemerkt). Modell-Farben sind jetzt stabil.
- **Instanz-Tabelle einklappbar** (Button rechts, Zustand im Cookie).

## [0.10.0] – 2026-07-10

### Neu
- **Ollama-Unterstützung** (eigener Datenpfad, da kein Prometheus): Health
  (`/api/version`), geladenes Modell + **VRAM** (`/api/ps`), installierte Modelle
  (`/api/tags`) und ein optionaler **synthetischer Probe** (`/api/generate`) →
  Tokens/s und Latenz-Perzentile (TTFT/E2E/ITL) aus synthetisierten Histogrammen.
  Konfig: `VLLM_OLLAMA_TARGETS`, `VLLM_OLLAMA_PROBE`, `VLLM_OLLAMA_PROMPT`.
- **Ollama-Autoscan** (`VLLM_OLLAMA_AUTOSCAN`): Standard-Endpunkte werden bei
  jedem Scrape geprüft; ein gefundenes Ollama wird automatisch mitüberwacht und
  im Dashboard eingeblendet.
- **STT-Server** (faster-whisper o. ä.): `/health` → Online-Status + aktive
  Sessions + Modell/Device (`VLLM_STT_TARGETS`).
- Dashboard: **VRAM-Belegung-Panel** (GB), **Typ-Spalte** (vllm/ollama/stt) und
  VRAM in der Instanz-Tabelle; **Instanz-Tabelle einklappbar** (Button rechts,
  Zustand im Cookie).
- Neue DB-Spalten `vram_bytes` (samples) und `kind` (config) mit additiver
  Migration; DB-Pfad per `VLLM_DB` überschreibbar.
- `setup.sh`: Abfragen für Ollama- und STT-Instanzen.

## [0.9.4] – 2026-07-10

### Neu
- **Erklär-Tooltips**: Beim Überfahren jedes Kachel-Titels erscheint eine
  3–4-zeilige Erläuterung, *was* das Diagramm zeigt und *wie* man es liest.

### Geändert
- **Layout-Persistenz in Cookies** statt localStorage: Kachel-Reihenfolge,
  ausgeblendete Kacheln und Theme werden in Cookies gespeichert
  (`SameSite=Lax`, 365 Tage) und beim Neuladen wiederhergestellt.

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
