# vLLM Monitor

![Version](https://img.shields.io/badge/version-0.18.4-blue)
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
- 🚦 **KPI-Karten & Alarme** – Farbampeln je Instanz, Schwellwert-Warnungen
  (KV %, Fehler, offline) mit optionaler Browser-Benachrichtigung.
- 📐 **Latenz-Perzentile P50/P95/P99** (TTFT/E2E/ITL) aus den Histogramm-Buckets.
- 🤖 **KI-Auswertung je Diagramm** – der 🔍-Button öffnet ein Analyse-Panel mit
  lokal berechneten Kennzahlen (Ø/Min/Max/Aktuell/Trend, Modellvergleich),
  **Ausreißer-Erkennung** und **Prognose** sowie einer optionalen KI-Bewertung.
  Die KI läuft über einen frei konfigurierbaren **OpenAI-kompatiblen
  Chat-Endpunkt** – z. B. direkt eine der überwachten vLLM-Instanzen, sodass
  keine Daten das Netz verlassen. Zusätzlich ein **KI-Gesamt-Report** über alle
  Diagramme auf einen Klick.
- 🚨 **Alarm-Historie** – der Collector protokolliert Zustandswechsel (offline,
  KV-Cache, GPU-Temp, Fehler) mit Dauer; Schwellwerte sind konfigurierbar. KPI-
  Karten zeigen „offline seit X".
- 🧮 **Anomalie-Erkennung ohne KI** (robuste MAD-Analyse) als rote Marker in
  allen Diagrammen; **Zeitraum-Vergleich** (vorige Periode / gestern / letzte
  Woche) als Overlay; **Effizienz-/Kapazitäts-KPIs** (Tokens/Tag, GPU-Stunden,
  tok/s pro Watt) und Sättigungs-Prognose.
- 🗓️ **Geplanter KI-Schicht-Report** (`report`-CLI + systemd-Timer) schreibt
  einen deutschen Betriebs-Report in eine Datei.
- 🏷️ **Zeitachsen-Annotationen** (Deploy/Restart) als senkrechte Linien in allen
  Diagrammen – per Toolbar-Button oder CLI (`vllm_dashboard.sh annotate "…"`),
  ideal aus Deploy-Skripten.
- 🌐 **Mehrere Hosts/Cluster** über `host:port:label`-Targets; Host-Filter im
  Dashboard blendet Instanzen/KPIs/Diagramme je Host ein.
- 🫀 **Self-Monitoring** – der Collector schreibt einen Heartbeat (Status im
  Header sichtbar) und unterstützt den **systemd-Watchdog** (Auto-Neustart bei
  Hänger).
- 📡 **Prometheus-Exporter** – `GET /metrics` liefert die aufbereiteten Werte
  (Gauges + kumulative Counter, GPU, Collector-Status) im Prometheus-Textformat,
  sodass vorhandenes **Prometheus/Grafana** sie scrapen kann. Rein additiv zur
  eigenen SQLite-Pipeline.
- 🔐 **Benutzerverwaltung & Anmeldung** – das Dashboard verlangt immer einen
  Login (HTML-Formular). Start mit **admin/admin** (Passwortwechsel beim ersten
  Login erzwungen). Zwei Rollen: **Admin** (Vollzugriff + Verwaltung) und
  **Read-only** (nur Ansicht). Lokale und **Active-Directory-Nutzer** (einzeln
  oder per **AD-Gruppe**) sowie die **LDAP-Anbindung** werden im UI unter
  ⚙ → 👥 *Benutzer & Zugriff* gepflegt (persistent in `auth.json`, Passwörter
  PBKDF2-gehasht; LDAP Simple Bind + `memberOf`-Gruppensuche, nur stdlib).
- 🖧 **Instanzen im UI verwalten** – zusätzliche vLLM-/Ollama-/STT-/GPU-Ziele
  über das ⚙-Menü hinzufügen, pausieren oder entfernen (persistent in
  `targets.json`; der Collector lädt sie zur Laufzeit) – ohne systemd-Unit zu
  editieren. Schreibzugriff nur mit aktiver Authentifizierung sinnvoll.
- 📐 **Latenz-Perzentile P50/P95/P99** (TTFT/E2E/ITL) aus den Histogramm-Buckets.
- ⚡ **Live-Push (SSE)**, Zoom/Pan, synchrones Fadenkreuz, Counter-Reset-Marker,
  CSV-/JSON-Export, Hell/Dunkel, frei wählbare Kachelfarben & -dichte,
  Health-Übersicht & KV-Kapazität je Instanz.

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

**Einzeiler** (klonen + interaktives Setup starten):

```bash
git clone https://github.com/dev-core-busy/vLLM-Monitor.git && cd vLLM-Monitor && ./setup.sh
```

`setup.sh` öffnet ein Menü – Punkt **1) Installieren** fragt Ziel-IP, Instanzen
usw. ab und richtet die systemd-Dienste ein. Nur `git` und Python 3.8+ nötig,
keine weiteren Abhängigkeiten.

