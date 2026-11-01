#!/usr/bin/env bash
#
# docker_setup.sh – Installation von vLLM Monitor als Docker-Container auf
# Debian 13 („trixie"). Interaktives Menü, analog zu setup.sh (systemd).
#
# Einfach ausführen:   sudo ./docker_setup.sh
#   oder direkt:       sudo ./docker_setup.sh [install|update|auto-update|status|logs|uninstall]
#
# Installiert bei Bedarf Docker (Debian-Paket docker.io), baut das Image aus
# diesem Verzeichnis und startet zwei Container – Collector und Dashboard –,
# die sich das Datenverzeichnis teilen. Beide starten nach einem Reboot
# automatisch (--restart unless-stopped). „update" holt den neuen Stand von
# GitHub (git, nur Fast-Forward), baut das Image neu und ersetzt die Container;
# „auto-update" ist dasselbe ohne Rückfragen für den Timer.
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
UPD_UNIT="vllm-monitor-update"
UPD_REPO="${VLLM_UPDATE_REPO:-dev-core-busy/vLLM-Monitor}"
UPD_BRANCH="${VLLM_UPDATE_BRANCH:-main}"
UPD_STATUS=""                    # $VLLM_DATA/update_status.json, liest das Dashboard als /data/…
# Änderung an einer dieser Dateien -> Image neu bauen
UPD_IMAGE=(Dockerfile .dockerignore docker/entrypoint.sh vllm_collector.sh vllm_dashboard.sh monitor.sh scan_for_llms.sh)
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
    # git braucht das (automatische) Update – nur bei einem git-Checkout sinnvoll
    [ -d "$DIR/.git" ] && ! command -v git >/dev/null 2>&1 && pkgs+=(git)
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
        warn "Dashboard noch nicht healthy ($st) – Logs: docker logs $C_DASH"; return 1; fi
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
# Gemerkte Einstellungen / Zeitpläne
# ---------------------------------------------------------------------------
conf_set() {  # $1=Schlüssel  $2=Wert – eine Zeile in $CONF setzen (Rechte bleiben)
    touch "$CONF"
    { grep -v "^$1=" "$CONF"; echo "$1='$2'"; } > "$CONF.tmp"
    cat "$CONF.tmp" > "$CONF"; rm -f "$CONF.tmp"
}

# leer oder gültiger systemd-Kalenderausdruck?
valid_calendar() {
    [ -z "$1" ] && return 0
    command -v systemd-analyze >/dev/null 2>&1 || return 0
    systemd-analyze calendar "$1" >/dev/null 2>&1
}

ask_calendar() {  # $1=Prompt  $2=Default -> echo OnCalendar (leer = aus)
    local v
    while true; do
        v="$(ask "$1" "$2")"
        [ "$v" = "-" ] && v=""
        valid_calendar "$v" && { echo "$v"; return; }
        bad "Kein gültiger OnCalendar-Ausdruck (Beispiel: '*-*-* 03:30' oder 'Sun 04:00')." >&2
    done
}

# ---------------------------------------------------------------------------
# Update von GitHub (git, nur Fast-Forward)
# ---------------------------------------------------------------------------
# git läuft als Eigentümer des Checkouts: als root lehnt git fremde
# Verzeichnisse ab („dubious ownership"), und dessen SSH-Key gehört zum Benutzer.
REPO_OWNER="$(stat -c %U "$DIR" 2>/dev/null)"
g() {
    if [ "$REPO_OWNER" = root ] || [ -z "$REPO_OWNER" ]; then
        GIT_TERMINAL_PROMPT=0 git -C "$DIR" "$@"
    else
        runuser -u "$REPO_OWNER" -- env HOME="$(getent passwd "$REPO_OWNER" | cut -d: -f6)" \
            GIT_TERMINAL_PROMPT=0 git -C "$DIR" "$@"
    fi
}
ver_of() { sed -n 's/^__version__ = "\(.*\)"/\1/p' | head -1; }      # liest stdin
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Schlüssel=Wert-Paare in update_status.json mischen; ok=… setzt auch den Zeitstempel
upd_status() {
    [ -n "$UPD_STATUS" ] && [ -d "$(dirname "$UPD_STATUS")" ] || return 0
    python3 - "$UPD_STATUS" "$@" <<'EOF' 2>/dev/null || true
import json, os, sys, time
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        st = json.load(f)
    if not isinstance(st, dict):
        st = {}
except (OSError, ValueError):
    st = {}
for arg in sys.argv[2:]:
    k, _, v = arg.partition("=")
    st[k] = (v == "1") if k == "ok" else v
    if k == "ok":
        st["ts"] = int(time.time())
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(st, f, ensure_ascii=False)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
EOF
}

