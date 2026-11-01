#!/usr/bin/env bash
#
# setup.sh – Interaktives Installations-/Deinstallationsmenü für vLLM Monitor.
#
# Einfach ausführen:   ./setup.sh
#   oder direkt:       ./setup.sh [install|update|auto-update|status|uninstall]
#
# Richtet die beiden systemd-User-Dienste (Collector + Dashboard) ein,
# prüft die Abhängigkeiten und kann alles wieder vollständig entfernen.
# „update" holt den neuen Stand von GitHub (git, nur Fast-Forward) und startet
# die Dienste neu; „auto-update" ist dasselbe ohne Rückfragen für den Timer.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
PY="$(command -v python3 || true)"
CONF="$HOME/.vllm_monitor_setup"
DB="$DIR/vllm_metrics.db"
CERT="$DIR/tls_cert.pem"
KEY="$DIR/tls_key.pem"
SERVICES=(vllm-collector.service vllm-dashboard.service)
UPD_UNIT="vllm-update"
UPD_REPO="${VLLM_UPDATE_REPO:-dev-core-busy/vLLM-Monitor}"
UPD_BRANCH="${VLLM_UPDATE_BRANCH:-main}"
UPD_STATUS="$DIR/update_status.json"       # liest das Dashboard (neben der DB)
UPD_RUNTIME=(vllm_collector.sh vllm_dashboard.sh)   # Änderung -> Dienste neu starten

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

valid_ip() { [ -n "$PY" ] && "$PY" - "$1" <<'EOF' 2>/dev/null
import sys, ipaddress
try: ipaddress.ip_address(sys.argv[1].strip()); sys.exit(0)
except Exception: sys.exit(1)
EOF
}

# ---------------------------------------------------------------------------
# Abhängigkeitsprüfung
# ---------------------------------------------------------------------------
check_deps() {
    # Rückgabe: 0 = alles kritische ok, 1 = etwas fehlt
    local fail=0
    echo "${B}Abhängigkeiten:${N}"

    if [ -n "$PY" ]; then
        local ver
        ver="$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
        if "$PY" -c 'import sys;sys.exit(0 if sys.version_info>=(3,8) else 1)' 2>/dev/null; then
            ok "python3 $ver ($PY)"
        else
            bad "python3 $ver – benötigt wird 3.8+"; fail=1
        fi
    else
        bad "python3 nicht gefunden"; fail=1
    fi

    if [ -n "$PY" ] && "$PY" -c 'import sqlite3,http.server,json,urllib.request' 2>/dev/null; then
        ok "Python-Standardmodule (sqlite3, http.server, json, urllib)"
    else
        bad "benötigte Python-Standardmodule fehlen"; fail=1
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl --user list-units >/dev/null 2>&1; then
        ok "systemd (User-Instanz erreichbar)"
    else
        bad "systemctl --user nicht verfügbar (kein systemd-User-Bus?)"; fail=1
    fi

    if command -v loginctl >/dev/null 2>&1; then
        if loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
            ok "Linger aktiv (Autostart nach Reboot)"
        else
            warn "Linger noch nicht aktiv – wird bei der Installation versucht"
        fi
    fi

    if command -v openssl >/dev/null 2>&1; then
        ok "openssl vorhanden (für HTTPS/Zertifikat)"
    else
        warn "openssl fehlt – HTTPS/Zertifikat nicht verfügbar (HTTP funktioniert weiterhin)"
    fi

    local missing=0
    for f in vllm_collector.sh vllm_dashboard.sh; do
        if [ -f "$DIR/$f" ]; then ok "$f vorhanden"; else bad "$f fehlt in $DIR"; missing=1; fi
    done
    [ "$missing" = 1 ] && fail=1

    return $fail
}

