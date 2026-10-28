#!/bin/sh
#
# Einstiegspunkt des vLLM-Monitor-Containers.
#
#   dashboard            Dashboard auf $VLLM_DASH_BIND:$VLLM_DASH_PORT (Default)
#   collector            Collector (Dauerschleife, 15-s-Pull)
#   report [sekunden]    KI-Schicht-Report nach $VLLM_REPORT_DIR schreiben
#   annotate "label" [ts]
#   health-dashboard     Healthcheck: Dashboard antwortet auf /
#   health-collector     Healthcheck: Heartbeat in collector_status ist frisch
#   <sonstiges>          wird unverändert ausgeführt (z. B. sh, python3 …)
#
set -e

cmd="${1:-dashboard}"
[ $# -gt 0 ] && shift

case "$cmd" in
    dashboard)
        exec python3 /app/vllm_dashboard.sh "${VLLM_DASH_PORT:-8899}" "${VLLM_DASH_BIND:-0.0.0.0}"
        ;;
    collector)
        exec python3 /app/vllm_collector.sh loop
        ;;
    once|status)
        exec python3 /app/vllm_collector.sh "$cmd"
        ;;
    report|annotate)
        exec python3 /app/vllm_dashboard.sh "$cmd" "$@"
        ;;
    health-dashboard)
        exec python3 - <<'EOF'
import os, ssl, sys, urllib.request
port = os.environ.get("VLLM_DASH_PORT", "8899")
bind = os.environ.get("VLLM_DASH_BIND", "0.0.0.0")
host = "127.0.0.1" if bind in ("", "0.0.0.0") else bind
tls = bool(os.environ.get("VLLM_TLS_CERT") and os.environ.get("VLLM_TLS_KEY")
           and os.path.exists(os.environ["VLLM_TLS_CERT"]))
url = "%s://%s:%s/" % ("https" if tls else "http", host, port)
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    urllib.request.urlopen(url, timeout=5, context=ctx if tls else None).read(64)
except Exception as e:
    print("Dashboard nicht erreichbar: %s" % e)
    sys.exit(1)
EOF
        ;;
    health-collector)
        exec python3 - <<'EOF'
import os, sqlite3, sys, time
interval = int(os.environ.get("VLLM_INTERVAL", "15"))
try:
    conn = sqlite3.connect("file:%s?mode=ro" % os.environ["VLLM_DB"], uri=True, timeout=5)
    ts = conn.execute("SELECT ts FROM collector_status WHERE id=1").fetchone()[0]
except Exception as e:
    print("Kein Heartbeat: %s" % e)
    sys.exit(1)
age = time.time() - ts
if age > max(120, 4 * interval):
    print("Heartbeat veraltet (%d s)" % age)
    sys.exit(1)
EOF
        ;;
    *)
        exec "$cmd" "$@"
        ;;
esac