# Neuen Stand nach FETCH_HEAD holen: erst über origin – ohne Rückfragen, im
# Timer gibt es weder Terminal noch ssh-agent –, sonst über die öffentliche
# HTTPS-Adresse des Repos.
git_fetch() {
    g -c core.sshCommand="ssh -o BatchMode=yes -o ConnectTimeout=10" \
        fetch -q origin "$UPD_BRANCH" 2>/dev/null && return 0
    g fetch -q "https://github.com/$UPD_REPO.git" "$UPD_BRANCH"
}

upd_fail() { bad "$1"; upd_status ok=0 "message=$1" "mode=$UPD_MODE"; }

# $1 = manual | auto.  Rückgabe 0 = aktualisiert oder nichts zu tun, 1 = Fehler;
# UPD_DONE=1, wenn tatsächlich ein neuer Stand eingespielt wurde.
# Auto aktualisiert nur auf eine neue __version__, nicht auf jeden Commit.
run_update() {
    UPD_MODE="$1"; UPD_DONE=0
    local cur new branch dirty changed n f rebuild=0

    [ -f "$CONF" ] || { bad "Nicht installiert (keine $CONF)."; return 1; }
    . "$CONF"
    UPD_STATUS="$VLLM_DATA/update_status.json"
    command -v git >/dev/null 2>&1 || { upd_fail "git ist nicht installiert (apt-get install git)"; return 1; }
    [ -d "$DIR/.git" ] || { upd_fail "$DIR ist kein git-Checkout (Update nur für per git clone installierte Kopien)"; return 1; }
    branch="$(g symbolic-ref --short -q HEAD)"
    if [ "$branch" != "$UPD_BRANCH" ]; then
        upd_fail "Arbeitskopie steht auf '${branch:-detached HEAD}', Updates kommen von '$UPD_BRANCH'"; return 1
    fi
    cur="$(ver_of < "$DIR/vllm_dashboard.sh")"
    git_fetch || { upd_fail "GitHub nicht erreichbar (git fetch fehlgeschlagen)"; return 1; }
    new="$(g show FETCH_HEAD:vllm_dashboard.sh 2>/dev/null | ver_of)"

    if [ "$(g rev-parse HEAD)" = "$(g rev-parse FETCH_HEAD)" ]; then
        ok "Bereits aktuell (${cur:-?})."
        upd_status ok=1 "message=bereits aktuell (${cur:-?})" "from=$cur" "to=$cur" "mode=$UPD_MODE"
        return 0
    fi
    if ! g merge-base --is-ancestor HEAD FETCH_HEAD; then
        if g merge-base --is-ancestor FETCH_HEAD HEAD; then
            ok "Arbeitskopie ist neuer als GitHub (${cur:-?}) – nichts zu tun."
            upd_status ok=1 "message=lokal neuer als GitHub (${cur:-?})" "from=$cur" "to=$cur" "mode=$UPD_MODE"
            return 0
        fi
        upd_fail "Lokale Commits, die nicht auf GitHub sind – kein Fast-Forward möglich"; return 1
    fi
    if [ "$UPD_MODE" = auto ] && ! ver_gt "$new" "$cur"; then
        ok "Neue Commits, aber keine neue Version (${cur:-?}) – Auto-Update wartet auf die nächste."
        upd_status ok=1 "message=keine neue Version (${cur:-?})" "from=$cur" "to=$cur" "mode=$UPD_MODE"
        return 0
    fi
    dirty="$(g status --porcelain --untracked-files=no)"
    n="$(g rev-list --count HEAD..FETCH_HEAD)"
    if [ "$UPD_MODE" = manual ]; then
        echo "  Installiert: ${B}${cur:-?}${N}   GitHub ($UPD_BRANCH): ${B}${new:-?}${N}   ($n neue Commits)"
        g log --oneline --no-decorate -n 15 HEAD..FETCH_HEAD | sed 's/^/    /'
        if [ -n "$dirty" ]; then
            warn "Lokale Änderungen an versionierten Dateien:"
            echo "$dirty" | sed 's/^/      /'
            warn "git bricht ab, falls das Update dieselben Dateien betrifft."
        fi
        is_yes "$(ask "Jetzt aktualisieren? [J/n]" "j")" || { echo "  ${DIM}Abgebrochen.${N}"; return 0; }
    elif [ -n "$dirty" ]; then
        upd_fail "Lokale Änderungen an versionierten Dateien ($(echo "$dirty" | awk '{print $2}' | paste -sd, -)) – Auto-Update ausgesetzt"
        return 1
    fi

    changed="$(g diff --name-only HEAD FETCH_HEAD)"
    if ! g merge -q --ff-only FETCH_HEAD; then
        upd_fail "git merge --ff-only fehlgeschlagen"; return 1
    fi
    UPD_DONE=1
    ok "Quellen aktualisiert: ${cur:-?} → ${new:-?}"
    APP_VERSION="$new"

    for f in "${UPD_IMAGE[@]}"; do
        grep -qx "$f" <<<"$changed" && rebuild=1
    done
    if [ "$rebuild" = 1 ]; then
        if ! { build_image && start_containers; }; then
            upd_fail "Quellen auf ${new:-?}, aber Image/Container konnten nicht erneuert werden"; return 1
        fi
        if ! wait_healthy; then
            upd_fail "Aktualisiert auf ${new:-?}, aber das Dashboard antwortet nicht (docker logs $C_DASH)"; return 1
        fi
    else
        echo "  ${DIM}Keine Datei des Images geändert – Container laufen unverändert weiter.${N}"
    fi
    upd_status ok=1 "message=aktualisiert ${cur:-?} → ${new:-?}" "from=$cur" "to=$new" "mode=$UPD_MODE"
    grep -qx "docker_setup.sh" <<<"$changed" && \
        warn "docker_setup.sh wurde geändert – Installieren (Punkt 1) erneut ausführen, damit neue Optionen greifen."
    return 0
}

