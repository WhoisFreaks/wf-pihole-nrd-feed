#!/bin/bash
# fetch-nrd.sh — Rolling-window NRD feed fetcher for Pi-hole
#
# Behavior:
#   - Caches each day's NRD download as a separate file in $CACHE_DIR
#   - Only downloads days that aren't already cached (idempotent)
#   - Rebuilds $OUTPUT from the last $WINDOW_DAYS of cached files
#   - Prunes cache files older than the window
#   - Auto-subscribes Pi-hole to the feed URL on first run (if AUTO_SUBSCRIBE=true)
#   - Triggers Pi-hole gravity reload after successful rebuild

set -euo pipefail

# --- Configuration ---
API_KEY_FILE="${API_KEY_FILE:-/etc/whoisfreaks/apikey}"
FEED_DIR="${FEED_DIR:-/var/feed}"
CACHE_DIR="${CACHE_DIR:-${FEED_DIR}/cache}"
OUTPUT="${OUTPUT:-${FEED_DIR}/nrd.txt}"
WINDOW_DAYS="${WINDOW_DAYS:-10}"
FEED_TYPES="${FEED_TYPES:-gtld cctld}"
PIHOLE_CONTAINER="${PIHOLE_CONTAINER:-pihole}"
TRIGGER_GRAVITY="${TRIGGER_GRAVITY:-true}"
AUTO_SUBSCRIBE="${AUTO_SUBSCRIBE:-true}"
FEED_URL="${FEED_URL:-http://feed-server/nrd.txt}"
FEED_COMMENT="${FEED_COMMENT:-WhoisFreaks NRD (auto-added)}"

# --- Validation ---
if ! [[ "$WINDOW_DAYS" =~ ^[0-9]+$ ]] || [[ "$WINDOW_DAYS" -lt 1 ]]; then
  echo "ERROR: WINDOW_DAYS must be a positive integer, got: $WINDOW_DAYS" >&2
  exit 1
fi

if [[ ! -r "$API_KEY_FILE" ]]; then
  echo "ERROR: API key file not readable: $API_KEY_FILE" >&2
  exit 1
fi
API_KEY="$(cat "$API_KEY_FILE")"

mkdir -p "$CACHE_DIR"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

log "Starting NRD fetch | window=${WINDOW_DAYS}d | feeds=${FEED_TYPES}"

# --- Build the list of dates we need (yesterday back through WINDOW_DAYS days) ---
WANTED_DATES=()
for ((i=1; i<=WINDOW_DAYS; i++)); do
  WANTED_DATES+=("$(date -u -d "${i} days ago" +%Y-%m-%d)")
done

# --- Fetch missing days ---
NEW_DOWNLOADS=0
FAILED_FETCHES=0
for date in "${WANTED_DATES[@]}"; do
  for feed in $FEED_TYPES; do
    cache_file="${CACHE_DIR}/${date}_${feed}.txt"

    if [[ -s "$cache_file" ]]; then
      continue
    fi

    log "  fetching ${feed} for ${date}"
    url="https://files.whoisfreaks.com/v3.1/download/domainer/${feed}?apiKey=${API_KEY}&date=${date}&whois=false"

    tmp_gz="$(mktemp)"
    tmp_txt="$(mktemp)"

    if curl -sS --fail --max-time 300 -o "$tmp_gz" "$url"; then
      if zcat "$tmp_gz" \
           | tr -d '\r' \
           | tr '[:upper:]' '[:lower:]' \
           | grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' \
           | sort -u > "$tmp_txt" \
         && [[ -s "$tmp_txt" ]]; then
        mv "$tmp_txt" "$cache_file"
        NEW_DOWNLOADS=$((NEW_DOWNLOADS + 1))
        log "    cached $(wc -l < "$cache_file") domains -> $(basename "$cache_file")"
      else
        log "    WARN: ${feed}/${date} returned empty or invalid data"
        FAILED_FETCHES=$((FAILED_FETCHES + 1))
        rm -f "$tmp_txt"
      fi
    else
      log "    WARN: fetch failed for ${feed}/${date}"
      FAILED_FETCHES=$((FAILED_FETCHES + 1))
    fi

    rm -f "$tmp_gz"
  done
done