# ---------------------------------------------------------------------------
# Eingaben (mit gemerkten Vorgaben)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# TLS-Zertifikat (self-signed) erzeugen
# ---------------------------------------------------------------------------
gen_cert() {  # $1 = IP/Hostname für den Common Name
    local cn="$1"
    if ! command -v openssl >/dev/null 2>&1; then
        bad "openssl nicht gefunden – kann kein Zertifikat erzeugen."; return 1
    fi
    # SAN um ALLE lokalen IPv4-Adressen + Hostname ergänzen, damit das
    # Zertifikat unabhängig davon passt, über welche Adresse das Dashboard
    # aufgerufen wird (sonst: Browser meldet "nicht sicher" trotz Import).
    local local_ips=""
    if command -v ip >/dev/null 2>&1; then
        local_ips="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    elif command -v hostname >/dev/null 2>&1; then
        local_ips="$(hostname -I 2>/dev/null)"
    fi
    local hn; hn="$(hostname 2>/dev/null)"
    local cand_ips="127.0.0.1 $local_ips" names="localhost"
    [ -n "$hn" ] && [ "$hn" != "localhost" ] && names="$names $hn"
    if valid_ip "$cn"; then cand_ips="$cn $cand_ips"; elif [ -n "$cn" ]; then names="$cn $names"; fi
    # IPs deduplizieren
    local san="" seen=" " x
    for x in $cand_ips; do
        valid_ip "$x" || continue
        case "$seen" in *" $x "*) continue;; esac
        seen="$seen$x "; san="${san:+$san,}IP:$x"
    done
    # Namen deduplizieren
    local nseen=" "
    for x in $names; do
        [ -n "$x" ] || continue
        case "$nseen" in *" $x "*) continue;; esac
        nseen="$nseen$x "; san="${san:+$san,}DNS:$x"
    done
    if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CERT" -days 3650 \
        -subj "/CN=${cn:-llm-monitor}" \
        -addext "subjectAltName=$san" \
        -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null; then
        chmod 600 "$KEY"; chmod 644 "$CERT"
        ok "Self-signed Zertifikat erzeugt (SAN: $san), 10 Jahre gültig."
    else
        bad "Zertifikat-Erzeugung fehlgeschlagen."; return 1
    fi
}