> **Erstanmeldung:** Das Dashboard verlangt immer einen Login – beim ersten
> Aufruf mit **`admin` / `admin`**; das Passwort muss sofort geändert werden.
> Weitere Benutzer und die optionale LDAP-/AD-Anbindung werden danach im UI
> unter ⚙ → 👥 *Benutzer & Zugriff* gepflegt.

Oder manuell:

```bash
git clone https://github.com/dev-core-busy/vLLM-Monitor.git
cd vLLM-Monitor
python3 --version   # 3.8 oder neuer
```

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
| `VLLM_TARGETS` | `8000:default` | Kommagetrennte Liste `[host:]port[:label][,…]`. Ohne Host gilt `VLLM_HOST` – mit Host-Präfix (`host:port:label`) lassen sich **mehrere Hosts/Cluster** mischen. Das Label ist nur Fallback – der echte Modellname kommt aus den Metriken. |
| `VLLM_INTERVAL` | `15` | Sekunden zwischen zwei Scrapes |
| `VLLM_RETENTION_DAYS` | `30` | Aufbewahrungsdauer; ältere Daten werden gelöscht |
| `VLLM_HTTP_TIMEOUT` | `15` | Timeout pro `/metrics`-Abruf (Sekunden) |
| `VLLM_DB` | *(Projektordner)* | Alternativer Pfad zur SQLite-Datei |
| `VLLM_TARGETS_FILE` | *(Projektordner)*`/targets.json` | Über das Dashboard verwaltete Zusatz-Instanzen; der Collector lädt die Datei bei jedem Scrape neu. Ergänzt `VLLM_TARGETS` & Co. |
| `VLLM_OLLAMA_TARGETS` | *(leer)* | Ollama-Instanzen `host:port:label,…` (Health/VRAM + Probe) |
| `VLLM_OLLAMA_PROBE` | `1` | Synthetischen Ollama-Probe (`/api/generate`) an/aus |
| `VLLM_OLLAMA_AUTOSCAN` | `<host>:11434,127.0.0.1:11434` | Endpunkte, die auf ein Ollama geprüft und automatisch eingebunden werden (`""` = aus) |
| `VLLM_STT_TARGETS` | *(leer)* | STT-Server (faster-whisper) `host:port:label,…` (nur `/health`) |
| `VLLM_DCGM_TARGETS` | *(leer)* | NVIDIA DCGM-Exporter `host:port,…` (Standard-Port 9400) für GPU-Hardware-Metriken (Auslastung, VRAM, Temperatur, Leistung) |
| `VLLM_ALERT_KV` | `90` | Alarm-Schwelle KV-Cache in % (>) |
| `VLLM_ALERT_TEMP` | `85` | Alarm-Schwelle GPU-Temperatur in °C (>) |
| `VLLM_ALERT_ERR` | `0` | Alarm-Schwelle: neue Fehler je Scrape (>) |
| `VLLM_ALERT_OFFLINE_MIN` | `1` | Minuten offline, bis ein Offline-Alarm ausgelöst wird |

Dashboard:

| Variable | Default | Bedeutung |
|----------|---------|-----------|
| `VLLM_LABEL` | *(leer)* | Untertitel in der Kopfzeile (z. B. Host/Standort) |
| `VLLM_DASH_BIND` | `127.0.0.1` | Bind-Adresse; `0.0.0.0` = netzwerkweit erreichbar |
| `VLLM_AI_URL` | *(leer)* | KI-Auswertung: OpenAI-kompatibler Chat-Endpunkt (`host:port` oder volle `…/v1/chat/completions`-URL; leer = aus). Gilt für **alle** Frontends. |
| `VLLM_AI_MODEL` | *(leer)* | Modellname für die KI-Auswertung (lt. `/v1/models`) |
| `VLLM_AI_KEY` | *(leer)* | Optionaler Bearer-Token (lokales vLLM meist ohne). Wird nie im Browser gespeichert oder ausgeliefert. |
| `VLLM_AI_MAX_TOKENS` | `2000` | Token-Budget der KI-Antwort |
| `VLLM_AI_NO_THINK` | `0` | `1` schaltet die Denk-Phase von Reasoning-Modellen (Qwen3 u. a.) ab (`chat_template_kwargs.enable_thinking=false`) – liefert direkte, saubere Antworten. Empfohlen bei vLLM. |
| `VLLM_REPORT_DIR` | `reports/` | Zielordner für geplante KI-Schicht-Reports |
| `VLLM_REPORT_RANGE` | `28800` | Zeitfenster des Reports in Sekunden (Default 8 h) |
| `VLLM_AUTH_FILE` | `auth.json` (neben der DB) | Speicherort für Benutzer, Rollen und LDAP-Konfiguration (Passwörter PBKDF2-gehasht, 0600, nicht ins Git). Verwaltung im UI unter ⚙ → 👥 *Benutzer & Zugriff*. |
| `VLLM_LDAP_*` | *(leer)* | **Nur Erst-Seed:** `VLLM_LDAP_HOST`/`_DOMAIN`/`_TLS`/`_PORT`/`_PORT_TLS`/`_BASE_DN` befüllen beim allerersten Start die LDAP-Config in `auth.json`; danach wird alles im UI gepflegt. `setup.sh` fragt LDAP nicht mehr ab. |
| `VLLM_PBKDF2_ITER` | `200000` | Iterationen fürs Passwort-Hashing (PBKDF2-HMAC-SHA256) lokaler Nutzer. |
| `VLLM_AUTH_TTL` | `300` | Sekunden, wie lange eine erfolgreiche Basic-Auth-Prüfung (Scraper) server-seitig gecacht wird. |
| `VLLM_AUTH_COOKIE_DAYS` | `7` | Gültigkeit des persistenten Session-Cookies (gleitend verlängert) – kein wiederholtes Login. |
| `VLLM_AUTH_SECRET` | *(auto)* | HMAC-Secret für die Session-Cookies; ohne Angabe wird eins in `.auth_secret` erzeugt/gespeichert. |

**Geplanter KI-Schicht-Report:** `python3 vllm_dashboard.sh report [sekunden]`
erzeugt einen deutschen Betriebs-Report (Kennzahlen + Alarme + KI-Bewertung) und
legt ihn unter `VLLM_REPORT_DIR` ab. `setup.sh` kann dafür einen systemd-Timer
einrichten (Abfrage `OnCalendar`, z. B. `*-*-* 06,14,22:00`).

Die KI-Auswertung wird **ausschließlich server-seitig** über `VLLM_AI_*`
konfiguriert (Env bzw. `setup.sh`) – es gibt keine Konfiguration im Browser.
`GET /api/config` meldet den Frontends nur, *ob* eine KI konfiguriert ist (und
welcher Endpunkt/welches Modell), **nie den Key**. Der Analyse-Request enthält
lediglich den Prompt; Endpunkt, Modell und Key liegen komplett auf dem Server.

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

### Prometheus / Grafana

`GET /metrics` liefert die aktuellen Werte im **Prometheus-Textformat** (Präfix
`vllm_monitor_`, Labels `host`/`port`/`model`), inkl. GPU- und Collector-Status.
Kumulative Werte sind `counter` – Prometheus bildet Raten selbst per `rate()`.
Beispiel-Scrape:

```yaml
scrape_configs:
  - job_name: vllm-monitor
    scheme: https            # bei aktivem TLS; sonst http
    tls_config: { insecure_skip_verify: true }
    static_configs:
      - targets: ["dein-host:8899"]
```

