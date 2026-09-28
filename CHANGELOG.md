# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.
Das Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
die Versionierung an [Semantic Versioning](https://semver.org/lang/de/).

## [0.29.0] – 2026-09-28

### Hinzugefügt
- **KI-Verbindung im ⚙-Menü konfigurierbar** (🤖 *KI-Verbindung*, nur Admins).
  Endpunkt, Modell, API-Key, Token-Budget, Zeitgrenze und „Denk-Phase
  abschalten" wurden bisher ausschließlich über die Env-Variablen `VLLM_AI_*`
  gesetzt – wer kein systemd-Unit editieren wollte, konnte die 🔍-Auswertungen
  und den 📋 KI-Report gar nicht in Betrieb nehmen. Die Werte liegen jetzt in
  `settings.json` (Abschnitt `ai`, 0600, gitignored) und überschreiben die Env,
  die nur noch die Vorbelegung ist. Der Key wird – wie bei den Ziel-Keys – **nie**
  an den Browser ausgeliefert (`key_set`); ein fehlendes Feld beim Speichern
  heißt „unverändert", `""` heißt „löschen".
- **„Verbindung testen"** im selben Dialog: holt erst die Modellliste des
  Endpunkts (füllt die Vorschlagsliste – gegen Tippfehler im Modellnamen) und
  schickt dann eine Mini-Anfrage, zusammen mit Antwortzeit und Klartextfehler
  (z. B. `HTTP 401`). Prüft die eingetippten, noch nicht gespeicherten Werte.
  Die Endpunkt-Vorschläge kommen aus den überwachten vLLM-/LM-Studio-Instanzen.
- **Eigenes ✕ für „Vollbild schließen".** In der maximierten Kachel bedeutete das
  ✕ bisher *Kachel ausblenden* – naheliegend war aber „Fenster zu". Maximiert
  trägt der Ausblenden-Knopf jetzt einen **🗑 Mülleimer**, daneben schließt ein
  **✕** nur das Vollbild (wie Esc). Unmaximiert bleibt alles wie gehabt.

### Geändert
- `POST /api/analyze` nimmt **keine** Verbindungsdaten mehr aus dem Request-Body
  (Relikt der früheren browser-seitigen Konfiguration). Endpunkt, Modell und Key
  kommen ausschließlich aus der Server-Config; sonst könnte jeder angemeldete
  Nutzer – auch read-only – den Server als Proxy auf beliebige URLs benutzen.
  Ungespeicherte Werte prüft nur noch das Admin-Endpunkt-Paar
  `POST /api/ai` / `POST /api/ai/test`.
- `settings.json` wird mit **0600** geschrieben (enthält jetzt den KI-Key).

## [0.28.0] – 2026-08-26

### Hinzugefügt
- **Kachel „Abgeschlossene Requests/h"** (`req_ph`) und ein eigener KPI-Kopf für
  vLLM-Omni: *aktiv · Requests/h · abgeschlossen · Dauer p95 · Fehler/s*.
  Bild-/Video-/Audio-Modelle geben keine Tokens aus – „gen tok/s 0" und
  „0 generiert" waren dort korrekt, aber nutzlos. Gezählt wird jetzt, was solche
  Modelle wirklich leisten. Neues Feld `req_total` (kumulierte Abschlüsse) als
  Mengenzähler analog zu den Tokens.
- Instanzen-Tabelle: Spalten, die ein Servertyp gar nicht kennt, stehen als
  kursives **„n. v."** mit Erklärung am ⓘ der Typ-Spalte statt als Strich, der
  wie „gerade nicht gemessen" aussieht.

### Behoben
- **Junge Instanzen hatten in langen Zeiträumen gar keine Werte.** Ohne
  Messpunkt vor dem Fensterbeginn fehlte der Bezugspunkt für jedes Delta – und
  bei „seit Beginn" (ein Bucket ≈ 54 min) fiel die gesamte junge Reihe in ein
  bis zwei Buckets. Ergebnis: keine Raten, keine Perzentile, eine leere Kachel
  und eine KPI-Karte voller Striche, obwohl Daten vorhanden waren. `build_series()`
  nimmt für Modelle ohne Anker jetzt den ältesten Rohwert des Fensters als
  Bezugspunkt. Gemessen an FLUX (35 min alt): „seit Beginn" vorher alles leer,
  jetzt 7,2 Requests/h und Dauer p50 5,0 s / p95 9,5 s.
- **KV-Cache-Kachel zeichnete eine 0-%-Linie für Server ohne KV-Cache.** Ein
  fehlender Wert wurde als 0 durchgereicht – vLLM-Omni, Ollama und STT
  behaupteten damit eine Messung, die es nicht gibt. Fehlt der Wert, bleibt die
  Kurve jetzt leer (Gegenprobe: Qwen 122 Werte, FLUX/GPU/STT 0).

## [0.27.1] – 2026-08-26

### Behoben
- **Typwechsel eines Ziels löschte dessen Messreihen.** Beim Bearbeiten legte
  der Client den geänderten Eintrag neu an und schickte anschließend ein
  `DELETE /api/targets` auf die alte id – und `del_target()` räumt neben dem
  Ziel auch `config` und `samples` des Ports ab. Da die id den Typ enthält,
  reichte schon das Umstellen von „vLLM" auf „vLLM-Omni", um die Historie
  desselben, weiterhin überwachten Servers zu verlieren (real passiert an Port
  9079). Das Umbenennen läuft jetzt vollständig in `add_target()`: `prev_id`
  entfernt den alten Eintrag mitsamt Key-Übernahme, der Client löscht nicht
  mehr. Zusätzlich ordnet `add_target()` über **Host:Port** zu – ein Port trägt
  genau einen Server, ein Typwechsel ersetzt den Eintrag also, statt einen
  zweiten mit derselben Adresse anzulegen (der doppelt gescrapt würde).
- **„Prefix-Cache: aus" war eine Behauptung, keine Messung.** Die Spalte zeigte
  „aus", sobald der Wert fehlte – also auch für STT-, GPU- und vLLM-Omni-Zeilen,
  die diese Angabe gar nicht liefern. Unbekannt wird jetzt als „–" dargestellt.
- vLLM-Omni-Zeilen tragen in der Typ-Spalte ein „ⓘ" mit dem Grund für die leeren
  Engine-Spalten (der Server veröffentlicht weder `cache_config_info` noch eine
  `max_model_len`, geprüft an allen 38 Metriknamen und an `/v1/models`).

## [0.27.0] – 2026-08-26

### Hinzugefügt
- **vLLM-Omni wird unterstützt.** Omni-Server (Bild-/Video-/Omni-Modelle)
  veröffentlichen ihre Kennzahlen unter dem Präfix `vllm_omni:` und mit zwei
  abweichenden Namen (`requests_success_total`, `e2e_request_latency_s`).
  Der Parser suchte auf `vllm:` – deshalb blieben alle Messwerte solcher
  Instanzen leer (nachgeprüft an Port 9079: `samples`-Zeilen ohne einen
  einzigen Wert). `normalize_metric()` bildet die Namen jetzt beim Parsen auf
  die vLLM-Schreibweise ab, sodass `GAUGE_COUNTER`/`HISTOGRAMS`/`extract()`
  unverändert greifen. Erfasst werden damit laufende/wartende Requests,
  Prompt-/Generation-Tokens, `requests_success` (inkl. `finished_reason`) und
  die E2E-Latenz samt Histogramm. KV-Cache, Prefix-Cache, TTFT, ITL und
  `cache_config_info` gibt es bei Omni nicht – diese Spalten bleiben leer.
- Neuer Ziel-Typ **„vLLM-Omni"** im ⚙-Dialog *Instanzen verwalten*
  (`_TARGET_KINDS`, `load_extra_targets()`). Die Art wird zusätzlich **am
  Präfix erkannt**, nicht am Eintrag: ein als `vllm` angelegtes Ziel wird
  automatisch als `vllm-omni` geführt, sobald der Server Omni-Metriken liefert
  (bestehende Einträge müssen also nicht angefasst werden).
- **✕ für veraltete Einträge** in der Instanzen-Tabelle. Bisher hatten nur
  Zeilen, die zu einem Eintrag in `targets.json` gehören, einen Löschknopf –
  Altlasten wie ein längst abgeschaltetes Ollama-Modell ließen sich nicht
  entfernen. Neu: `DELETE /api/instances?id=host:port:modell` (`del_instance()`)
  entfernt **nur die Registrierung** in der `config`-Tabelle; die Messreihen
  bleiben erhalten, das Modell bleibt also in den Diagrammen sichtbar (👁
  blendet es dort aus). Aktive Einträge werden abgelehnt – sie wären beim
  nächsten Scrape ohnehin wieder da.
  - Welches ✕ eine Zeile bekommt, entscheidet `port_live`: Liefert der Port
    weiter Daten, ist ein veralteter Eintrag ein **ausgetauschtes Modell** und
    bekommt das Eintrags-✕ – sonst würde das bisherige Ziel-✕ die ganze
    Instanz mitsamt dem laufenden Modell löschen.
  - `build_config()` ordnet Instanzen jetzt über **Host:Port** statt über
    (Art, Host, Port) einem Ziel zu und liefert dessen `target_id` mit. Sonst
    verlöre eine als `vllm` eingetragene, als `vllm-omni` erkannte Instanz ihr
    Ziel-✕.
- `durTxt()` rechnet ab zwei Tagen in Tagen („vor 13,5 Tagen" statt „vor 324 h").

## [0.26.0] – 2026-08-25

### Hinzugefügt
- **Drittes Diagramm unter „Effizienz & Kapazität": „Generierte Tokens pro Tag
  – seit Aufzeichnungsbeginn (kumuliert)".** Liniendiagramm der aufsummierten
  Tagessummen (Gesamtlinie als Fläche, je Modell eine eigene Linie), gespeist
  aus denselben Daten wie das Tagesbalken-Diagramm (`/api/tokens` ohne
  Zeitraum) – keine zusätzliche Serverlast.
  - **Lückenlose Kalendertage:** Tage ohne Messung fehlen in `days[]` und
    hätten die Kategorie-Achse gestaucht, also die Kurvenform verfälscht;
    `cumTokenSeries()` füllt sie mit dem fortgeschriebenen Stand auf.
  - **Umschalter „log. Achse":** exponentielles Wachstum wird auf der
    logarithmischen y-Achse zur Geraden. Beschriftet werden nur 1er- und
    3er-Dekaden, sonst überlagern sich die Zwischenschritte.
  - **Wachstumshinweis in der Überschrift:** `fitInfo()` legt eine Regression
    über `ln(y)` und eine lineare Regression über dieselben Punkte und nennt
    das besser passende Modell samt R² – exponentiell mit Wachstum pro Tag und
    Verdopplungszeit, sonst „eher linear" mit Tokens/Tag. Der erste
    Aufzeichnungstag bleibt außen vor: Er ist angebrochen und im Log-Raum ein
    massiver Ausreißer (real gemessen R² 0,41 mit, 0,98 ohne ihn).
  - Der Zustand des Schalters liegt in `vllm_cumtok_log` und wandert damit über
    `prefs.json` mit dem Benutzer.

## [0.25.1] – 2026-08-10

### Behoben
- **Lesbare Zahlen in allen Diagrammen.** Die Zeitreihen-Kacheln hatten keine
  Tooltip-Callbacks; bei einer linearen X-Achse zeigte Chart.js deshalb den
  rohen Zeitstempel in Millisekunden („1.770.844.123.000") und den Y-Wert
  ungerundet („96.68999999999998"). Der Tooltip nennt jetzt den vollständigen
  Zeitpunkt („Mo., 10.08.2026, 02:59:49 Uhr") und den Wert in deutscher
  Schreibweise samt Einheit („GPU 0: 96,7 GB"); `null`-Punkte werden
  ausgefiltert. Vergleichslinien führen zusätzlich ihren echten Zeitpunkt mit,
  da sie aufs aktuelle Fenster projiziert sind.
- Y-Achsen kürzen große Werte (`1,4 Mio` statt `1400000`), Balken-Tooltips
  zeigen weiterhin die exakte Zahl. Jede Kachel trägt dafür eine `unit`;
  `num()` und `fmtBig()` nutzen dieselben Formatierer, damit KPI-Zeile und
  Diagramme gleich schreiben.

## [0.25.0] – 2026-08-10

### Geändert
- **Gleitendes Fenster für Signale, die nur unter Last existieren**
  (Prefix-Trefferquote, alle Latenz-Perzentile): Sie werden nicht mehr aus dem
  Delta zum vorherigen Chart-Bucket berechnet (~76 s – dort meist undefiniert,
  weil die Server im Leerlauf sind), sondern gegen den Messpunkt ein volles
  Fenster zurück (`_smooth_window()`: ~1/34 des Zeitraums, mindestens vier
  Buckets, höchstens eine Stunde → 30 min bei 17 h). Aus 34 Fragmenten à 1,8
  Punkten werden so 9 Verläufe à 47 Punkten. Die Fensterlänge liefert
  `/api/series` als `win`; betroffene Kacheln tragen sie im Kopf
  („· gleitend 35 min").
- **Messlücken werden nicht mehr überbrückt.** `spanGaps` ist jetzt ein
  Zeitlimit (2,5 × Bucket) statt `true` – vorher zog Chart.js über stundenlange
  Leerlaufphasen eine Gerade und erfand damit einen nie gemessenen Verlauf.
  `datasets()`/`compareDatasets()` behalten die `null`-Punkte, statt sie
  herauszufiltern.
- **Darstellungsmodus je Serie** (`renderMode()`): Maßstab ist nicht die Anzahl
  der Messwerte, sondern ob sie zusammenhängen – Ø-Länge einer zusammenhängenden
  Strecke ≥ 5 Punkte → Linie, darunter → Streudiagramm mit sichtbaren Punkten.
  Dichte Serien (Tokens/s, KV-Cache, GPU) bleiben unverändert.

## [0.24.0] – 2026-07-30

### Hinzugefügt
- **Kachel „Token-Zähler"** (analog zur GPU-Verbrauch-Kachel): zeigt die
  **generierten Tokens je Kalendertag** im gewählten Zeitraum als Balkendiagramm
  mit Ø-Linie und Werten über den Balken (nur maximiert). Die Vorschau zeigt
  schlicht die **Gesamtsumme** als große Kennzahl; der Kopf ergänzt Ø/Tag und die
  Prompt-Tokens. Eigene Chart-Instanz (`tokTileChart`), kein 🔍-Analysepanel.
  Backend: `build_tokens(range_s|start,end)` liefert das auf das Fenster
  gefilterte Ergebnis inkl. Summen/Ø; `GET /api/tokens?range=…|from=…&to=…`
  (ohne Parameter weiterhin alle Tage seit Aufzeichnung für den bestehenden
  Effizienz-Chart).

## [0.22.0] – 2026-07-29

### Hinzugefügt
- **Zeitraum „seit Beginn"** – neue Option im Zeitraum-Menü (`range=all`).
  `_range_from()` löst sie zentral über `db_span()` auf (jetzt − ältester
  `ts`, weiter auf die 30-Tage-Aufbewahrung gedeckelt) und liefert die
  tatsächliche Spanne in der Antwort zurück, sodass Vergleichszeitraum und
  Beschriftung stimmen. Gilt für `/api/series`, `/api/stream`,
  `/api/annotations` und `/api/energy`.
- **Kachel „GPU-Verbrauch"** – neuer Endpunkt `GET /api/energy`
  (`build_energy()`): integriert die DCGM-Leistungswerte über die Zeit
  (Trapezregel, auf den **Rohdaten**, nicht auf den verdichteten
  Diagrammpunkten) zu **kWh je Kalendertag**, an lokalen Tagesgrenzen
  aufgeteilt (sommerzeitfest) und über alle GPUs summiert. Messlücken über dem
  4-fachen des Median-Scrape-Intervalls werden übersprungen statt
  hochgerechnet und als `coverage` ausgewiesen.
  Die Vorschaukachel zeigt nur den Tagesdurchschnitt im gewählten Zeitraum,
  die maximierte Ansicht das Balkendiagramm mit Werten über den Balken,
  gestrichelter Ø-Linie und Gesamtverbrauch/Messdauer.
- **Beliebig viele AD-Gruppen freigeben** – neue Tabelle *Active-Directory-
  Gruppen (Freigabe)* im Dialog *Benutzer & Zugriff*, gespeichert in
  `auth.json.ad_groups` (`{name, role}`, CN oder vollständiger DN, Abgleich
  gegen `memberOf`). Rangfolge in `resolve_ad_role()`: Einzelfreigabe eines
  Benutzers > freigegebene Gruppen (Admin schlägt Read-only) > die bisherigen
  Einzelfelder `group_admin`/`group_readonly` > Standardrolle. Verwaltung über
  `POST/DELETE /api/users` mit `kind: "adgroup"`; die Verzeichnissuche gibt
  eine Gruppe per „→ Admin"/„→ Read-only" direkt frei.

### Geändert
- **Anmeldung als echtes Formular** – Login und Passwortwechsel sind jetzt
  `<form>`-Elemente mit `name`-Attributen, die per POST abgeschickt werden und
  serverseitig mit **303** auf `/` zurückleiten (Fehler über
  `?login=failed|expired` bzw. `?pwerr=…`). Erst durch diese echte Navigation
  bieten Browser-Passwortmanager das Speichern der Zugangsdaten an und füllen
  sie später aus; der bisherige JSON-Pfad der Endpunkte bleibt erhalten.
  `_read_body()` versteht zusätzlich `application/x-www-form-urlencoded`.
- **Kachel-Layout** – jede Kachel ist eine Flex-Spalte, das Diagramm liegt in
  `.chartwrap` und füllt sie bis zur Unterkante. Dadurch liegen die X-Achsen
  aller Kacheln einer Reihe auf einer Linie, unabhängig davon, über wie viele
  Zeilen die Überschrift läuft; maximierte Kacheln passen ohne Scrollen ins
  Fenster und nutzen die volle Höhe.
- **Achsenbeschriftung** – bei Fenstern über 36 h zeigt die X-Achse Datum und
  Uhrzeit, über 7 Tagen nur noch das Datum (vorher immer nur die Uhrzeit).

### Behoben
- **Trefferliste der Verzeichnissuche** – die Schaltflächen nutzten `.cbtn`
  (fest 22 px breit); der Text lief heraus und erzeugte waagerechte und
  senkrechte Scrollbalken, der Treffer war abgeschnitten. Neue Klasse `.tbtn`
  für Textschaltflächen, Ergebnisbereich höher, lange Namen werden gekürzt.

## [0.21.0] – 2026-07-28

### Hinzugefügt
- **API-Keys für geschützte LLM-Server** – überall dort, wo das Toolkit LLMs
  anspricht, kann jetzt ein Key mitgegeben werden (`Authorization: Bearer …`;
  Keys mit eigenem Schema – `Bearer …`/`Basic …`/`Token …` – werden unverändert
  übernommen):
  - **Dashboard:** neues Passwortfeld **API-Key** je Instanz im ⚙-Dialog
    *Instanzen verwalten*, dazu die Spalte „Key" (🔑/–) in der Übersicht. Beim
    Bearbeiten bedeutet ein leeres Feld *unverändert*, das Häkchen *Key
    entfernen* löscht ihn; bei geänderter Host/Port-Kombination wandert der Key
    mit (`prev_id`). `GET /api/targets` liefert **nie** den Key, nur
    `key_set: true`. `targets.json` wird jetzt mit **0600** geschrieben (eine
    bestehende Datei wird beim Start einmalig abgesichert).
  - **Collector:** neues `auth_headers()`; der Key wird an alle Abrufe und
    Probes durchgereicht (vLLM `/metrics`, `/v1/models`, `/version`, Ollama,
    LM Studio, STT, DCGM). Reihenfolge: Instanz-Key aus `targets.json` >
    globaler `VLLM_API_KEY`.
  - **`monitor.sh` / `scan_for_llms.sh`:** Key per `--key=…`, `VLLM_API_KEY`
    oder interaktiv im Menü (`monitor.sh` → *8*, `scan_for_llms.sh` → *4*;
    Eingabe verborgen via `getpass`, `-` löscht), gemerkt in
    `~/.monitor_api_key` bzw. `~/.scan_for_llms_api_key` (0600).
    Bei `401`/`403` weisen beide Tools ausdrücklich auf den fehlenden bzw.
    abgelehnten Key hin; `scan_for_llms.sh` meldet solche Ports als
    *„LLM-API (API-Key erforderlich)"* statt als anonymen HTTP-Dienst.

## [0.20.2] – 2026-07-23

### Behoben
- **Speichern der Ansicht robuster:** Konnte `applyLoadedPrefs()` beim Anmelden
  eine Exception werfen, wurde `_prefsReady=true` nie erreicht – der Client
  spiegelte danach **gar keine** Änderungen mehr zum Server (Reihenfolge etc.
  ging auf anderen Rechnern verloren). `_prefsReady` wird jetzt garantiert
  gesetzt (`applyLoadedPrefs` in try/catch). Zusätzlich wird bei jeder Änderung
  praktisch **sofort** gespeichert (Entprellung 400 → 120 ms), und ausstehende
  Änderungen werden bei `pagehide`/`visibilitychange`/Abmelden per
  `navigator.sendBeacon`/`keepalive` zuverlässig nachgesichert.

## [0.20.1] – 2026-07-23

### Behoben
- **Diagramm-/Bereichs-Reihenfolge und Einklapp-Zustände wurden auf einem
  anderen Rechner nicht geladen:** Diese Einstellungen werden nur einmalig beim
  Seitenaufbau gesetzt (`buildGrid`, Sektions-Sortierung, Collapse-IIFEs) –
  zu diesem Zeitpunkt sind die Cookies auf einem frischen Rechner noch leer.
  `applyLoadedPrefs()` ordnet die vorhandenen DOM-Karten jetzt nach dem Laden
  der Server-Prefs erneut um (`reorderDom` für `#charts` und `#sections`) und
  wendet die Einklapp-Zustände neu an (`applyCollapse` für KPI/Diagramme/
  Instanzen/Alarm/Effizienz). Die KPI-Reihenfolge war bereits korrekt, da
  `renderKPIs` bei jedem Refresh neu rendert.

## [0.20.0] – 2026-07-23

### Hinzugefügt
- **Ansichts-Einstellungen serverseitig pro Benutzer:** Theme, Dichte, Layout
  (Kachel-Reihenfolge, ein-/ausgeklappte Bereiche), ausgeblendete Modelle,
  Modell-Farben, gewählter Zeitraum/Vergleich, Host-Filter und der
  Benachrichtigungs-Schalter werden jetzt **pro Benutzer auf dem Server**
  gespeichert (`prefs.json`, `VLLM_PREFS_FILE`, 0600, gitignored). Ein
  Rechnerwechsel zeigt damit dieselbe Ansicht wie zuvor. Endpunkte:
  `GET/POST /api/prefs` (für jeden angemeldeten Nutzer, auch read-only – es sind
  persönliche Einstellungen). Das Frontend spiegelt die bisher nur als Cookie
  gehaltenen `vllm_*`-Werte transparent an den Server (gebündelt, entprellt) und
  lädt sie beim Anmelden zurück; die Cookies bleiben als lokaler Cache. Beim
  ersten Anmelden mit noch leerem Server-Profil wird die vorhandene lokale
  Ansicht **einmalig übernommen**.

## [0.19.1] – 2026-07-22

### Behoben
- **Zertifikat-Download ohne Login:** `GET /api/cert` ist jetzt eine öffentliche
  Route (wie `/` und `/api/me`). Vorher war der Download auth-geschützt – ein
  Henne-Ei-Problem, da man das self-signed Zertifikat installieren muss, *um*
  die HTTPS-Warnung loszuwerden, aber zum Login schon eine vertraute Verbindung
  bräuchte. Das ausgelieferte Server-Zertifikat ist ohnehin öffentlich.
- **„Nicht sicher" trotz importiertem Zertifikat:** `setup.sh` (`gen_cert`)
  nimmt jetzt **alle lokalen IPv4-Adressen des Hosts** und den Hostnamen in den
  **SAN** auf (nicht mehr nur den CN + `127.0.0.1`). Moderne Browser
  (Chrome/Edge) prüfen ausschließlich den SAN; fehlte die tatsächlich
  aufgerufene IP dort, blieb die Verbindung trotz Import als „nicht sicher"
  markiert (`ERR_CERT_COMMON_NAME_INVALID`).

## [0.19.0] – 2026-07-17

### Hinzugefügt
- **LM-Studio-Unterstützung:** LM Studio kann jetzt als Instanz überwacht werden
  (⚙ → 🖧 *Instanzen verwalten* → Typ **„LM Studio"**, Standardport **1234**;
  im `setup.sh` eigener Prompt). Der Collector (`scrape_lmstudio`) liest
  `/api/v0/models` für das geladene Modell, die Kontextlänge und den
  Online-Status (Fallback auf `/v1/models`). Eine optionale **Durchsatz-Probe**
  (`/api/v0/chat/completions`) liefert Tokens/s, TTFT und kumulierte Tokens für
  KPI-Karten und Diagramme – wie bei Ollama läuft sie **nur gegen bereits
  geladene Modelle** (kein Kalt-Load, kein Flackern) und mit begrenztem Timeout.
  Konfiguration: `VLLM_LMSTUDIO_TARGETS` (`host:port:label`),
  `VLLM_LMSTUDIO_PROBE`, `VLLM_LMSTUDIO_PROMPT`, `VLLM_LMSTUDIO_MAX_TOKENS`.

## [0.18.6] – 2026-07-16

### Behoben
- **Gelöschte Instanz blieb sichtbar:** Beim Löschen einer Instanz (aus der
  Instanzen-Tabelle bzw. `targets.json`) werden jetzt auch die zugehörigen
  **DB-Reste** (config- und sample-Zeilen für den Host:Port) entfernt – vorher
  blieb die Instanz aus der `config`-Tabelle als „offline" stehen. Das Frontend
  aktualisiert nach dem Löschen Instanzen **und** KPIs/Diagramme sofort.

## [0.18.5] – 2026-07-16

### Geändert
- **Einheitliche Symbole:** Der Löschen-Button in der Instanzen-Tabelle und das
  Schließen-Symbol der Diagramm-Karten sind jetzt ein **`✕`** – konsistent zur
  Alarm-Historie (vorher 🗑 bzw. das dünnere `×`).
- **Überschrift „Diagramme"** bündig wie die übrigen Container (der zusätzliche
  Flex-Abstand vor dem Titel wurde entfernt).

## [0.18.4] – 2026-07-16

### Neu
- **KPI-Karten zeigen „generiert"** – die kumulierten Gesamt-Tokens je Instanz
  (aus dem rohen Counter), sodass auch bei Idle (gen tok/s = 0) sichtbar ist,
  wie viel die Instanz bereits erzeugt hat.

### Geändert
- **Mausrad-Zoom nur noch bei maximierten Karten.** In der normalen
  Diagramm-Übersicht sind Zoom und Verschieben deaktiviert (kein versehentliches
  Zoomen mehr); erst beim Maximieren (⤢) werden Mausrad-Zoom/Pinch/Verschieben
  aktiv. Der Button „Zoom ⟲" ist entsprechend nur bei einer maximierten Karte
  klickbar; beim Verkleinern wird der Zoom zurückgesetzt.

## [0.18.3] – 2026-07-16

### Neu
- **Instanzen-Tabelle: Aktionsspalte** je Instanz – **👁 Ein-/Ausblenden**
  (blendet das Modell in „Modelle & GPU", Diagrammen und Legende aus/ein;
  Anzeige-Einstellung im Cookie) und **🗑 Löschen** (entfernt die Instanz aus der
  Überwachung, `targets.json`). Das Löschsymbol erscheint nur bei über die
  Oberfläche verwaltbaren Instanzen (`build_config` liefert dazu `managed`) und
  ist Admins vorbehalten (Löschschutz der letzten vLLM-Instanz bleibt).

## [0.18.2] – 2026-07-16

### Neu
- **Instanzen-Tabelle sortierbar** – Klick auf jeden Spaltenkopf (Status, Typ,
  Instanz, Modell, Version, Kapazität, max_model_len, gpu_mem, Prefix-Cache)
  sortiert; erneuter Klick dreht die Richtung, Pfeil-Indikator (wie bei der
  Alarm-Historie).

### Behoben
- Die Token-Diagramme in „Effizienz & Kapazität" füllen ihren **Rahmen jetzt
  bündig** (globale Canvas-Höhendeckelung `--card-h` wird für diese Diagramme
  aufgehoben) – keine Leerfläche mehr.
- **Einklappen** der Karte „Effizienz & Kapazität" versteckt jetzt auch die
  Token-Diagramme (vorher blieben sie sichtbar).

## [0.18.1] – 2026-07-16

### Geändert
- Die beiden Token-Diagramme in „Effizienz & Kapazität" sitzen jetzt in einem
  **Rahmen** (wie die Karten); die Überschrift steht darüber und das Diagramm
  **füllt den Rahmen** in fester Höhe aus.

## [0.18.0] – 2026-07-16

### Neu
- **Token-Auswertung als Diagramme** in „Effizienz & Kapazität" (untereinander):
  (a) **generierte Tokens im gewählten Zeitraum je Modell** (aus den Serien
  integriert) und (b) **generierte Tokens pro Tag seit Aufzeichnungsbeginn**
  (gestapelt je Modell, aus den kumulativen Countern als Tages-Deltas mit
  Reset-Behandlung, 60 s server-seitig gecacht). Neuer Endpunkt
  `GET /api/tokens`.
- **Benachrichtigungen als Umschalter:** Die 🔔/🔕-Schaltfläche aktiviert **und
  deaktiviert** Browser-Benachrichtigungen; Zustand im Cookie (`vllm_notif`).
- **Alarm-Historie verwaltbar (nur Admins):** einzelne Einträge löschen (✕) und
  gesamte Historie leeren (🗑) – im Frontend rollenabhängig sichtbar, server-
  seitig erzwungen (`DELETE /api/alerts[?id=…]`). Zusätzlich sind die **Spalten
  sortierbar** (Klick auf den Kopf, Pfeil-Indikator).

### Geändert
- **Collector-Status** wird im Header nur noch **bei Problemen** angezeigt (rote
  Warnung „Collector inaktiv …") statt als Dauer-Pille – die Aktualität zeigt der
  Refresh-Zähler rechts.

### Behoben / Robustheit
- **Kein Rot/Grün-Flackern mehr** durch langsame Ollama-Hosts: Die Generierungs-
  Probe läuft nur noch gegen **bereits geladene** Modelle (kein selbst ausgelöster
  Kalt-Load eines großen Modells, der den ganzen Scrape-Loop blockierte), mit
  begrenztem Timeout (`VLLM_OLLAMA_PROBE_TIMEOUT`, 15 s). Erreichbarkeits-/Meta-
  Aufrufe für Ollama/STT nutzen einen kurzen Timeout (`VLLM_OLLAMA_TIMEOUT`, 3 s),
  damit ein toter Host den Sammler nicht ausbremst.
- **Offline-Entprellung** (`VLLM_OFFLINE_GRACE`, 60 s): Eine Instanz wird erst nach
  anhaltender Nichterreichbarkeit als offline markiert – kurze Netz-/Lastspitzen
  führen nicht mehr zu sofortigem „offline".

## [0.17.0] – 2026-07-16

### Neu
- **Benutzerverwaltung & Rollen (Login immer aktiv):** Alle Konten, Rollen und die
  LDAP-Konfiguration liegen in **`auth.json`** (`VLLM_AUTH_FILE`, `0600`, nicht ins
  Git). Erststart mit **admin/admin**, Passwortwechsel beim ersten Login erzwungen.
  Zwei Rollen – **Admin** (Vollzugriff + Verwaltung) und **Read-only** (Ansicht +
  KI-Auswertung, alle Schreib-/Verwaltungsaktionen serverseitig 403). Lokale
  Passwörter **PBKDF2-HMAC-SHA256** (`VLLM_PBKDF2_ITER`). Anmeldung über ein
  **HTML-Login-Formular** (`/api/login`, `/api/logout`, `/api/password`, `/api/me`);
  Session-Cookie trägt Benutzer+Rolle. Basic-Auth bleibt für Scraper (Prometheus)
  gültig. Verwaltung im UI unter ⚙ → 👥 *Benutzer & Zugriff*
  (`GET/POST/DELETE /api/users`).
- **LDAP/AD im UI konfigurierbar:** Host, Domäne, TLS, Basis-DN, Admin-/Read-only-
  **Gruppe** (via LDAP **`memberOf`-Suche**) und Standardrolle; zusätzlich
  **Verzeichnissuche** nach AD-Benutzern/-Gruppen und ein Verbindungstest
  (`POST /api/ldap`, `/api/ldap/test`, `/api/ldap/search`). Rolle: expliziter
  AD-Nutzer > Gruppen-Mapping > Standardrolle. Die `VLLM_LDAP_*`-Env dienen nur noch
  als **Erst-Seed**; **`setup.sh` fragt LDAP nicht mehr ab**.
- **vLLM-Instanzen im UI verwaltbar:** die per Unit definierten Instanzen werden
  beim ersten Start in `targets.json` übernommen und sind dann bearbeit-, pausier-
  und löschbar (✎); die **letzte** vLLM-Instanz bleibt geschützt.
- **Unerreichbare Instanzen sichtbar:** eingetragene Ziele erscheinen jetzt auch
  offline in der Instanzen-Tabelle („nicht erreichbar"), statt zu fehlen.
- **Alarm-Schwellwerte im UI editierbar** (⚙ → 🔔 Schwellwerte, nur Admins):
  GPU-Temperatur, KV-Cache-%, Fehler/Scrape, Offline-Minuten – persistent in
  `settings.json`, vom Collector bei jedem Scrape neu gelesen (ohne Neustart).
  `POST /api/thresholds`.
- **Freier Zeitraum (Von/Bis mit Datum & Uhrzeit):** neue Option
  „benutzerdefiniert…" im Zeitraum-Pulldown; `/api/series`/`/api/annotations`
  akzeptieren zusätzlich `from`/`to`.

### Geändert
- **UI heißt jetzt „KI Monitor"** (Titelzeile, Browser-Tab, Login). Die
  Host-Auswahl sitzt direkt hinter dem Titel (Default „Alle Hosts", im Cookie
  gespeichert); die feste Host-IP in der Titelzeile entfällt.
- **Icons vereinheitlicht** (Outline-SVG, hell/dunkel via `currentColor`):
  Zahnrad, Abmelden und Hell-/Dunkel-Umschalter (Mond/Sonne); „Neu laden" größer.

## [0.16.1] – 2026-07-13

### Behoben
- **Login „klebt" jetzt:** Nach erfolgreicher LDAP-Anmeldung setzt der Server ein
  signiertes, persistentes **Session-Cookie** (`vllm_auth`, HMAC-signiert,
  `HttpOnly`, `SameSite=Lax`, `Secure` bei HTTPS; Default 7 Tage, gleitend
  verlängert). Damit entfällt das wiederholte Eintippen der Zugangsdaten (auch
  nach Browser-Neustart). Neu: `VLLM_AUTH_COOKIE_DAYS`, `VLLM_AUTH_SECRET`
  (sonst automatisch in `.auth_secret` persistiert).

## [0.16.0] – 2026-07-13

### Neu
- **LDAP-/AD-Authentifizierung** (optional): HTTP Basic-Auth → LDAP Simple Bind
  gegen den Domain-Controller (nur Standardbibliothek, BER über Socket – kein
  `ldap3`). Schützt Seite, alle `/api/*` und `/metrics`; Login als
  `benutzer@domäne`, leere Passwörter werden abgelehnt, erfolgreiche Prüfungen
  werden `VLLM_AUTH_TTL` s gecacht. Aktiv über `VLLM_LDAP_HOST`/`VLLM_LDAP_DOMAIN`
  (weitere: `VLLM_LDAP_TLS/PORT/PORT_TLS/ALLOW`, `VLLM_AUTH_REALM`). `setup.sh`
  fragt DC + Domäne ab. Nur mit HTTPS betreiben.
- **Instanzen im UI verwalten:** zusätzliche vLLM-/Ollama-/STT-/DCGM-Ziele über
  das ⚙-Menü hinzufügen, pausieren oder entfernen – persistent in `targets.json`
  (`VLLM_TARGETS_FILE`), vom Collector bei jedem Scrape neu geladen; ohne
  Unit-Editieren. API `GET/POST/DELETE /api/targets` (auth-geschützt).

## [0.15.1] – 2026-07-12

### Geändert
- Toolbar aufgeräumt: **„Notiz"** in das ⚙-Menü verschoben; **„Neu laden"** ist
  jetzt ein **⟳-Symbol** und sitzt zwischen dem 🔒-Sicherheits-Button und dem
  ⚙-Menü.

## [0.15.0] – 2026-07-12

### Neu
- **Prometheus-Exporter:** `GET /metrics` liefert die aktuellen Werte im
  Prometheus-Textformat (Präfix `vllm_monitor_`, Labels `host`/`port`/`model`) –
  Gauges, kumulative Counter (rate-fähig), GPU- und Collector-Status. Additiv zur
  SQLite-Pipeline, stdlib-only. Ein Link **📡 Prometheus /metrics** im ⚙-Menü
  macht den Endpunkt auffindbar.
- **Zeitraum „heute"** im Zeitraum-Pulldown (direkt hinter „24 h", neuer
  Default): dynamisch seit lokaler Mitternacht.

### Behoben
- Maximierte Diagramm-Karte: Canvas-Höhe wird jetzt aus den echten Maßen
  berechnet (statt fester CSS-Höhe), sodass die untere Achsenbeschriftung ohne
  Scrollen sichtbar bleibt – unabhängig von der Höhe der (sticky) Titelleiste.

## [0.14.1] – 2026-07-12

### Geändert
- `setup.sh`: Abfrage der vLLM-Instanzen weist jetzt auf das Host-Präfix hin
  (`[host:]port[:label]`), sodass mehrere Hosts direkt beim Setup eintragbar sind.

## [0.14.0] – 2026-07-12

### Neu
- **Zeitachsen-Annotationen** (Deploy/Restart …): senkrechte Linien mit Label in
  allen Diagrammen. API `GET/POST/DELETE /api/annotations`, Toolbar-Button
  **🏷 Notiz**, Klick auf eine Linie löscht sie, sowie CLI
  `vllm_dashboard.sh annotate "Label" [ts]` für Deploy-Skripte.
- **Mehrere Hosts/Cluster:** `VLLM_TARGETS` akzeptiert jetzt `[host:]port[:label]`
  (rückwärtskompatibel). Neuer **Host-Filter** im Dashboard (erscheint ab zwei
  Hosts) filtert Instanzen, KPI-Karten und Diagramme; Auswahl im Cookie.
- **Self-Monitoring:** Collector schreibt einen Heartbeat (`collector_status`),
  den das Dashboard in `/api/config` ausliefert und im Header anzeigt
  („Collector aktiv · Xs" bzw. rot bei Stillstand). Zusätzlich **systemd-
  Watchdog** über `sd_notify` (`WATCHDOG=1`) + `WatchdogSec=120` in der
  Collector-Unit (Auto-Neustart bei Hänger). Alles stdlib-only.

## [0.13.2] – 2026-07-11

### Neu
- **Bereiche per Drag & Drop umsortierbar:** Alle Container (Modelle & GPU,
  Instanzen, Alarm-Historie, Effizienz, Diagramme) liegen in `#sections` und
  lassen sich an ihrer Überschrift vertikal umordnen (Reihenfolge im Cookie
  `vllm_section_order`). Eigene Griff-Klasse `.shandle`, sauber getrennt von den
  inneren Kachel-Sortables.
- **Diagramme im eigenen einklappbaren Container**; die 4 Kacheldichte-Buttons
  sind aus der Titelleiste in dessen Überschrift gewandert (mehr Platz oben).

### Geändert / behoben
- **Maximierte Karten überdecken die Titelleiste nicht mehr** (Header sticky mit
  z-index über der Maximierung; Karte beginnt unterhalb des Headers).
- **Klick vs. Drag:** Sortier-Drag startet erst ab kleiner Bewegungsschwelle –
  ein Klick auf eine Bereichs-Überschrift klappt jetzt zuverlässig auf/zu statt
  als Drag interpretiert zu werden.

## [0.13.1] – 2026-07-11

### Geändert
- **KPI-Karten (Modelle & GPU)** liegen jetzt in einem einklappbaren Container
  („Modelle & GPU") – konsistent mit Instanzen, Alarm-Historie und Effizienz.
- **Aktualisierungs-Auswahl** (Live/SSE bzw. Poll-Intervall) aus der Titelleiste
  ins ⚙-Menü verschoben (aufgeräumtere Kopfzeile).

### Doku
- README: **Einzeiler-Installation** ergänzt
  (`git clone … && cd vLLM-Monitor && ./setup.sh`).

## [0.13.0] – 2026-07-11

### Neu
- **Alarm-Historie:** Der Collector protokolliert Zustandswechsel (offline,
  KV-Cache, GPU-Temperatur, Fehler) als Ereignisse in einer neuen `events`-
  Tabelle – jeweils „ausgelöst"/„behoben" mit Dauer. Dashboard: einklappbare
  Alarm-Historie-Karte + `GET /api/alerts`.
- **Konfigurierbare Schwellwerte** (statt hart im Code): `VLLM_ALERT_KV`,
  `VLLM_ALERT_TEMP`, `VLLM_ALERT_ERR`, `VLLM_ALERT_OFFLINE_MIN` – von Collector
  und Dashboard genutzt, ans Frontend über `/api/config` gereicht.
- **„Instanz seit X min offline"** in KPI-Karten und Alarmtexten.
- **Anomalie-Erkennung ohne KI** (robuste Median/MAD-Analyse): Ausreißer im
  Analyse-Panel + als rote Marker in allen Diagrammen (Toolbar „⚠ Anomalien").
- **Prognose** je Serie im Analyse-Panel (lineare Extrapolation, ETA bis
  Sättigung/Schwelle).
- **Zeitraum-Vergleich** als Overlay (vorige Periode / gestern / letzte Woche)
  über `GET /api/series?offset=…`.
- **Effizienz-/Kapazitäts-KPIs** (Tokens/Tag, GPU-Vollast-Std./Tag, tok/s pro
  Watt) als eigene Karte.
- **KI-Gesamt-Report** über alle Diagramme auf einen Klick (Toolbar „📋 KI-
  Report").
- **Geplanter KI-Schicht-Report:** `vllm_dashboard.sh report [sekunden]` schreibt
  einen deutschen Betriebs-Report in `VLLM_REPORT_DIR`; `setup.sh` richtet dafür
  optional einen systemd-Timer ein.
- **Reasoning-Abschaltung** `VLLM_AI_NO_THINK=1` (`chat_template_kwargs.
  enable_thinking=false`) für saubere, direkte KI-Antworten; `max_tokens` pro
  Anfrage überschreibbar; Defaults erhöht (`VLLM_AI_MAX_TOKENS=2000`,
  `VLLM_AI_TIMEOUT=120`).

## [0.12.2] – 2026-07-11

### Geändert
- **KI-Konfiguration ausschließlich server-seitig:** Die KI-Einstellungen
  (Endpunkt/Modell/Key/An-Aus) sind aus dem ⚙-Menü **entfernt**. Konfiguriert
  wird nur noch über `VLLM_AI_*` (Env bzw. `setup.sh`) – eine einzige Quelle für
  alle Frontends, kein Pro-Browser-Override mehr. Der 🔍-Button ist immer
  sichtbar; der Analyse-Request enthält nur den Prompt. Alte KI-Cookies
  (`vllm_ai_url/model/on/key`) werden beim Laden entfernt.

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