# ---------------------------------------------------------------------------
# Gemerkte Einstellungen: eine Zeile in $CONF setzen
# ---------------------------------------------------------------------------
conf_set() {  # $1=Schlüssel  $2=Wert
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
g() { GIT_TERMINAL_PROMPT=0 git -C "$DIR" "$@"; }
ver_of() { sed -n 's/^__version__ = "\(.*\)"/\1/p' | head -1; }      # liest stdin
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Schlüssel=Wert-Paare in update_status.json mischen; ok=… setzt auch den Zeitstempel
upd_status() {
    [ -n "$PY" ] || return 0
    "$PY" - "$UPD_STATUS" "$@" <<'EOF' 2>/dev/null || true
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

# $1 = manual | auto.  Rückgabe 0 = aktualisiert oder nichts zu tun, 1 = Fehler.
# Auto aktualisiert nur auf eine neue __version__, nicht auf jeden Commit.
run_update() {
    UPD_MODE="$1"
    local cur new branch dirty changed n f restart=0

    command -v git >/dev/null 2>&1 || { upd_fail "git ist nicht installiert"; return 1; }
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
        [[ "$(ask "Jetzt aktualisieren? [J/n]" "j")" =~ ^[jJyY] ]] || { echo "  ${DIM}Abgebrochen.${N}"; return 0; }
    elif [ -n "$dirty" ]; then
        upd_fail "Lokale Änderungen an versionierten Dateien ($(echo "$dirty" | awk '{print $2}' | paste -sd, -)) – Auto-Update ausgesetzt"
        return 1
    fi

    changed="$(g diff --name-only HEAD FETCH_HEAD)"
    if ! g merge -q --ff-only FETCH_HEAD; then
        upd_fail "git merge --ff-only fehlgeschlagen"; return 1
    fi
    ok "Aktualisiert: ${cur:-?} → ${new:-?}"
    upd_status ok=1 "message=aktualisiert ${cur:-?} → ${new:-?}" "from=$cur" "to=$new" "mode=$UPD_MODE"

    for f in "${UPD_RUNTIME[@]}"; do
        grep -qx "$f" <<<"$changed" && restart=1
    done
    if [ "$restart" = 1 ] && [ -f "$UNIT_DIR/vllm-collector.service" ]; then
        if systemctl --user restart "${SERVICES[@]}" 2>/dev/null; then
            ok "Dienste neu gestartet."
        else
            upd_fail "Aktualisiert auf ${new:-?}, aber Dienste konnten nicht neu gestartet werden"; return 1
        fi
    fi
    grep -qx "setup.sh" <<<"$changed" && \
        warn "setup.sh wurde geändert – Installieren (Punkt 1) erneut ausführen, damit neue Dienst-Optionen greifen."
    return 0
}

do_update() {
    echo "${B}== Aktualisieren (GitHub $UPD_REPO, $UPD_BRANCH) ==${N}"
    run_update manual
}

# Für den Timer: keine Rückfragen, nie zwei Läufe gleichzeitig
do_auto_update() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${XDG_RUNTIME_DIR:-/tmp}/vllm-monitor-update.lock"
        flock -n 9 || { echo "Update läuft bereits."; return 0; }
    fi
    run_update auto
}

# Timer für das automatische Update (User-Units neben den Diensten)
write_update_timer() {  # $1 = OnCalendar (leer = entfernen)
    local when="$1"
    upd_status "auto=$when"
    if [ -z "$when" ]; then
        systemctl --user disable --now "$UPD_UNIT.timer" 2>/dev/null
        rm -f "$UNIT_DIR/$UPD_UNIT.service" "$UNIT_DIR/$UPD_UNIT.timer"
        systemctl --user daemon-reload 2>/dev/null
        return 0
    fi
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/$UPD_UNIT.service" <<EOF
[Unit]
Description=vLLM Monitor – automatisches Update von GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$DIR
Environment=VLLM_UPDATE_REPO=$UPD_REPO
Environment=VLLM_UPDATE_BRANCH=$UPD_BRANCH
ExecStart=$(command -v bash) $DIR/setup.sh auto-update
EOF
    cat > "$UNIT_DIR/$UPD_UNIT.timer" <<EOF
[Unit]
Description=Zeitplan für das automatische Update von vLLM Monitor

[Timer]
OnCalendar=$when
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    if systemctl --user enable --now "$UPD_UNIT.timer" 2>/dev/null; then
        ok "Auto-Update aktiv: $when (Log: journalctl --user -u $UPD_UNIT)"
    else
        warn "Auto-Update-Timer konnte nicht aktiviert werden."
    fi
}

do_autoupdate_cfg() {
    echo "${B}== Automatisches Update ==${N}"
    [ -f "$CONF" ] && . "$CONF" 2>/dev/null
    if [ ! -d "$DIR/.git" ]; then
        bad "$DIR ist kein git-Checkout – automatisches Update nicht möglich (git clone verwenden)."; return 1
    fi
    echo "  ${DIM}Holt nach Zeitplan neue Versionen von GitHub ($UPD_REPO, $UPD_BRANCH) und startet"
    echo "  die Dienste neu. Lokale Änderungen oder eigene Commits setzen es aus – das Dashboard"
    echo "  zeigt dann „Auto-Update fehlgeschlagen“. '-' schaltet es ab.${N}"
    local when; when="$(ask_calendar "Zeitplan (systemd OnCalendar)" "${VLLM_AUTOUPDATE:-*-*-* 03:30}")"
    conf_set VLLM_AUTOUPDATE "$when"
    write_update_timer "$when"
    [ -z "$when" ] && ok "Auto-Update aus."
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
do_install() {
    echo "${B}== Installation ==${N}"
    if ! check_deps; then
        echo; bad "Kritische Abhängigkeiten fehlen – Installation abgebrochen."
        return 1
    fi

    # gemerkte Werte laden
    local D_IP="" D_TARGETS="9081:Qwen,9082:Gemma" D_BIND="0.0.0.0" D_PORT="8899" D_HTTPS="n" D_OLLAMA=""
    [ -f "$CONF" ] && . "$CONF" 2>/dev/null
    D_IP="${VLLM_HOST:-$D_IP}"
    D_TARGETS="${VLLM_TARGETS:-$D_TARGETS}"
    D_BIND="${VLLM_BIND:-$D_BIND}"
    D_PORT="${VLLM_PORT:-$D_PORT}"
    D_HTTPS="${VLLM_HTTPS:-$D_HTTPS}"
    D_OLLAMA="${VLLM_OLLAMA:-$D_OLLAMA}"
    local D_STT="${VLLM_STT:-}"
    local D_LMSTUDIO="${VLLM_LMSTUDIO:-}"
    local D_DCGM="${VLLM_DCGM:-}"
    local D_AI_URL="${VLLM_AI_URL:-}"
    local D_AI_MODEL="${VLLM_AI_MODEL:-}"
    local D_REPORT="${VLLM_REPORT:-}"
    local D_AUTOUPD="${VLLM_AUTOUPDATE-}" D_UPDCHK="${VLLM_UPDATE_CHECK:-j}"

    echo
    local ip targets bind port https="n" ans ollama stt lmstudio dcgm ai_url ai_model report_when autoupd updchk
    while true; do
        ip="$(ask "Ziel-IP des vLLM-Hosts" "$D_IP")"
        if valid_ip "$ip"; then break; fi
        bad "Ungültige IP-Adresse – bitte erneut."
    done
    targets="$(ask "vLLM-Instanzen ([host:]port[:label], mehrere per Komma; Host-Präfix = anderer Host)" "$D_TARGETS")"
    ollama="$(ask "Ollama-Instanz(en)? host:port:label (leer=keine, Autoscan bleibt aktiv)" "$D_OLLAMA")"
    stt="$(ask "STT-Server (faster-whisper)? host:port:label (leer=keiner)" "$D_STT")"
    lmstudio="$(ask "LM-Studio-Instanz(en)? host:port:label (Standardport 1234, leer=keine)" "$D_LMSTUDIO")"
    dcgm="$(ask "NVIDIA DCGM-Exporter (GPU)? host:port (leer=keiner)" "$D_DCGM")"
    # nur Vorbelegung: gepflegt wird die KI-Verbindung spaeter im Dashboard
    # (Zahnrad-Menue -> KI-Verbindung), gespeichert in settings.json
    ai_url="$(ask "KI-Auswertung: Chat-Endpunkt (host:port o. .../v1/chat/completions, leer=spaeter im UI)" "$D_AI_URL")"
    ai_model=""
    [ -n "$ai_url" ] && ai_model="$(ask "KI-Modell (Name lt. /v1/models)" "$D_AI_MODEL")"
    report_when=""
    [ -n "$ai_url" ] && report_when="$(ask "Geplanter KI-Schicht-Report? systemd OnCalendar (z.B. '*-*-* 06,14,22:00', leer=aus)" "$D_REPORT")"
    bind="$(ask "Dashboard-Bind (0.0.0.0=Netz, 127.0.0.1=nur lokal)" "$D_BIND")"
    port="$(ask "Dashboard-Port" "$D_PORT")"
    updchk="$(ask "Update-Hinweis im Dashboard (prüft GitHub alle 6 h)? [j/n]" "$D_UPDCHK")"
    [[ "${updchk,,}" == j* || "${updchk,,}" == y* ]] && updchk="j" || updchk="n"
    if [ -d "$DIR/.git" ]; then
        autoupd="$(ask_calendar "Automatisches Update von GitHub? systemd OnCalendar (z.B. '*-*-* 03:30', '-'=aus)" "$D_AUTOUPD")"
    else
        autoupd=""; warn "Kein git-Checkout – automatisches Update nicht möglich (git clone verwenden)."
    fi
    # Zertifikat muss auf die Adresse lauten, die der BROWSER aufruft (Dashboard-Host)
    local dash_ip="$bind"
    [ "$bind" = "0.0.0.0" ] && dash_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "$dash_ip" ] && dash_ip="127.0.0.1"

    ans="$(ask "HTTPS aktivieren? (self-signed; nötig für Benachrichtigungen im Netz) [j/n]" "$D_HTTPS")"
    if [[ "${ans,,}" == "j" ]]; then
        https="j"
        if [ -f "$CERT" ] && [ -f "$KEY" ]; then
            ask "Vorhandenes Zertifikat neu erzeugen (für $dash_ip)? [j/N]" "n" | grep -qi '^j' && gen_cert "$dash_ip"
            ok "HTTPS aktiv (Zertifikat: $CERT)."
        else
            gen_cert "$dash_ip" || { https="n"; warn "Fahre ohne HTTPS fort."; }
        fi
    fi

    # merken
    # gequotet: OnCalendar-Ausdrücke enthalten Leerzeichen
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
VLLM_BIND='$bind'
VLLM_PORT='$port'
VLLM_HTTPS='$https'
EOF

    mkdir -p "$UNIT_DIR"

    local ollama_env=""
    [ -n "$ollama" ] && ollama_env="Environment=VLLM_OLLAMA_TARGETS=$ollama"$'\n'"Environment=VLLM_OLLAMA_PROBE=1"
    local stt_env=""
    [ -n "$stt" ] && stt_env="Environment=VLLM_STT_TARGETS=$stt"
    local lmstudio_env=""
    [ -n "$lmstudio" ] && lmstudio_env="Environment=VLLM_LMSTUDIO_TARGETS=$lmstudio"
    local dcgm_env=""
    [ -n "$dcgm" ] && dcgm_env="Environment=VLLM_DCGM_TARGETS=$dcgm"

    cat > "$UNIT_DIR/vllm-collector.service" <<EOF
[Unit]
Description=vLLM Metrik-Collector ($ip)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DIR
Environment=VLLM_HOST=$ip
Environment=VLLM_TARGETS=$targets
${ollama_env}
${stt_env}
${lmstudio_env}
${dcgm_env}
ExecStart=$PY $DIR/vllm_collector.sh loop
Restart=always
RestartSec=10
WatchdogSec=120
NotifyAccess=main

[Install]
WantedBy=default.target
EOF

    local tls_env=""
    [ "$https" = "j" ] && tls_env="Environment=VLLM_TLS_CERT=$CERT"$'\n'"Environment=VLLM_TLS_KEY=$KEY"
    local upd_env=""
    [ "$updchk" = "n" ] && upd_env="Environment=VLLM_UPDATE_CHECK=0"
    local ai_env=""
    [ -n "$ai_url" ] && ai_env="Environment=VLLM_AI_URL=$ai_url"$'\n'"Environment=VLLM_AI_MODEL=$ai_model"$'\n'"Environment=VLLM_AI_NO_THINK=1"

    cat > "$UNIT_DIR/vllm-dashboard.service" <<EOF
[Unit]
Description=vLLM Monitoring-Dashboard (Port $port)
After=vllm-collector.service

[Service]
Type=simple
WorkingDirectory=$DIR
Environment=VLLM_LABEL=$ip
${tls_env}
${ai_env}
${upd_env}
ExecStart=$PY $DIR/vllm_dashboard.sh $port $bind
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

    # Optionaler geplanter KI-Schicht-Report (oneshot service + timer)
    if [ -n "$report_when" ]; then
        cat > "$UNIT_DIR/vllm-report.service" <<EOF
[Unit]
Description=vLLM KI-Schicht-Report

[Service]
Type=oneshot
WorkingDirectory=$DIR
Environment=VLLM_HOST=$ip
Environment=VLLM_TARGETS=$targets
${ai_env}
ExecStart=$PY $DIR/vllm_dashboard.sh report
EOF
        cat > "$UNIT_DIR/vllm-report.timer" <<EOF
[Unit]
Description=Zeitplan für den vLLM KI-Schicht-Report

[Timer]
OnCalendar=$report_when
Persistent=true

[Install]
WantedBy=timers.target
EOF
    else
        systemctl --user disable --now vllm-report.timer 2>/dev/null
        rm -f "$UNIT_DIR/vllm-report.service" "$UNIT_DIR/vllm-report.timer"
    fi

    echo
    systemctl --user daemon-reload
    systemctl --user enable "${SERVICES[@]}" 2>/dev/null
    [ -n "$report_when" ] && systemctl --user enable --now vllm-report.timer 2>/dev/null \
        && ok "Report-Timer aktiv: $report_when"
    # restart (nicht nur start), damit geänderte Unit-Env auch bei laufendem Dienst greift
    if systemctl --user restart "${SERVICES[@]}" 2>/dev/null; then
        ok "Dienste installiert und (neu) gestartet."
    else
        bad "Dienste konnten nicht gestartet werden – siehe: systemctl --user status ${SERVICES[0]}"
        return 1
    fi

    write_update_timer "$autoupd"

    # Autostart ohne Login
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        if sudo loginctl enable-linger "$USER" 2>/dev/null; then
            ok "Linger aktiviert (Autostart nach Reboot)."
        else
            warn "Linger nicht aktiviert – für Autostart nach Reboot manuell: sudo loginctl enable-linger $USER"
        fi
    fi

    local shown="$bind" scheme="http"
    [ "$bind" = "0.0.0.0" ] && shown="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ "$https" = "j" ] && scheme="https"
    echo
    echo "${G}${B}Fertig.${N}  Ziel: $ip   Instanzen: $targets"
    echo "Dashboard:  ${B}${scheme}://${shown:-127.0.0.1}:$port${N}"
    [ "$https" = "j" ] && warn "Self-signed: der Browser zeigt einmalig eine Zertifikatswarnung – Ausnahme bestätigen."
    ok "Erstanmeldung im Browser mit ${B}admin / admin${N} – das Passwort wird sofort abgefragt und muss geändert werden."
    echo "   Weitere Benutzer und die LDAP-/AD-Anbindung werden danach im Dashboard unter ⚙ → 👥 Benutzer & Zugriff gepflegt."
    [ "$bind" = "0.0.0.0" ] && [ "$https" != "j" ] && warn "Login ohne HTTPS im Netz – Zugangsdaten gehen im Klartext übers Netz. HTTPS empfohlen."
}

# ---------------------------------------------------------------------------
# Vollständige Deinstallation
# ---------------------------------------------------------------------------
do_uninstall() {
    echo "${B}== Deinstallation ==${N}"
    if [ ! -f "$UNIT_DIR/vllm-collector.service" ] && [ ! -f "$UNIT_DIR/vllm-dashboard.service" ]; then
        warn "Keine Dienste installiert."
    fi

    systemctl --user disable --now "${SERVICES[@]}" 2>/dev/null
    systemctl --user disable --now vllm-report.timer "$UPD_UNIT.timer" 2>/dev/null
    for s in "${SERVICES[@]}"; do rm -f "$UNIT_DIR/$s"; done
    rm -f "$UNIT_DIR/vllm-report.service" "$UNIT_DIR/vllm-report.timer" \
          "$UNIT_DIR/$UPD_UNIT.service" "$UNIT_DIR/$UPD_UNIT.timer" "$UPD_STATUS"
    systemctl --user daemon-reload
    systemctl --user reset-failed "${SERVICES[@]}" vllm-report.timer "$UPD_UNIT.service" "$UPD_UNIT.timer" 2>/dev/null
    ok "Dienste gestoppt, deaktiviert und Unit-Dateien entfernt."

    local a
    read -rp "Messdaten-Datenbank ($DB) ebenfalls löschen? [j/N]: " a || true
    if [[ "${a,,}" == "j" ]]; then
        rm -f "$DB" "$DB-wal" "$DB-shm"; ok "Datenbank gelöscht."
    else
        echo "  ${DIM}Datenbank behalten.${N}"
    fi

    read -rp "Gemerkte Einstellungen ($CONF) löschen? [j/N]: " a || true
    if [[ "${a,,}" == "j" ]]; then rm -f "$CONF"; ok "Einstellungen gelöscht."; fi

    if [ -f "$DIR/auth.json" ] || [ -f "$DIR/settings.json" ] || [ -f "$DIR/targets.json" ]; then
        read -rp "Benutzer/LDAP, Schwellwerte und Zusatz-Instanzen (auth.json, settings.json, targets.json) löschen? [j/N]: " a || true
        if [[ "${a,,}" == "j" ]]; then
            rm -f "$DIR/auth.json" "$DIR/settings.json" "$DIR/targets.json" "$DIR/.auth_secret"
            ok "Lokale Konfiguration (Benutzer/Schwellwerte/Instanzen) gelöscht."
        fi
    fi

    if [ -f "$CERT" ] || [ -f "$KEY" ]; then
        read -rp "TLS-Zertifikat ($CERT / Key) löschen? [j/N]: " a || true
        if [[ "${a,,}" == "j" ]]; then rm -f "$CERT" "$KEY"; ok "Zertifikat gelöscht."; fi
    fi

    rm -rf "$DIR/__pycache__"

    read -rp "Linger deaktivieren (Autostart abschalten)? [j/N]: " a || true
    if [[ "${a,,}" == "j" ]]; then
        sudo loginctl disable-linger "$USER" 2>/dev/null && ok "Linger deaktiviert." \
            || warn "Konnte Linger nicht deaktivieren (evtl. sudo nötig)."
    fi
    echo; ok "Vollständig deinstalliert."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
do_status() {
    echo "${B}== Status ==${N}"
    local any=0
    for s in "${SERVICES[@]}"; do
        if [ -f "$UNIT_DIR/$s" ]; then
            any=1
            local act; act="$(systemctl --user is-active "$s" 2>/dev/null)"
            local en;  en="$(systemctl --user is-enabled "$s" 2>/dev/null)"
            if [ "$act" = "active" ]; then ok "$s – $act ($en)"; else bad "$s – ${act:-inaktiv} ($en)"; fi
        fi
    done
    [ "$any" = 0 ] && warn "Nicht installiert."
    if [ -f "$CONF" ]; then
        . "$CONF" 2>/dev/null
        local sch="http"; [ "${VLLM_HTTPS:-n}" = "j" ] && sch="https"
        echo "  ${DIM}Ziel: ${VLLM_HOST:-?}  URL: ${sch}://…:${VLLM_PORT:-?}  Bind: ${VLLM_BIND:-?}${N}"
    fi
    [ -f "$CERT" ] && ok "TLS-Zertifikat vorhanden ($CERT)" || echo "  ${DIM}Kein TLS-Zertifikat.${N}"
    echo "  ${DIM}Version: $(ver_of < "$DIR/vllm_dashboard.sh")${N}"
    if [ -f "$UNIT_DIR/$UPD_UNIT.timer" ]; then
        ok "Auto-Update: $(sed -n 's/^OnCalendar=//p' "$UNIT_DIR/$UPD_UNIT.timer")" \
           "– nächster Lauf: $(systemctl --user show -p NextElapseUSecRealtime --value "$UPD_UNIT.timer" 2>/dev/null)"
    else
        echo "  ${DIM}Auto-Update aus.${N}"
    fi
    [ -f "$UPD_STATUS" ] && [ -n "$PY" ] && "$PY" - "$UPD_STATUS" <<'EOF' 2>/dev/null
import json, sys, time
st = json.load(open(sys.argv[1], encoding="utf-8"))
if st.get("ts"):
    print("  Letzter Update-Lauf %s: %s%s" % (time.strftime("%d.%m.%Y %H:%M", time.localtime(st["ts"])),
          "" if st.get("ok") else "FEHLER – ", st.get("message", "")))
EOF
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
menu() {
    while true; do
        echo
        echo "${B}############################################${N}"
        echo "${B}#   vLLM Monitor – Setup                   #${N}"
        echo "${B}############################################${N}"
        echo "  1) Installieren"
        echo "  2) Deinstallieren (vollständig)"
        echo "  3) Status anzeigen"
        echo "  4) Abhängigkeiten prüfen"
        echo "  5) TLS-Zertifikat (neu) erzeugen"
        echo "  6) Aktualisieren (neue Version von GitHub)"
        echo "  7) Automatisches Update einrichten/ändern"
        echo "  0) Beenden"
        local c ipp; read -rp "Auswahl: " c || exit 0
        echo
        case "$c" in
            1) do_install; pause;;
            2) do_uninstall; pause;;
            3) do_status; pause;;
            4) check_deps; pause;;
            5) [ -f "$CONF" ] && . "$CONF" 2>/dev/null
               ipp="$(ask "IP/Hostname für das Zertifikat" "${VLLM_HOST:-127.0.0.1}")"; gen_cert "$ipp"
               warn "Nach dem Erzeugen ggf. neu installieren (Punkt 1) und HTTPS wählen."; pause;;
            6) do_update; pause;;
            7) do_autoupdate_cfg; pause;;
            0) exit 0;;
            *) warn "Ungültige Auswahl.";;
        esac
    done
}

case "${1:-}" in
    install)     do_install ;;
    update)      do_update ;;
    auto-update) do_auto_update ;;
    status)      do_status ;;
    uninstall)   do_uninstall ;;
    "")          menu ;;
    *) echo "Aufruf: $0 [install|update|auto-update|status|uninstall]   (ohne Argument: Menü)"; exit 1 ;;
esac