## Als Dienst betreiben (systemd)

**Am einfachsten** über das interaktive `setup.sh` (Menü, keine Parameter):

```bash
./setup.sh
```

Das Menü bietet: **Abhängigkeitsprüfung**, **Installation** (fragt Ziel-IP,
Instanzen, Bind und Port ab, legt beide systemd-**User**-Services an, startet sie
und aktiviert Linger für Autostart nach Reboot) sowie **vollständige
Deinstallation** (Dienste entfernen, optional Datenbank/Einstellungen/Linger).
Zuletzt genutzte Werte werden als Vorgabe gemerkt.

Alternativ von Hand — Beispiel für den Collector:

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

- **Anmeldung ist immer aktiv.** Das Dashboard verlangt beim Aufruf einen Login
  (HTML-Formular). Erststart mit **admin/admin**; das Passwort muss beim ersten
  Login geändert werden. Geschützt sind alle `/api/*` und `/metrics` (nur die
  Seiten-Hülle und `/api/me` sind offen). Session per signiertem, `HttpOnly`-Cookie.
- **Rollen:** *Admin* (Vollzugriff inkl. Benutzer-/Instanz-/LDAP-Verwaltung) und
  *Read-only* (Ansicht + KI-Auswertung, keine Schreib- oder Verwaltungsaktionen –
  server-seitig erzwungen, nicht nur im UI ausgeblendet).
- **Benutzer & LDAP im UI:** Lokale Nutzer (Passwörter PBKDF2-HMAC-SHA256) und
  Active-Directory-Nutzer (einzeln oder per **AD-Gruppe** → Rolle, via LDAP
  Simple Bind + `memberOf`-Suche) werden unter ⚙ → 👥 *Benutzer & Zugriff*
  gepflegt und in `auth.json` (0600, nicht ins Git) gespeichert.
- **Scraper/Automation:** Prometheus u. Ä. können sich per **HTTP Basic Auth**
  mit einem (lokalen oder AD-)Konto an `/metrics` anmelden – parallel zum Cookie.
- **Nur mit HTTPS betreiben** – sonst gehen Zugangsdaten im Klartext übers Netz.
  Bei Bind an `0.0.0.0` zusätzlich per Firewall/Reverse-Proxy absichern.
- Die Tools senden **keine** Metrikdaten nach außen; alles bleibt lokal in der
  SQLite-DB. (Ausnahme: die optionale KI-Auswertung ruft den konfigurierten
  Chat-Endpunkt auf, und die LDAP-Anmeldung spricht mit dem Domain-Controller.)

### HTTPS

Das Dashboard kann direkt TLS sprechen (ohne Reverse-Proxy). Am einfachsten über
`./setup.sh` → Installation → *„HTTPS aktivieren?"* (bzw. Menüpunkt 5 zum
Erzeugen des Zertifikats). Manuell:

```bash
# self-signed Zertifikat für die Adresse erzeugen, unter der das Dashboard läuft
openssl req -x509 -newkey rsa:2048 -nodes -keyout tls_key.pem -out tls_cert.pem \
  -days 3650 -subj "/CN=<dashboard-ip>" \
  -addext "subjectAltName=IP:<dashboard-ip>,IP:127.0.0.1,DNS:localhost"

VLLM_TLS_CERT=tls_cert.pem VLLM_TLS_KEY=tls_key.pem \
  python3 vllm_dashboard.sh 8899 0.0.0.0
```

Bei self-signed Zertifikaten zeigt der Browser einmalig eine Warnung (Ausnahme
bestätigen). HTTPS ist außerdem **Voraussetzung für Browser-Benachrichtigungen**:
diese sind nur in einem *secure context* (HTTPS oder `http://localhost`) erlaubt.
Der TLS-Handshake läuft pro Verbindung im Handler-Thread, damit langlebige
SSE-Verbindungen die Annahme neuer Verbindungen nicht blockieren.
`tls_*.pem` sind per `.gitignore` vom Repo ausgeschlossen.

## Lizenz

[MIT](LICENSE) © 2026 Andreas Bender
