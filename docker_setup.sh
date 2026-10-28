#!/usr/bin/env bash
#
# docker_setup.sh – Installation von vLLM Monitor als Docker-Container auf
# Debian 13 („trixie"). Interaktives Menü, analog zu setup.sh (systemd).
#
# Einfach ausführen:   sudo ./docker_setup.sh
#
# Installiert bei Bedarf Docker (Debian-Paket docker.io), baut das Image aus
# diesem Verzeichnis und startet zwei Container – Collector und Dashboard –,
# die sich das Datenverzeichnis teilen. Beide starten nach einem Reboot
# automatisch (--restart unless-stopped).
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${VLLM_DOCKER_BASE:-/opt/vllm-monitor}"
CONF="$BASE/setup.conf"          # gemerkte Antworten
ENVF="$BASE/monitor.env"         # Env-Datei für beide Container (0600)
IMAGE="vllm-monitor"
C_COL="vllm-monitor-collector"
C_DASH="vllm-monitor-dashboard"
CUID=10001                       # UID des Benutzers „monitor" im Container
REPORT_UNIT="vllm-monitor-report"
APP_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$DIR/vllm_dashboard.sh" 2>/dev/null | head -1)"

# Farben (nur wenn Terminal)
if [ -t 1 ]; then
    B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; DIM=$'\e[2m'; N=$'\e[0m'
else
    B=""; G=""; Y=""; R=""; DIM=""; N=""
