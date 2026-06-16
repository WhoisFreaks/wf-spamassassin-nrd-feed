#!/usr/bin/env bash
# wf-nrd-fetch.sh — WhoisFreaks NRD feed fetcher for SpamAssassin
# Fetches daily gTLD + ccTLD files, maintains a rolling-window cache,
# and atomically rebuilds the SpamAssassin domain list file.
#
# Compatible with: Ubuntu, Debian, RHEL, CentOS, Rocky, Alma, Fedora,
#                  openSUSE, Arch Linux — any Linux with bash + GNU/BSD date.
#
# Usage:
#   WINDOW_DAYS=10 /usr/local/bin/wf-nrd-sa-fetch.sh
#
# Environment:
#   WINDOW_DAYS    Number of days to keep in the rolling window (default: 10)
#   API_KEY_FILE   Path to the file containing the WhoisFreaks API key
#                  (default: /etc/whoisfreaks/apikey)

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
WINDOW_DAYS="${WINDOW_DAYS:-10}"
API_KEY_FILE="${API_KEY_FILE:-/etc/whoisfreaks/apikey}"
CACHE_DIR="/var/cache/wf-nrd"
LIST_FILE="/var/lib/spamassassin/nrd/nrd_domains.list"
BASE_URL="https://api.whoisfreaks.com/v1.0/nrd"
LOG_TAG="[wf-nrd-sa]"

# ── Validate ───────────────────────────────────────────────────────────────────
if [[ ! -f "$API_KEY_FILE" ]]; then
  echo "$LOG_TAG ERROR: API key file not found at $API_KEY_FILE" >&2
  echo "$LOG_TAG Run: echo 'YOUR_KEY' | sudo tee $API_KEY_FILE && sudo chmod 600 $API_KEY_FILE" >&2
  exit 1
fi

API_KEY=$(cat "$API_KEY_FILE")
if [[ -z "$API_KEY" ]]; then
  echo "$LOG_TAG ERROR: API key file is empty." >&2
  exit 1
fi

# ── POSIX-compatible date arithmetic ──────────────────────────────────────────
# Works on GNU coreutils (Linux) and BSD date (macOS/FreeBSD).
# Usage: date_offset <YYYY-MM-DD> <days_ago>  => prints YYYY-MM-DD
date_offset() {
  local base="$1"
  local days_ago="$2"

  # Try GNU date first (Linux standard)
  if date --version >/dev/null 2>&1; then
    date -u -d "${base} - ${days_ago} days" +%Y-%m-%d
  else
    # BSD date fallback (macOS, FreeBSD)
    date -u -v "-${days_ago}d" -j -f "%Y-%m-%d" "$base" +%Y-%m-%d
  fi
}

# ── Setup ──────────────────────────────────────────────────────────────────────
mkdir -p "$CACHE_DIR"
mkdir -p "$(dirname "$LIST_FILE")"

TODAY=$(date -u +%Y-%m-%d)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "$LOG_TAG Starting NRD fetch | window: ${WINDOW_DAYS} days | date: $TODAY"

# ── Fetch daily files ──────────────────────────────────────────────────────────
fetch_day() {
  local date_str="$1"
  local gtld_cache="$CACHE_DIR/gtld_${date_str}.txt"
  local cctld_cache="$CACHE_DIR/cctld_${date_str}.txt"

  # gTLD
  if [[ ! -f "$gtld_cache" ]]; then
    local gtld_gz="$WORK_DIR/gtld_${date_str}.gz"
    if curl -sf --max-time 60 \
        "${BASE_URL}?whoisFreaksApiKey=${API_KEY}&domainType=gtld&date=${date_str}" \
        -o "$gtld_gz"; then
      gunzip -c "$gtld_gz" | grep -v '^#' | grep -v '^[[:space:]]*$' \
        | tr '[:upper:]' '[:lower:]' > "$gtld_cache"
      echo "$LOG_TAG  Fetched gTLD  $date_str ($(wc -l < "$gtld_cache") domains)"
    else
      echo "$LOG_TAG  WARN: gTLD $date_str not available — skipping" >&2
      touch "$gtld_cache"
    fi
  fi

  # ccTLD
  if [[ ! -f "$cctld_cache" ]]; then
    local cctld_gz="$WORK_DIR/cctld_${date_str}.gz"
    if curl -sf --max-time 60 \
        "${BASE_URL}?whoisFreaksApiKey=${API_KEY}&domainType=cctld&date=${date_str}" \
        -o "$cctld_gz"; then
      gunzip -c "$cctld_gz" | grep -v '^#' | grep -v '^[[:space:]]*$' \
        | tr '[:upper:]' '[:lower:]' > "$cctld_cache"
      echo "$LOG_TAG  Fetched ccTLD $date_str ($(wc -l < "$cctld_cache") domains)"
    else
      echo "$LOG_TAG  WARN: ccTLD $date_str not available — skipping" >&2
      touch "$cctld_cache"
    fi
  fi
}

for i in $(seq 0 $((WINDOW_DAYS - 1))); do
  fetch_day "$(date_offset "$TODAY" "$i")"
done

# ── Purge old cache files outside the window ───────────────────────────────────
find "$CACHE_DIR" -name "*.txt" -mtime "+${WINDOW_DAYS}" -delete 2>/dev/null || true

# ── Merge cached files into a single sorted+deduped domain list ───────────────
MERGED="$WORK_DIR/merged.list"
cat "$CACHE_DIR"/*.txt 2>/dev/null \
  | grep -v '^[[:space:]]*$' \
  | sort -u \
  > "$MERGED"

DOMAIN_COUNT=$(wc -l < "$MERGED")
echo "$LOG_TAG Merged list: $DOMAIN_COUNT unique domains"

# ── Atomic replace ─────────────────────────────────────────────────────────────
TEMP_LIST="${LIST_FILE}.tmp.$$"
cp "$MERGED" "$TEMP_LIST"
mv -f "$TEMP_LIST" "$LIST_FILE"
chmod 644 "$LIST_FILE"

echo "$LOG_TAG List file updated: $LIST_FILE ($DOMAIN_COUNT domains)"

# ── Reload SpamAssassin ────────────────────────────────────────────────────────
# spamd reads the list file at startup and on SIGHUP.
# Try systemctl first (systemd distros), then fall back to PID file.
# Service name varies by distro: 'spamassassin' on Debian/Ubuntu/RHEL/Arch,
# 'spamd' on some openSUSE and older setups.
_reload_spamd() {
  for svc in spamassassin spamd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      systemctl kill --kill-who=main --signal=SIGHUP "$svc"
      echo "$LOG_TAG Sent SIGHUP to $svc (systemd) — list reloaded"
      return 0
    fi
  done

  # Fallback: PID file locations across distros
  for pidfile in /var/run/spamd.pid /run/spamd/spamd.pid \
                 /var/run/spamassassin/spamd.pid /run/spamassassin.pid; do
    if [[ -f "$pidfile" ]]; then
      kill -HUP "$(cat "$pidfile")" 2>/dev/null && \
        echo "$LOG_TAG Sent SIGHUP to spamd via $pidfile" && return 0
    fi
  done

  echo "$LOG_TAG WARN: spamd not running; list will be loaded on next start" >&2
  return 0
}

_reload_spamd

echo "$LOG_TAG Done."