#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/opt/bbb/config/.env}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/opt/bbb/config/rclone.conf}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
RCLONE_SERVE_ADDR="${RCLONE_SERVE_ADDR:-127.0.0.1:8081}"
RCLONE_SERVE_CACHE_MODE="${RCLONE_SERVE_CACHE_MODE:-full}"
RCLONE_SERVE_CACHE_DIR="${RCLONE_SERVE_CACHE_DIR:-/var/cache/bbb-rclone}"
RCLONE_SERVE_CACHE_MAX_SIZE="${RCLONE_SERVE_CACHE_MAX_SIZE:-50G}"
RCLONE_SERVE_CACHE_MAX_AGE="${RCLONE_SERVE_CACHE_MAX_AGE:-72h}"
RCLONE_SERVE_CACHE_POLL_INTERVAL="${RCLONE_SERVE_CACHE_POLL_INTERVAL:-1m}"

if [[ ! -r "$ENV_FILE" ]]; then
    echo "Missing environment file: $ENV_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${GDRIVE_FOLDER_ID:?GDRIVE_FOLDER_ID is required}"

export RCLONE_CONFIG_GDRIVE_ROOT_FOLDER_ID="$GDRIVE_FOLDER_ID"

exec rclone serve http "$RCLONE_REMOTE:" \
    --config="$RCLONE_CONFIG" \
    --addr="$RCLONE_SERVE_ADDR" \
    --read-only \
    --cache-dir="$RCLONE_SERVE_CACHE_DIR" \
    --vfs-cache-mode="$RCLONE_SERVE_CACHE_MODE" \
    --vfs-cache-max-size="$RCLONE_SERVE_CACHE_MAX_SIZE" \
    --vfs-cache-max-age="$RCLONE_SERVE_CACHE_MAX_AGE" \
    --vfs-cache-poll-interval="$RCLONE_SERVE_CACHE_POLL_INTERVAL"
