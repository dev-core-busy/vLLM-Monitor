#!/usr/bin/env bash
#
# setup.sh – Installiert/Deinstalliert vLLM Monitor als systemd-User-Dienste.
#
#   ./setup.sh install <ZIEL-IP> [targets] [bind] [port]
#   ./setup.sh uninstall
#   ./setup.sh status
#
#   targets  Standard "8000:default"; Format "port:label,port:label"
#   bind     Standard "0.0.0.0" (netzwerkweit); "127.0.0.1" = nur lokal
#   port     Dashboard-Port, Standard 8899
#
# Beispiel:
#   ./setup.sh install 10.0.0.5 "9081:Qwen,9082:Gemma" 0.0.0.0 8899
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
PY="$(command -v python3 || true)"
SERVICES=(vllm-collector.service vllm-dashboard.service)

die() { echo "Fehler: $*" >&2; exit 1; }

do_install() {
    local ip="${1:-}"
    [ -n "$ip" ] || die "Ziel-IP fehlt.  Aufruf: ./setup.sh install <ZIEL-IP> [targets] [bind] [port]"
    [ -n "$PY" ] || die "python3 nicht gefunden."
    local targets="${2:-8000:default}"
    local bind="${3:-0.0.0.0}"
    local port="${4:-8899}"

    mkdir -p "$UNIT_DIR"

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
ExecStart=$PY $DIR/vllm_collector.sh loop
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

    cat > "$UNIT_DIR/vllm-dashboard.service" <<EOF
[Unit]
Description=vLLM Monitoring-Dashboard (Port $port)
After=vllm-collector.service

[Service]
Type=simple
WorkingDirectory=$DIR
Environment=VLLM_LABEL=$ip
ExecStart=$PY $DIR/vllm_dashboard.sh $port $bind
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "${SERVICES[@]}"

    # Autostart ohne aktive Sitzung (best effort – braucht i.d.R. sudo)
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        sudo loginctl enable-linger "$USER" 2>/dev/null \
            && echo "Linger aktiviert (Autostart nach Reboot)." \
            || echo "Hinweis: 'sudo loginctl enable-linger $USER' manuell ausführen für Autostart nach Reboot."
    fi

    local shown="$bind"; [ "$bind" = "0.0.0.0" ] && shown="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo
    echo "Installiert. Ziel: $ip  Targets: $targets"
    echo "Dashboard:  http://${shown:-127.0.0.1}:$port"
    [ "$bind" = "0.0.0.0" ] && echo "  [!] Ohne Auth im Netz erreichbar – ggf. per Firewall einschränken."
}

do_uninstall() {
    systemctl --user disable --now "${SERVICES[@]}" 2>/dev/null || true
    for s in "${SERVICES[@]}"; do rm -f "$UNIT_DIR/$s"; done
    systemctl --user daemon-reload
    echo "Deinstalliert. Dienste gestoppt und Unit-Dateien entfernt."
    echo "Hinweis: Messdaten in $DIR/vllm_metrics.db bleiben erhalten (bei Bedarf manuell löschen)."
}

case "${1:-help}" in
    install)   shift; do_install "$@";;
    uninstall) do_uninstall;;
    status)    systemctl --user --no-pager status "${SERVICES[@]}" || true;;
    *)         sed -n '3,20p' "$0";;
esac
