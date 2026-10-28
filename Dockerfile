# vLLM Monitor – Container-Image (Debian 13 „trixie")
#
# Ein Image, zwei Container: Collector und Dashboard teilen sich das
# Datenverzeichnis /data (SQLite-DB, auth.json, settings.json, targets.json,
# prefs.json, TLS-Zertifikat, Reports). Installation/Betrieb: ./docker_setup.sh
#
FROM debian:trixie-slim

# Label: docker_setup.sh räumt darüber alte, unbenannte Builds ab
LABEL org.opencontainers.image.title="vllm-monitor"

# python3 genügt (nur Standardbibliothek); tzdata, damit die Kalendertage
# (kWh/Tag, Tokens/Tag) in der Zeitzone des Betreibers geschnitten werden,
# openssl für die Zertifikatserzeugung im Container.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 tzdata openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG UID=10001
RUN groupadd --system --gid "$UID" monitor \
 && useradd --system --uid "$UID" --gid "$UID" --home-dir /data --shell /usr/sbin/nologin monitor \
 && mkdir -p /app /data && chown monitor:monitor /data

COPY vllm_collector.sh vllm_dashboard.sh monitor.sh scan_for_llms.sh /app/
COPY docker/entrypoint.sh /app/docker-entrypoint.sh
RUN chmod 755 /app/*.sh

# Alle Laufzeitdateien liegen unter /data, nicht neben den Skripten
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=Europe/Berlin \
    VLLM_DB=/data/vllm_metrics.db \
    VLLM_TARGETS_FILE=/data/targets.json \
    VLLM_SETTINGS_FILE=/data/settings.json \
    VLLM_PREFS_FILE=/data/prefs.json \
    VLLM_AUTH_FILE=/data/auth.json \
    VLLM_REPORT_DIR=/data/reports \
    VLLM_DASH_PORT=8899 \
    VLLM_DASH_BIND=0.0.0.0

USER monitor
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8899

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["dashboard"]