fi
ok()   { echo "  ${G}✓${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
bad()  { echo "  ${R}✗${N} $*"; }

pause() { read -rp $'\nWeiter mit [Enter] …' _ || true; }

ask() {  # $1=Prompt  $2=Default  -> echo Antwort
    local prompt="$1" def="$2" ans
    if [ -n "$def" ]; then
        read -rp "$prompt [$def]: " ans || true
        echo "${ans:-$def}"
    else
        read -rp "$prompt: " ans || true
        echo "$ans"
    fi
}

is_yes() { [[ "${1,,}" == j* || "${1,,}" == y* ]]; }

valid_ip() { python3 - "$1" <<'EOF' 2>/dev/null
import sys, ipaddress
try: ipaddress.ip_address(sys.argv[1].strip()); sys.exit(0)
except Exception: sys.exit(1)
EOF
}

# Root wird für apt, Docker und /opt benötigt
if [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo VLLM_DOCKER_BASE="$BASE" bash "$0" "$@"
    fi
    echo "Bitte als root ausführen (oder sudo installieren)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Abhängigkeiten (Debian 13)
# ---------------------------------------------------------------------------
check_os() {
    # Subshell: os-release setzt u. a. VERSION, das soll hier nichts überschreiben
    [ -r /etc/os-release ] && (
        . /etc/os-release
        if [ "${ID:-}" = "debian" ] && [ "${VERSION_ID:-}" = "13" ]; then
            ok "Debian 13 (${VERSION_CODENAME:-trixie})"
        else
            warn "Erkannt: ${PRETTY_NAME:-unbekannt} – getestet ist Debian 13, es wird trotzdem fortgefahren."
        fi
    )
}

docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

install_deps() {
    echo "${B}Abhängigkeiten:${N}"
    check_os
    local pkgs=()
    command -v python3 >/dev/null 2>&1 || pkgs+=(python3)
    command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
    command -v docker  >/dev/null 2>&1 || pkgs+=(docker.io)
    if [ ${#pkgs[@]} -gt 0 ]; then
        echo "  Installiere: ${pkgs[*]}"
        if ! { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"; }; then
            bad "apt-get install ${pkgs[*]} fehlgeschlagen."; return 1
        fi
    fi
    ok "python3 $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
    ok "openssl vorhanden"
    if ! docker_ok; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi
    if docker_ok; then
        ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) läuft"
    else
        bad "Docker-Daemon nicht erreichbar – siehe: systemctl status docker"; return 1
    fi
    local f missing=0
    for f in vllm_collector.sh vllm_dashboard.sh Dockerfile docker/entrypoint.sh; do
        [ -f "$DIR/$f" ] || { bad "$f fehlt in $DIR"; missing=1; }
    done
    [ "$missing" = 0 ] && ok "Quellen vollständig ($DIR, Version ${APP_VERSION:-?})"
    return $missing
}

host_ips() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    else
        hostname -I 2>/dev/null | tr ' ' '\n'
    fi
}

host_tz() {
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
    [ -z "$tz" ] && [ -r /etc/timezone ] && tz="$(cat /etc/timezone)"
    [ -z "$tz" ] && tz="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
    echo "${tz:-Europe/Berlin}"
}

# ---------------------------------------------------------------------------
# TLS-Zertifikat (self-signed), SAN = alle Host-IPs + Hostname
# ---------------------------------------------------------------------------
gen_cert() {  # $1 = IP/Hostname, $2 = Zielverzeichnis
    local cn="$1" out="$2" san="" seen=" " x hn
    hn="$(hostname 2>/dev/null)"
    for x in "$cn" 127.0.0.1 $(host_ips); do
        valid_ip "$x" || continue
        case "$seen" in *" $x "*) continue;; esac
        seen="$seen$x "; san="${san:+$san,}IP:$x"
    done
    for x in localhost "$hn" "$cn"; do
        [ -n "$x" ] && ! valid_ip "$x" || continue
        case "$seen" in *" $x "*) continue;; esac
        seen="$seen$x "; san="${san:+$san,}DNS:$x"
    done
    if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/tls_key.pem" -out "$out/tls_cert.pem" \
        -days 3650 -subj "/CN=${cn:-llm-monitor}" \
        -addext "subjectAltName=$san" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null; then
        chmod 600 "$out/tls_key.pem"; chmod 644 "$out/tls_cert.pem"
        ok "Self-signed Zertifikat erzeugt (SAN: $san), 10 Jahre gültig."
    else
        bad "Zertifikat-Erzeugung fehlgeschlagen."; return 1
    fi
}

# ---------------------------------------------------------------------------
# Vorhandene Daten aus diesem Verzeichnis übernehmen (bisheriger systemd-Betrieb)
# ---------------------------------------------------------------------------
migrate_data() {  # $1 = Datenverzeichnis
    local data="$1" f have=0
    for f in vllm_metrics.db auth.json settings.json targets.json prefs.json .auth_secret; do
        [ -f "$DIR/$f" ] && have=1
    done
    [ "$have" = 1 ] || return 0
    [ -f "$data/vllm_metrics.db" ] || [ -f "$data/auth.json" ] && return 0

    echo
    warn "In $DIR liegen Daten eines bisherigen Betriebs (DB, Benutzer, Einstellungen)."
    is_yes "$(ask "In den Container übernehmen? [j/n]" "j")" || return 0
    if pgrep -f "vllm_collector.sh" >/dev/null 2>&1; then
        warn "Ein Collector läuft noch außerhalb von Docker – er sollte gestoppt werden"
        warn "(z. B. ./setup.sh → Deinstallieren), sonst wird doppelt gesammelt."
    fi
    if [ -f "$DIR/vllm_metrics.db" ]; then
        echo "  Kopiere Datenbank ($(du -h "$DIR/vllm_metrics.db" | cut -f1)) – konsistent per SQLite-Backup …"
        if python3 - "$DIR/vllm_metrics.db" "$data/vllm_metrics.db" <<'EOF'
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
EOF
        then ok "Datenbank übernommen."; else bad "Datenbank-Kopie fehlgeschlagen."; fi
    fi
    for f in auth.json settings.json targets.json prefs.json .auth_secret; do
        [ -f "$DIR/$f" ] && cp -p "$DIR/$f" "$data/$f" && ok "$f übernommen."
    done
    if [ -f "$DIR/tls_cert.pem" ] && [ -f "$DIR/tls_key.pem" ] && [ ! -f "$data/tls_cert.pem" ]; then
        cp -p "$DIR/tls_cert.pem" "$DIR/tls_key.pem" "$data/" && ok "TLS-Zertifikat übernommen."
    fi
}

# ---------------------------------------------------------------------------
# Image bauen, Container (neu) starten
# ---------------------------------------------------------------------------
build_image() {
    echo "  Baue Image $IMAGE:${APP_VERSION:-latest} (debian:trixie-slim) …"
    if docker build -q -t "$IMAGE:latest" ${APP_VERSION:+-t "$IMAGE:$APP_VERSION"} "$DIR" >/dev/null; then
        ok "Image gebaut: $IMAGE:${APP_VERSION:-latest}"
        # Vorgänger-Build ist jetzt unbenannt -> entfernen (nur eigene, per Label)
        docker image prune -f --filter "label=org.opencontainers.image.title=$IMAGE" >/dev/null 2>&1
    else
        bad "docker build fehlgeschlagen – Ausgabe: docker build $DIR"; return 1
    fi
}

start_containers() {
    [ -f "$CONF" ] || { bad "Nicht installiert (keine $CONF)."; return 1; }
    . "$CONF"
    local data="$VLLM_DATA" net=() pub=()
    if [ "$VLLM_NET" = "host" ]; then
        net=(--network host)
    else
        net=(--add-host host.docker.internal:host-gateway)
        pub=(-p "$VLLM_BIND:$VLLM_PORT:$VLLM_PORT")
    fi

    docker rm -f "$C_COL" "$C_DASH" >/dev/null 2>&1

    docker run -d --name "$C_COL" --init --restart unless-stopped \
        "${net[@]}" --env-file "$ENVF" -v "$data:/data" \
        --health-cmd "/app/docker-entrypoint.sh health-collector" \
        --health-interval 60s --health-start-period 60s --health-retries 3 \
        --log-opt max-size=10m --log-opt max-file=3 \
        "$IMAGE:latest" collector >/dev/null \
        || { bad "Collector-Container konnte nicht gestartet werden."; return 1; }

    docker run -d --name "$C_DASH" --init --restart unless-stopped \
        "${net[@]}" "${pub[@]}" --env-file "$ENVF" -v "$data:/data" \
        --health-cmd "/app/docker-entrypoint.sh health-dashboard" \
        --health-interval 30s --health-start-period 20s --health-retries 3 \
        --log-opt max-size=10m --log-opt max-file=3 \
        "$IMAGE:latest" dashboard >/dev/null \
        || { bad "Dashboard-Container konnte nicht gestartet werden."; return 1; }

    ok "Container gestartet: $C_COL, $C_DASH"
}

# kurz auf den Healthcheck des Dashboards warten
wait_healthy() {
    local i st=""
    for i in $(seq 1 15); do
        st="$(docker inspect -f '{{.State.Health.Status}}' "$C_DASH" 2>/dev/null)"
        [ "$st" = healthy ] && break
        sleep 2
    done
    if [ "$st" = healthy ]; then ok "Dashboard antwortet."; else
        warn "Dashboard noch nicht healthy ($st) – Logs: docker logs $C_DASH"; fi
}

# Geplanter KI-Schicht-Report: systemd-Timer auf dem Host -> docker exec
write_report_timer() {  # $1 = OnCalendar (leer = entfernen)
    local when="$1"
    if [ -z "$when" ]; then
        systemctl disable --now "$REPORT_UNIT.timer" >/dev/null 2>&1
        rm -f "/etc/systemd/system/$REPORT_UNIT.service" "/etc/systemd/system/$REPORT_UNIT.timer"
        systemctl daemon-reload 2>/dev/null
        return 0
    fi
    cat > "/etc/systemd/system/$REPORT_UNIT.service" <<EOF
[Unit]
Description=vLLM Monitor – KI-Schicht-Report (Docker)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$(command -v docker) exec $C_DASH /app/docker-entrypoint.sh report
EOF
    cat > "/etc/systemd/system/$REPORT_UNIT.timer" <<EOF
[Unit]
Description=Zeitplan für den vLLM KI-Schicht-Report

[Timer]
OnCalendar=$when
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$REPORT_UNIT.timer" >/dev/null 2>&1 \
        && ok "Report-Timer aktiv: $when (Ablage: $VLLM_DATA/reports)" \
        || warn "Report-Timer konnte nicht aktiviert werden."
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
do_install() {
    echo "${B}== Installation (Docker) ==${N}"
    install_deps || { echo; bad "Abhängigkeiten fehlen – Installation abgebrochen."; return 1; }

    # gemerkte Werte laden
    local VLLM_HOST="" VLLM_TARGETS="9081:Qwen,9082:Gemma" VLLM_OLLAMA="" VLLM_STT="" \
          VLLM_LMSTUDIO="" VLLM_DCGM="" VLLM_AI_URL="" VLLM_AI_MODEL="" VLLM_REPORT="" \
          VLLM_BIND="0.0.0.0" VLLM_PORT="8899" VLLM_HTTPS="j" VLLM_NET="bridge" \
          VLLM_TZ="" VLLM_DATA="$BASE/data"
    [ -f "$CONF" ] && . "$CONF"
    [ -z "$VLLM_TZ" ] && VLLM_TZ="$(host_tz)"

    echo
    local ip targets ollama stt lmstudio dcgm ai_url ai_model="" report_when="" net bind port https tz data
    while true; do
        ip="$(ask "Ziel-IP des vLLM-Hosts" "$VLLM_HOST")"
        valid_ip "$ip" && break
        bad "Ungültige IP-Adresse – bitte erneut."
    done
    targets="$(ask "vLLM-Instanzen ([host:]port[:label], mehrere per Komma)" "$VLLM_TARGETS")"
    ollama="$(ask "Ollama-Instanz(en)? host:port:label (leer=keine)" "$VLLM_OLLAMA")"
    stt="$(ask "STT-Server (faster-whisper)? host:port:label (leer=keiner)" "$VLLM_STT")"
    lmstudio="$(ask "LM-Studio-Instanz(en)? host:port:label (leer=keine)" "$VLLM_LMSTUDIO")"
    dcgm="$(ask "NVIDIA DCGM-Exporter (GPU)? host:port (leer=keiner)" "$VLLM_DCGM")"
    ai_url="$(ask "KI-Auswertung: Chat-Endpunkt (leer=später im UI unter ⚙ → KI-Verbindung)" "$VLLM_AI_URL")"
    [ -n "$ai_url" ] && ai_model="$(ask "KI-Modell (Name lt. /v1/models)" "$VLLM_AI_MODEL")"
    [ -n "$ai_url" ] && report_when="$(ask "Geplanter KI-Schicht-Report? systemd OnCalendar (z.B. '*-*-* 06,14,22:00', leer=aus)" "$VLLM_REPORT")"

    echo
    echo "  ${DIM}Netzwerk: 'bridge' = isoliert, Port wird veröffentlicht (Ziele auf diesem Host"
    echo "  über ihre LAN-IP oder host.docker.internal). 'host' = Container im Host-Netz"
    echo "  (nötig, wenn Ziele nur auf 127.0.0.1 dieses Hosts lauschen).${N}"
    while true; do
        net="$(ask "Netzwerkmodus (bridge/host)" "$VLLM_NET")"
        [[ "$net" == bridge || "$net" == host ]] && break
        bad "Bitte 'bridge' oder 'host'."
    done
    if [[ "$ip" == 127.* ]] && [ "$net" = bridge ]; then
        warn "Ziel 127.0.0.1 ist im bridge-Modus der Container selbst – 'host' wählen oder die LAN-IP angeben."
    fi
    bind="$(ask "Dashboard-Bind (0.0.0.0=Netz, 127.0.0.1=nur lokal)" "$VLLM_BIND")"
    port="$(ask "Dashboard-Port" "$VLLM_PORT")"
    tz="$(ask "Zeitzone (bestimmt die Tagesgrenzen für kWh/Tag, Tokens/Tag)" "$VLLM_TZ")"
    [ -e "/usr/share/zoneinfo/$tz" ] || warn "Zeitzone '$tz' auf dem Host unbekannt – bitte prüfen."
    data="$(ask "Datenverzeichnis (DB, Benutzer, Einstellungen)" "$VLLM_DATA")"

    mkdir -p "$BASE" "$data/reports"
    chmod 755 "$BASE"
    migrate_data "$data"

    local dash_ip="$bind"
    [ "$bind" = "0.0.0.0" ] && dash_ip="$(host_ips | head -1)"
    [ -z "$dash_ip" ] && dash_ip="127.0.0.1"
    https="n"
    if is_yes "$(ask "HTTPS aktivieren? (self-signed; empfohlen, da Login) [j/n]" "$VLLM_HTTPS")"; then
        https="j"
        if [ -f "$data/tls_cert.pem" ] && [ -f "$data/tls_key.pem" ]; then
            is_yes "$(ask "Vorhandenes Zertifikat neu erzeugen (für $dash_ip)? [j/N]" "n")" && gen_cert "$dash_ip" "$data"
            ok "HTTPS aktiv (Zertifikat: $data/tls_cert.pem)."
        else
            gen_cert "$dash_ip" "$data" || { https="n"; warn "Fahre ohne HTTPS fort."; }
        fi
    fi

    # Container läuft als UID $CUID – Datenverzeichnis gehört ihm
    chown -R "$CUID:$CUID" "$data"
    chmod 700 "$data"

    # merken
    cat > "$CONF" <<EOF
VLLM_HOST='$ip'
VLLM_TARGETS='$targets'
VLLM_OLLAMA='$ollama'
VLLM_STT='$stt'
VLLM_LMSTUDIO='$lmstudio'
VLLM_DCGM='$dcgm'
VLLM_AI_URL='$ai_url'
VLLM_AI_MODEL='$ai_model'
VLLM_REPORT='$report_when'
VLLM_NET='$net'
VLLM_BIND='$bind'
VLLM_PORT='$port'
VLLM_HTTPS='$https'
VLLM_TZ='$tz'
VLLM_DATA='$data'
EOF
    chmod 600 "$CONF"

    # Env-Datei für beide Container (docker --env-file: KEY=VALUE, keine Quotes)
    {
        echo "TZ=$tz"
        echo "VLLM_HOST=$ip"
        echo "VLLM_TARGETS=$targets"
        echo "VLLM_LABEL=$ip"
        [ -n "$ollama" ]   && { echo "VLLM_OLLAMA_TARGETS=$ollama"; echo "VLLM_OLLAMA_PROBE=1"; }
        [ -n "$stt" ]      && echo "VLLM_STT_TARGETS=$stt"
        [ -n "$lmstudio" ] && echo "VLLM_LMSTUDIO_TARGETS=$lmstudio"
        [ -n "$dcgm" ]     && echo "VLLM_DCGM_TARGETS=$dcgm"
        [ -n "$ai_url" ]   && { echo "VLLM_AI_URL=$ai_url"; echo "VLLM_AI_MODEL=$ai_model"; echo "VLLM_AI_NO_THINK=1"; }
        # im host-Modus lauscht das Dashboard direkt auf Bind/Port des Hosts
        if [ "$net" = host ]; then
            echo "VLLM_DASH_BIND=$bind"; echo "VLLM_DASH_PORT=$port"
        else
            echo "VLLM_DASH_BIND=0.0.0.0"; echo "VLLM_DASH_PORT=$port"
        fi
        [ "$https" = j ] && { echo "VLLM_TLS_CERT=/data/tls_cert.pem"; echo "VLLM_TLS_KEY=/data/tls_key.pem"; }
    } > "$ENVF"
    chmod 600 "$ENVF"
    ok "Konfiguration: $CONF, $ENVF"

    echo
    build_image || return 1
    start_containers || return 1
    VLLM_DATA="$data" write_report_timer "$report_when"

    wait_healthy

    local scheme="http"; [ "$https" = j ] && scheme="https"
    echo
    echo "${G}${B}Fertig.${N}  Ziel: $ip   Instanzen: $targets"
    echo "Dashboard:  ${B}${scheme}://${dash_ip}:$port${N}"
    [ "$https" = j ] && warn "Self-signed: der Browser zeigt einmalig eine Zertifikatswarnung – Ausnahme bestätigen."
    ok "Erstanmeldung mit ${B}admin / admin${N} – das Passwort muss sofort geändert werden."
    [ "$bind" = "0.0.0.0" ] && [ "$https" != j ] && warn "Login ohne HTTPS im Netz – Zugangsdaten gehen im Klartext übers Netz."
}

# ---------------------------------------------------------------------------
# Aktualisieren: Image aus dem aktuellen Stand neu bauen, Container ersetzen
# ---------------------------------------------------------------------------
do_update() {
    echo "${B}== Aktualisieren ==${N}"
    [ -f "$CONF" ] || { warn "Nicht installiert."; return 1; }
    if [ -d "$DIR/.git" ] && command -v git >/dev/null 2>&1; then
        is_yes "$(ask "Vorher 'git pull' in $DIR ausführen? [j/N]" "n")" && \
            sudo -u "$(stat -c %U "$DIR")" git -C "$DIR" pull --ff-only
        APP_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$DIR/vllm_dashboard.sh" | head -1)"
    fi
    build_image && start_containers && wait_healthy
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
do_uninstall() {
    echo "${B}== Deinstallation ==${N}"
    local data="$BASE/data" a
    [ -f "$CONF" ] && { . "$CONF"; data="$VLLM_DATA"; }

    docker rm -f "$C_COL" "$C_DASH" >/dev/null 2>&1 && ok "Container entfernt."
    write_report_timer ""
    # über die Tags löschen: eine ID mit mehreren Tags (latest + Version) lehnt rm sonst ab
    local tags; tags="$(docker image ls --format '{{.Repository}}:{{.Tag}}' "$IMAGE" 2>/dev/null)"
    [ -n "$tags" ] && docker image rm $tags >/dev/null 2>&1 && ok "Image $IMAGE entfernt."
    docker image prune -f --filter "label=org.opencontainers.image.title=$IMAGE" >/dev/null 2>&1

    if [ -d "$data" ]; then
        read -rp "Datenverzeichnis $data (DB, Benutzer, Einstellungen, Zertifikat) löschen? [j/N]: " a || true
        if is_yes "$a"; then rm -rf "$data"; ok "Daten gelöscht."; else echo "  ${DIM}Daten behalten.${N}"; fi
    fi
    read -rp "Konfiguration ($CONF, $ENVF) löschen? [j/N]: " a || true
    if is_yes "$a"; then rm -f "$CONF" "$ENVF"; rmdir "$BASE" 2>/dev/null; ok "Konfiguration gelöscht."; fi
    echo "  ${DIM}Docker selbst bleibt installiert (apt-get purge docker.io zum Entfernen).${N}"
    echo; ok "Deinstalliert."
}

# ---------------------------------------------------------------------------
# Status / Logs
# ---------------------------------------------------------------------------
do_status() {
    echo "${B}== Status ==${N}"
    if ! docker_ok; then bad "Docker nicht erreichbar."; return 1; fi
    local c st h any=0
    for c in "$C_COL" "$C_DASH"; do
        st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" || continue
        any=1
        h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null)"
        if [ "$st" = running ] && [ "$h" != unhealthy ]; then ok "$c – $st ${h:+($h)}"; else bad "$c – $st ${h:+($h)}"; fi
    done
    [ "$any" = 0 ] && { warn "Nicht installiert."; return 0; }
    if [ -f "$CONF" ]; then
        . "$CONF"
        local sch="http"; [ "$VLLM_HTTPS" = j ] && sch="https"
        echo "  ${DIM}Ziel: $VLLM_HOST  URL: $sch://…:$VLLM_PORT  Netz: $VLLM_NET  Daten: $VLLM_DATA${N}"
        [ -f "$VLLM_DATA/vllm_metrics.db" ] && echo "  ${DIM}DB: $(du -h "$VLLM_DATA/vllm_metrics.db" | cut -f1)${N}"
    fi
    docker exec "$C_COL" /app/docker-entrypoint.sh status 2>/dev/null | head -20
}

do_logs() {
    local c
    for c in "$C_COL" "$C_DASH"; do
        echo "${B}--- $c ---${N}"
        docker logs --tail 25 "$c" 2>&1 || warn "$c existiert nicht."
    done
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
menu() {
    while true; do
        echo
        echo "${B}############################################${N}"
        echo "${B}#   vLLM Monitor – Docker-Setup (Debian 13)#${N}"
        echo "${B}############################################${N}"
        echo "  1) Installieren / neu konfigurieren"
        echo "  2) Aktualisieren (Image neu bauen, Container ersetzen)"
        echo "  3) Status anzeigen"
        echo "  4) Logs anzeigen"
        echo "  5) Container neu starten"
        echo "  6) Deinstallieren"
        echo "  0) Beenden"
        local c; read -rp "Auswahl: " c || exit 0
        echo
        case "$c" in
            1) do_install; pause;;
            2) do_update; pause;;
            3) do_status; pause;;
            4) do_logs; pause;;
            5) docker restart "$C_COL" "$C_DASH" >/dev/null && ok "Neu gestartet." || bad "Neustart fehlgeschlagen."; pause;;
            6) do_uninstall; pause;;
            0) exit 0;;
            *) warn "Ungültige Auswahl.";;
        esac
    done
}

case "${1:-}" in
    install)   do_install ;;
    update)    do_update ;;
    status)    do_status ;;
    logs)      do_logs ;;
    uninstall) do_uninstall ;;
    "")        menu ;;
    *) echo "Aufruf: $0 [install|update|status|logs|uninstall]   (ohne Argument: Menü)"; exit 1 ;;
esac
