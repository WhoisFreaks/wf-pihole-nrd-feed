#!/bin/bash
# entrypoint.sh — Sets up cron inside the fetcher container.
# Runs the fetch script once at startup, then schedules it via cron.
# Cron lives and dies with this container.

set -euo pipefail

CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * *}"
SCRIPT_PATH="/var/feed/fetch-nrd.sh"
LOG_FILE="/var/log/nrd-fetcher.log"

echo "[entrypoint] Installing dependencies"
# docker-cli is needed so the fetcher can trigger 'pihole -g' on the pihole container
apk add --no-cache --quiet bash curl coreutils tzdata busybox-suid docker-cli >/dev/null

chmod +x "$SCRIPT_PATH"
touch "$LOG_FILE"

echo "[entrypoint] Running initial fetch on startup"
env > /etc/environment
"$SCRIPT_PATH" 2>&1 | tee -a "$LOG_FILE" || echo "[entrypoint] WARN: initial fetch failed, will retry on schedule"

echo "[entrypoint] Installing cron schedule: ${CRON_SCHEDULE}"
cat > /etc/crontabs/root <<EOF
# NRD feed fetcher — runs on schedule, logs to ${LOG_FILE}
${CRON_SCHEDULE} . /etc/environment; ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1
EOF

# Graceful shutdown: kill crond cleanly when the container receives SIGTERM
shutdown() {
  echo "[entrypoint] Received shutdown signal, stopping cron"
  if [[ -n "${CROND_PID:-}" ]]; then
    kill -TERM "$CROND_PID" 2>/dev/null || true
    wait "$CROND_PID" 2>/dev/null || true
  fi
  echo "[entrypoint] Cron stopped, exiting"
  exit 0
}
trap shutdown SIGTERM SIGINT

echo "[entrypoint] Starting crond in foreground"
crond -f -L "$LOG_FILE" -l 8 &
CROND_PID=$!

tail -F "$LOG_FILE" &
TAIL_PID=$!

wait "$CROND_PID"
