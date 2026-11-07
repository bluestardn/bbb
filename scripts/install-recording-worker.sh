#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/bbb}"
SYSTEMD_DIR="/etc/systemd/system"
ENV_FILE="$INSTALL_ROOT/config/.env"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this installer as root." >&2
    exit 1
fi

for command_name in curl flock jq python3 rclone sha256sum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 1
    fi
done

if [[ ! -s "$ENV_FILE" || ! -s "$INSTALL_ROOT/config/rclone.conf" ]]; then
    echo "Configure $INSTALL_ROOT/config/.env and rclone.conf first." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

RCLONE_SERVE_CACHE_DIR="${RCLONE_SERVE_CACHE_DIR:-/var/cache/bbb-rclone}"

chgrp bigbluebutton "$INSTALL_ROOT/config"
chmod 0770 "$INSTALL_ROOT/config"
chown bigbluebutton:bigbluebutton \
    "$ENV_FILE" \
    "$INSTALL_ROOT/config/rclone.conf"
chmod 0640 "$ENV_FILE" "$INSTALL_ROOT/config/rclone.conf"
chgrp bigbluebutton \
    "$INSTALL_ROOT/scripts/sync-recordings.sh" \
    "$INSTALL_ROOT/scripts/serve-recordings.sh"
chmod 0750 "$INSTALL_ROOT/scripts/sync-recordings.sh"
chmod 0750 "$INSTALL_ROOT/scripts/serve-recordings.sh"

install -o root -g root -m 0644 \
    "$INSTALL_ROOT/config/bbb-recording-sync.service" \
    "$SYSTEMD_DIR/bbb-recording-sync.service"
install -o root -g root -m 0644 \
    "$INSTALL_ROOT/config/bbb-recording-sync.timer" \
    "$SYSTEMD_DIR/bbb-recording-sync.timer"
install -o root -g root -m 0644 \
    "$INSTALL_ROOT/config/rclone-serve-gdrive.service" \
    "$SYSTEMD_DIR/rclone-serve-gdrive.service"
rm -f /etc/bigbluebutton/nginx/recording-playback.nginx

if ! grep -Rqs 'location /presentation/' \
    /etc/bigbluebutton/nginx /usr/share/bigbluebutton/nginx; then
    install -o root -g root -m 0644 \
        "$INSTALL_ROOT/config/recording-playback.nginx" \
        /etc/bigbluebutton/nginx/recording-playback.nginx
fi

install -d -o bigbluebutton -g bigbluebutton -m 0750 \
    "$INSTALL_ROOT/config/recording-state"
install -d -o bigbluebutton -g bigbluebutton -m 0750 \
    "$RCLONE_SERVE_CACHE_DIR"

nginx -t
systemctl daemon-reload
systemctl enable --now rclone-serve-gdrive.service
systemctl reload nginx
systemctl enable --now bbb-recording-sync.timer
systemctl start bbb-recording-sync.service

systemctl --no-pager --full status bbb-recording-sync.timer