# Für den Timer: keine Rückfragen, nie zwei Läufe gleichzeitig
do_auto_update() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>/run/vllm-monitor-update.lock
        flock -n 9 || { echo "Update läuft bereits."; return 0; }
    fi
    run_update auto
}

# Timer für das automatische Update (systemd auf dem Host)
write_update_timer() {  # $1 = OnCalendar (leer = entfernen)
    local when="$1"
    upd_status "auto=$when"
    if [ -z "$when" ]; then
        systemctl disable --now "$UPD_UNIT.timer" >/dev/null 2>&1
        rm -f "/etc/systemd/system/$UPD_UNIT.service" "/etc/systemd/system/$UPD_UNIT.timer"
        systemctl daemon-reload 2>/dev/null
        return 0
    fi
    cat > "/etc/systemd/system/$UPD_UNIT.service" <<EOF
[Unit]
Description=vLLM Monitor – automatisches Update von GitHub (Docker)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=VLLM_DOCKER_BASE=$BASE
Environment=VLLM_UPDATE_REPO=$UPD_REPO
Environment=VLLM_UPDATE_BRANCH=$UPD_BRANCH
ExecStart=$(command -v bash) $DIR/docker_setup.sh auto-update
EOF
    cat > "/etc/systemd/system/$UPD_UNIT.timer" <<EOF
[Unit]
Description=Zeitplan für das automatische Update von vLLM Monitor

[Timer]
OnCalendar=$when
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$UPD_UNIT.timer" >/dev/null 2>&1 \
        && ok "Auto-Update aktiv: $when (Log: journalctl -u $UPD_UNIT)" \
        || warn "Auto-Update-Timer konnte nicht aktiviert werden."
}