# --- Prune cache files outside the window ---
KEEP_PATTERN="$(IFS='|'; echo "${WANTED_DATES[*]}")"
PRUNED=0
shopt -s nullglob
for f in "${CACHE_DIR}"/*.txt; do
  basename="$(basename "$f")"
  file_date="${basename:0:10}"
  if ! [[ "$file_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    continue
  fi
  if ! [[ "|${KEEP_PATTERN}|" == *"|${file_date}|"* ]]; then
    rm -f "$f"
    PRUNED=$((PRUNED + 1))
  fi
done
shopt -u nullglob

if [[ "$PRUNED" -gt 0 ]]; then
  log "Pruned ${PRUNED} cache file(s) outside the ${WINDOW_DAYS}-day window"
fi

# --- Rebuild the combined output file from cache ---
PREVIOUS_HASH=""
if [[ -f "$OUTPUT" ]]; then
  PREVIOUS_HASH="$(sha256sum "$OUTPUT" | awk '{print $1}')"
fi

if compgen -G "${CACHE_DIR}/*.txt" > /dev/null; then
  cat "${CACHE_DIR}"/*.txt | sort -u > "${OUTPUT}.tmp"
  mv "${OUTPUT}.tmp" "$OUTPUT"
  log "Rebuilt ${OUTPUT} with $(wc -l < "$OUTPUT") unique domains (new: ${NEW_DOWNLOADS}, failed: ${FAILED_FETCHES})"
else
  log "ERROR: no cache files found, nothing to write" >&2
  exit 1
fi

# --- Wait for Pi-hole to be ready ---
# On a fresh `docker compose up`, Pi-hole takes 10-30s to initialize gravity.db.
# Without this wait, our first-run subscribe/gravity calls race and fail.
wait_for_pihole() {
  local max_attempts=30   # 30 attempts * 2s = 60s max wait
  local attempt=0
  while (( attempt < max_attempts )); do
    if docker exec "$PIHOLE_CONTAINER" test -f /etc/pihole/gravity.db 2>/dev/null \
       && docker exec "$PIHOLE_CONTAINER" pihole-FTL sqlite3 /etc/pihole/gravity.db \
            "SELECT 1 FROM adlist LIMIT 1;" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

if [[ "$AUTO_SUBSCRIBE" == "true" ]] || [[ "$TRIGGER_GRAVITY" == "true" ]]; then
  if [[ ! -S /var/run/docker.sock ]]; then
    log "WARN: /var/run/docker.sock not mounted, skipping Pi-hole integration"
    exit 0
  fi

  log "Waiting for Pi-hole to be ready..."
  if ! wait_for_pihole; then
    log "WARN: Pi-hole did not become ready in time, skipping subscribe + gravity"
    log "      Cron will retry on next tick; or run 'docker exec ${PIHOLE_CONTAINER} pihole -g' manually"
    exit 0
  fi
  log "Pi-hole is ready"
fi

# --- Auto-subscribe Pi-hole to our feed URL (only if not already subscribed) ---
if [[ "$AUTO_SUBSCRIBE" == "true" ]]; then
  EXISTS=$(docker exec "$PIHOLE_CONTAINER" pihole-FTL sqlite3 /etc/pihole/gravity.db \
    "SELECT COUNT(*) FROM adlist WHERE address = '${FEED_URL}';" 2>/dev/null || echo "0")

  if [[ "$EXISTS" == "0" ]]; then
    log "Subscribing Pi-hole to ${FEED_URL}"
    NOW=$(date +%s)
    # type=0 means blocklist (1 would be allowlist)
    if docker exec "$PIHOLE_CONTAINER" pihole-FTL sqlite3 /etc/pihole/gravity.db \
        "INSERT INTO adlist (address, enabled, date_added, date_modified, comment, type)
         VALUES ('${FEED_URL}', 1, ${NOW}, ${NOW}, '${FEED_COMMENT}', 0);" 2>/dev/null; then
      log "Subscribed successfully"
    else
      log "WARN: failed to subscribe (Pi-hole schema may differ); add the URL manually in the UI"
    fi
  else
    log "Pi-hole already subscribed to ${FEED_URL}, skipping"
  fi
fi

# --- Trigger gravity reload (skip if file is byte-identical to previous run) ---
NEW_HASH="$(sha256sum "$OUTPUT" | awk '{print $1}')"

if [[ "$TRIGGER_GRAVITY" != "true" ]]; then
  log "TRIGGER_GRAVITY=false, skipping gravity reload"
  exit 0
fi

# Reload if file changed OR we just subscribed (need at least one reload to pick up new list)
if [[ "$NEW_HASH" == "$PREVIOUS_HASH" ]] && [[ "${EXISTS:-1}" != "0" ]]; then
  log "nrd.txt unchanged and already subscribed, skipping gravity reload"
  exit 0
fi

log "Triggering gravity reload on container '${PIHOLE_CONTAINER}'"
if docker exec "$PIHOLE_CONTAINER" pihole -g > /tmp/gravity.log 2>&1; then
  GRAVITY_TOTAL=$(grep -oE '[0-9,]+ unique domains' /tmp/gravity.log | tail -1 || echo "unknown count")
  log "Gravity reload complete: ${GRAVITY_TOTAL}"
else
  log "ERROR: gravity reload failed, see /tmp/gravity.log"
  tail -20 /tmp/gravity.log | sed 's/^/    /'
  exit 1
fi

exit 0
