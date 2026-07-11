#!/usr/bin/env bash
#
# setup.sh – Interaktives Installations-/Deinstallationsmenü für vLLM Monitor.
#
# Einfach ausführen:   ./setup.sh
#
# Richtet die beiden systemd-User-Dienste (Collector + Dashboard) ein,
# prüft die Abhängigkeiten und kann alles wieder vollständig entfernen.
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
gen_cert() {  # $1 = IP/Hostname für den Common Name / SAN
    local ip="$1"
    if ! command -v openssl >/dev/null 2>&1; then
        bad "openssl nicht gefunden – kann kein Zertifikat erzeugen."; return 1
    fi
    local san="IP:127.0.0.1,DNS:localhost"
    if valid_ip "$ip"; then san="IP:$ip,$san"; else san="DNS:$ip,$san"; fi
    if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CERT" -days 3650 \
        -subj "/CN=$ip" -addext "subjectAltName=$san" 2>/dev/null; then
        chmod 600 "$KEY"; chmod 644 "$CERT"
        ok "Self-signed Zertifikat erzeugt (SAN: $san), 10 Jahre gültig."
    else
        bad "Zertifikat-Erzeugung fehlgeschlagen."; return 1
    fi
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
    local D_DCGM="${VLLM_DCGM:-}"
    local D_AI_URL="${VLLM_AI_URL:-}"
    local D_AI_MODEL="${VLLM_AI_MODEL:-}"
    local D_REPORT="${VLLM_REPORT:-}"

    echo
    local ip targets bind port https="n" ans ollama stt dcgm ai_url ai_model report_when
    while true; do
        ip="$(ask "Ziel-IP des vLLM-Hosts" "$D_IP")"
        if valid_ip "$ip"; then break; fi
        bad "Ungültige IP-Adresse – bitte erneut."
    done
    targets="$(ask "vLLM-Instanzen (port:label,port:label)" "$D_TARGETS")"
    ollama="$(ask "Ollama-Instanz(en)? host:port:label (leer=keine, Autoscan bleibt aktiv)" "$D_OLLAMA")"
    stt="$(ask "STT-Server (faster-whisper)? host:port:label (leer=keiner)" "$D_STT")"
    dcgm="$(ask "NVIDIA DCGM-Exporter (GPU)? host:port (leer=keiner)" "$D_DCGM")"
    ai_url="$(ask "KI-Auswertung: Chat-Endpunkt (host:port o. .../v1/chat/completions, leer=aus)" "$D_AI_URL")"
    ai_model=""
    [ -n "$ai_url" ] && ai_model="$(ask "KI-Modell (Name lt. /v1/models)" "$D_AI_MODEL")"
    report_when=""
    [ -n "$ai_url" ] && report_when="$(ask "Geplanter KI-Schicht-Report? systemd OnCalendar (z.B. '*-*-* 06,14,22:00', leer=aus)" "$D_REPORT")"
    bind="$(ask "Dashboard-Bind (0.0.0.0=Netz, 127.0.0.1=nur lokal)" "$D_BIND")"
    port="$(ask "Dashboard-Port" "$D_PORT")"
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
    cat > "$CONF" <<EOF
VLLM_HOST=$ip
VLLM_TARGETS=$targets
VLLM_OLLAMA=$ollama
VLLM_STT=$stt
VLLM_DCGM=$dcgm
VLLM_AI_URL=$ai_url
VLLM_AI_MODEL=$ai_model
VLLM_REPORT=$report_when
VLLM_BIND=$bind
VLLM_PORT=$port
VLLM_HTTPS=$https
EOF

    mkdir -p "$UNIT_DIR"

    local ollama_env=""
    [ -n "$ollama" ] && ollama_env="Environment=VLLM_OLLAMA_TARGETS=$ollama"$'\n'"Environment=VLLM_OLLAMA_PROBE=1"
    local stt_env=""
    [ -n "$stt" ] && stt_env="Environment=VLLM_STT_TARGETS=$stt"
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
${dcgm_env}
ExecStart=$PY $DIR/vllm_collector.sh loop
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

    local tls_env=""
    [ "$https" = "j" ] && tls_env="Environment=VLLM_TLS_CERT=$CERT"$'\n'"Environment=VLLM_TLS_KEY=$KEY"
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
    [ "$bind" = "0.0.0.0" ] && warn "Ohne Auth im Netz erreichbar – ggf. per Firewall einschränken."
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
    systemctl --user disable --now vllm-report.timer 2>/dev/null
    for s in "${SERVICES[@]}"; do rm -f "$UNIT_DIR/$s"; done
    rm -f "$UNIT_DIR/vllm-report.service" "$UNIT_DIR/vllm-report.timer"
    systemctl --user daemon-reload
    systemctl --user reset-failed "${SERVICES[@]}" vllm-report.timer 2>/dev/null
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
            0) exit 0;;
            *) warn "Ungültige Auswahl.";;
        esac
    done
}

menu