do_autoupdate_cfg() {
    echo "${B}== Automatisches Update ==${N}"
    [ -f "$CONF" ] || { warn "Nicht installiert."; return 1; }
    . "$CONF"
    UPD_STATUS="$VLLM_DATA/update_status.json"
    if [ ! -d "$DIR/.git" ]; then
        bad "$DIR ist kein git-Checkout – automatisches Update nicht möglich (git clone verwenden)."; return 1
    fi
    echo "  ${DIM}Holt nach Zeitplan neue Versionen von GitHub ($UPD_REPO, $UPD_BRANCH), baut das"
    echo "  Image neu und ersetzt die Container. Lokale Änderungen oder eigene Commits setzen es"
    echo "  aus – das Dashboard zeigt dann „Auto-Update fehlgeschlagen“. '-' schaltet es ab.${N}"
    local when; when="$(ask_calendar "Zeitplan (systemd OnCalendar)" "${VLLM_AUTOUPDATE:-*-*-* 03:30}")"
    conf_set VLLM_AUTOUPDATE "$when"
    write_update_timer "$when"
    [ -z "$when" ] && ok "Auto-Update aus."
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
do_install() {
    echo "${B}== Installation (Docker) ==${N}"
    install_deps || { echo; bad "Abhängigkeiten fehlen – Installation abgebrochen."; return 1; }

    # gemerkte Werte laden. Auto-Update ist bei einer neuen Installation an;
    # ein bewusst abgeschaltetes (VLLM_AUTOUPDATE='' in $CONF) bleibt aus.
    local VLLM_HOST="" VLLM_TARGETS="9081:Qwen,9082:Gemma" VLLM_OLLAMA="" VLLM_STT="" \
          VLLM_LMSTUDIO="" VLLM_DCGM="" VLLM_AI_URL="" VLLM_AI_MODEL="" VLLM_REPORT="" \
          VLLM_BIND="0.0.0.0" VLLM_PORT="8899" VLLM_HTTPS="j" VLLM_NET="bridge" \
          VLLM_TZ="" VLLM_DATA="$BASE/data" VLLM_AUTOUPDATE="*-*-* 03:30" VLLM_UPDATE_CHECK="j"
    [ -f "$CONF" ] && . "$CONF"
    [ -z "$VLLM_TZ" ] && VLLM_TZ="$(host_tz)"

    echo
    local ip targets ollama stt lmstudio dcgm ai_url ai_model="" report_when="" net bind port https tz data
    local updchk autoupd=""
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
    updchk="$(ask "Update-Hinweis im Dashboard (prüft GitHub alle 6 h)? [j/n]" "$VLLM_UPDATE_CHECK")"
    is_yes "$updchk" && updchk="j" || updchk="n"
    if [ -d "$DIR/.git" ]; then
        autoupd="$(ask_calendar "Automatisches Update von GitHub? systemd OnCalendar ('-'=aus)" "$VLLM_AUTOUPDATE")"
    else
        warn "Kein git-Checkout – automatisches Update nicht möglich (git clone verwenden)."
    fi

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
VLLM_AUTOUPDATE='$autoupd'
VLLM_UPDATE_CHECK='$updchk'
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
        [ "$updchk" = n ] && echo "VLLM_UPDATE_CHECK=0"
    } > "$ENVF"
    chmod 600 "$ENVF"
    ok "Konfiguration: $CONF, $ENVF"

    echo
    build_image || return 1
    start_containers || return 1
    VLLM_DATA="$data" write_report_timer "$report_when"
    UPD_STATUS="$data/update_status.json" write_update_timer "$autoupd"

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
    echo "${B}== Aktualisieren (GitHub $UPD_REPO, $UPD_BRANCH) ==${N}"
    [ -f "$CONF" ] || { warn "Nicht installiert."; return 1; }
    run_update manual
    [ "$UPD_DONE" = 1 ] && return 0
    # nichts Neues eingespielt: auf Wunsch aus dem lokalen Stand neu bauen
    # (z. B. nach eigenen Änderungen oder bei einer Kopie ohne git)
    is_yes "$(ask "Image trotzdem aus dem lokalen Stand neu bauen und Container ersetzen? [j/N]" "n")" || return 0
    APP_VERSION="$(ver_of < "$DIR/vllm_dashboard.sh")"
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
    write_update_timer ""
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
        echo "  ${DIM}Version (Quellen): $(ver_of < "$DIR/vllm_dashboard.sh")${N}"
        if [ -f "/etc/systemd/system/$UPD_UNIT.timer" ]; then
            ok "Auto-Update: $(sed -n 's/^OnCalendar=//p' "/etc/systemd/system/$UPD_UNIT.timer")" \
               "– nächster Lauf: $(systemctl show -p NextElapseUSecRealtime --value "$UPD_UNIT.timer" 2>/dev/null)"
        else
            echo "  ${DIM}Auto-Update aus.${N}"
        fi
        [ -f "$VLLM_DATA/update_status.json" ] && python3 - "$VLLM_DATA/update_status.json" <<'EOF' 2>/dev/null
import json, sys, time
st = json.load(open(sys.argv[1], encoding="utf-8"))
if st.get("ts"):
    print("  Letzter Update-Lauf %s: %s%s" % (time.strftime("%d.%m.%Y %H:%M", time.localtime(st["ts"])),
          "" if st.get("ok") else "FEHLER – ", st.get("message", "")))
EOF
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
        echo "  2) Aktualisieren (neue Version von GitHub, Image neu bauen)"
        echo "  3) Status anzeigen"
        echo "  4) Logs anzeigen"
        echo "  5) Container neu starten"
        echo "  6) Deinstallieren"
        echo "  7) Automatisches Update einrichten/ändern"
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
            7) do_autoupdate_cfg; pause;;
            0) exit 0;;
            *) warn "Ungültige Auswahl.";;
        esac
    done
}

case "${1:-}" in
    install)   do_install ;;
    update)    do_update ;;
    auto-update) do_auto_update ;;
    status)    do_status ;;
    logs)      do_logs ;;
    uninstall) do_uninstall ;;
    "")        menu ;;
    *) echo "Aufruf: $0 [install|update|auto-update|status|logs|uninstall]   (ohne Argument: Menü)"; exit 1 ;;
esac
