#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/opt/bbb/config/.env}"
LOCAL_REC_DIR="${LOCAL_REC_DIR:-/var/bigbluebutton/published/presentation}"
PUBLISHED_STATUS_DIR="${PUBLISHED_STATUS_DIR:-/var/bigbluebutton/recording/status/published}"
STATE_DIR="${STATE_DIR:-/opt/bbb/config/recording-state}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/opt/bbb/config/rclone.conf}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
RCLONE_SERVE_URL="${RCLONE_SERVE_URL:-http://127.0.0.1:8081}"
RECORDING_KEEP_LOCAL_DAYS="${RECORDING_KEEP_LOCAL_DAYS:-3}"
LOG_PREFIX="bbb-recording-worker"

if [[ ! -r "$ENV_FILE" ]]; then
    echo "$LOG_PREFIX: missing environment file: $ENV_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${GDRIVE_FOLDER_ID:?GDRIVE_FOLDER_ID is required}"
: "${LMS_RECORDING_CALLBACK_URL:?LMS_RECORDING_CALLBACK_URL is required}"
: "${BBB_RECORDING_CALLBACK_SECRET:?BBB_RECORDING_CALLBACK_SECRET is required}"

export RCLONE_CONFIG_GDRIVE_ROOT_FOLDER_ID="$GDRIVE_FOLDER_ID"

CALLBACK_TIMEOUT="${BBB_RECORDING_CALLBACK_TIMEOUT:-15}"
MAX_RETRIES="${BBB_RECORDING_MAX_RETRIES:-5}"
RETRY_BASE_DELAY="${BBB_RECORDING_RETRY_BASE_DELAY:-2}"
ALLOW_HTTP_CALLBACK="${BBB_RECORDING_ALLOW_HTTP_CALLBACK:-false}"
RCLONE_TPS_LIMIT="${BBB_RECORDING_RCLONE_TPS_LIMIT:-8}"
mkdir -p "$STATE_DIR"
cd /

log() {
    printf '%s: %s\n' "$LOG_PREFIX" "$*"
}

validate_runtime() {
    local command_name
    local numeric_value

    if [[ ! "$LMS_RECORDING_CALLBACK_URL" =~ ^https:// ]] \
        && ! is_allowed_local_http_callback "$LMS_RECORDING_CALLBACK_URL"; then
        log "LMS recording callback URL must use HTTPS"
        return 1
    fi

    for numeric_value in \
        "$CALLBACK_TIMEOUT" \
        "$MAX_RETRIES" \
        "$RETRY_BASE_DELAY" \
        "$RCLONE_TPS_LIMIT" \
        "$RECORDING_KEEP_LOCAL_DAYS"; do
        if [[ ! "$numeric_value" =~ ^[1-9][0-9]*$ ]]; then
            log "Recording worker retry settings must be positive integers"
            return 1
        fi
    done

    for command_name in curl flock jq python3 rclone sha256sum; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log "Missing required command: $command_name"
            return 1
        fi
    done

    if [[ ! -r "$RCLONE_CONFIG" ]]; then
        log "Missing rclone configuration: $RCLONE_CONFIG"
        return 1
    fi

    if [[ ! "$RCLONE_SERVE_URL" =~ ^https?://[^/]+/?$ ]]; then
        log "Rclone serve URL is invalid"
        return 1
    fi
}

is_allowed_local_http_callback() {
    local callback_url="$1"

    if [[ "$ALLOW_HTTP_CALLBACK" != 'true' ]]; then
        return 1
    fi

    python3 - "$callback_url" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

url = urlparse(sys.argv[1])
if url.scheme != "http" or not url.hostname or url.username or url.password:
    sys.exit(1)

if url.hostname == "localhost":
    sys.exit(0)

try:
    address = ipaddress.ip_address(url.hostname)
except ValueError:
    sys.exit(1)

sys.exit(0 if address.is_private or address.is_loopback else 1)
PY
}

recording_id_from_path() {
    basename "$1"
}

is_lms_meeting_id() {
    [[ "$1" =~ ^lms-session-[0-9]+$ ]]
}

metadata_value() {
    local metadata_file="$1"
    local expression="$2"

    python3 - "$metadata_file" "$expression" <<'PY'
import sys
import xml.etree.ElementTree as ET

metadata_file, expression = sys.argv[1:]
try:
    root = ET.parse(metadata_file).getroot()
except (ET.ParseError, OSError):
    sys.exit(1)

node = root
for part in expression.split("/"):
    node = node.find(part)
    if node is None:
        sys.exit(1)

value = node.text or ""
print(value.strip())
PY
}

metadata_for_recording() {
    local recording_dir="$1"
    local metadata_file="$recording_dir/metadata.xml"
    local recording_id="$2"
    local meeting_id=""
    local start_ms=""
    local end_ms=""
    local duration_ms=""
    local size_bytes=""
    local playback_url=""

    [[ -r "$metadata_file" ]] || return 1

    meeting_id="$(metadata_value "$metadata_file" "meta/meetingId" || true)"
    start_ms="$(metadata_value "$metadata_file" "start_time" || true)"
    end_ms="$(metadata_value "$metadata_file" "end_time" || true)"
    duration_ms="$(metadata_value "$metadata_file" "playback/duration" || true)"
    size_bytes="$(metadata_value "$metadata_file" "playback/size" || true)"
    playback_url="$(metadata_value "$metadata_file" "playback/link" || true)"

    if [[ -z "$meeting_id" || -z "$start_ms" || -z "$end_ms" || ! "$playback_url" =~ ^https:// ]]; then
        return 1
    fi

    if [[ ! "$start_ms" =~ ^[0-9]+$ || ! "$end_ms" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ ! "$duration_ms" =~ ^[0-9]+$ ]]; then
        duration_ms=$((end_ms - start_ms))
    fi

    if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then
        size_bytes="$(du -sb "$recording_dir" | awk '{print $1}')"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$recording_id" \
        "$meeting_id" \
        "$size_bytes" \
        "$((duration_ms / 1000))" \
        "$playback_url"
}

state_file() {
    printf '%s/%s.state\n' "$STATE_DIR" "$1"
}

write_state() {
    local path="$1"
    shift
    local temporary_path="${path}.tmp.$$"

    printf '%s\n' "$@" > "$temporary_path"
    mv "$temporary_path" "$path"
}

lock_dir() {
    printf '%s/%s.lock\n' "$STATE_DIR" "$1"
}

drive_path_for() {
    printf '%s\n' "$2"
}

drive_file_id() {
    local remote_path="$1"
    local parent_path
    local folder_name

    parent_path="$(dirname "$remote_path")"
    folder_name="$(basename "$remote_path")"

    if [[ "$parent_path" == '.' ]]; then
        parent_path=""
    fi

    rclone lsjson "$RCLONE_REMOTE:$parent_path" \
        --dirs-only \
        --config="$RCLONE_CONFIG" \
        | jq -r --arg folder_name "$folder_name" \
            '.[] | select(.Name == $folder_name) | .ID // empty' \
        | head -n 1
}

drive_link() {
    local remote_path="$1"

    rclone link "$RCLONE_REMOTE:$remote_path" \
        --config="$RCLONE_CONFIG" 2>/dev/null
}

verify_drive_link() {
    local url="$1"
    local status

    status="$(curl --silent --show-error --location \
        --head --connect-timeout 15 --max-time 30 \
        --output /dev/null --write-out '%{http_code}' "$url" || printf '000')"

    [[ "$status" == "2"* || "$status" == "3"* ]]
}

verify_playback_bundle() {
    local recording_id="$1"
    local metadata_status
    local presentation_status

    metadata_status="$(curl --silent --show-error --location \
        --connect-timeout "$CALLBACK_TIMEOUT" \
        --max-time "$CALLBACK_TIMEOUT" \
        --output /dev/null --write-out '%{http_code}' \
        "$RCLONE_SERVE_URL/$recording_id/metadata.xml" || printf '000')"
    presentation_status="$(curl --silent --show-error --location \
        --connect-timeout "$CALLBACK_TIMEOUT" \
        --max-time "$CALLBACK_TIMEOUT" \
        --output /dev/null --write-out '%{http_code}' \
        "$RCLONE_SERVE_URL/$recording_id/presentation/" || printf '000')"

    [[ "$metadata_status" == '200' && "$presentation_status" == '200' ]]
}

upload_to_drive() {
    local recording_dir="$1"
    local remote_path="$2"
    local attempt=1
    local delay="$RETRY_BASE_DELAY"

    while ((attempt <= MAX_RETRIES)); do
        if rclone copy "$recording_dir/" "$RCLONE_REMOTE:$remote_path" \
            --config="$RCLONE_CONFIG" \
            --contimeout=15s \
            --timeout=10m \
            --retries=1 \
            --low-level-retries=1 \
            --tpslimit="$RCLONE_TPS_LIMIT" \
            --tpslimit-burst="$RCLONE_TPS_LIMIT"; then
            return 0
        fi

        if ((attempt == MAX_RETRIES)); then
            return 1
        fi

        log "Drive upload failed; retry $((attempt + 1))/$MAX_RETRIES"
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
}

callback_body() {
    jq -cn \
        --arg event_id "$1" \
        --arg meeting_id "$2" \
        --arg recording_id "$3" \
        --arg file_id "$4" \
        --arg file_url "$5" \
        --arg playback_url "$6" \
        --arg filename "$7" \
        --argjson size_bytes "$8" \
        --argjson duration_seconds "$9" \
        '{
            event_id: $event_id,
            meeting_id: $meeting_id,
            recording_id: $recording_id,
            file_id: $file_id,
            file_url: $file_url,
            playback_url: $playback_url,
            filename: $filename,
            size_bytes: $size_bytes,
            duration_seconds: $duration_seconds,
            format: "presentation",
            status: "ready"
        }'
}

callback_signature() {
    local body="$1"

    printf '%s' "$body" | python3 -c '
import hashlib
import hmac
import os
import sys

secret = os.fdopen(3, encoding="utf-8").read().rstrip("\n").encode()
print(hmac.new(secret, sys.stdin.buffer.read(), hashlib.sha256).hexdigest())
' 3<<<"$BBB_RECORDING_CALLBACK_SECRET"
}

send_callback() {
    local body="$1"
    local signature="$2"
    local response_file="$3"
    local status=""
    local attempt=1
    local delay="$RETRY_BASE_DELAY"

    CALLBACK_RESULT="retryable"

    while ((attempt <= MAX_RETRIES)); do
        status="$(curl --silent --show-error \
            --connect-timeout "$CALLBACK_TIMEOUT" \
            --max-time "$CALLBACK_TIMEOUT" \
            --output "$response_file" \
            --write-out '%{http_code}' \
            --header 'Accept: application/json' \
            --header 'Content-Type: application/json' \
            --header "X-BBB-Callback-Signature: $signature" \
            --data-binary "$body" \
            "$LMS_RECORDING_CALLBACK_URL" || printf '000')"

        if [[ "$status" == "2"* ]]; then
            CALLBACK_RESULT="sent"
            return 0
        fi

        if [[ "$status" == "4"* ]]; then
            CALLBACK_RESULT="rejected"
            log "LMS callback rejected with HTTP $status; no retry"
            return 1
        fi

        if ((attempt == MAX_RETRIES)); then
            log "LMS callback failed after $MAX_RETRIES attempts (HTTP $status)"
            return 1
        fi

        log "LMS callback failed with HTTP $status; retry $((attempt + 1))/$MAX_RETRIES"
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
}

process_recording() {
    local recording_dir="$1"
    local recording_id
    local state_path
    local metadata
    local meeting_id
    local size_bytes
    local duration_seconds
    local playback_url
    local filename
    local remote_path
    local file_id
    local file_url
    local body
    local event_id
    local signature
    local callback_response

    recording_id="$(recording_id_from_path "$recording_dir")"
    state_path="$(state_file "$recording_id")"

    if [[ -f "$state_path" ]] \
        && grep -Eqx 'callback=rejected' "$state_path"; then
        return 0
    fi

    local lock_path
    lock_path="$(lock_dir "$recording_id")"
    exec 9>"$lock_path"

    if ! flock -n 9; then
        log "Skipping locked recording $recording_id"
        return 0
    fi

    if grep -qx 'upload=done' "$state_path" 2>/dev/null \
        && grep -qx 'playback=verified' "$state_path" 2>/dev/null \
        && grep -qx 'callback=sent' "$state_path" 2>/dev/null; then
        return 0
    fi

    metadata="$(metadata_for_recording "$recording_dir" "$recording_id" || true)"
    if [[ -z "$metadata" ]]; then
        log "Skipping incomplete recording $recording_id"
        return 0
    fi

    IFS=$'\t' read -r recording_id meeting_id size_bytes duration_seconds playback_url <<< "$metadata"

    if ! is_lms_meeting_id "$meeting_id"; then
        log "Skipping recording with unsupported meeting ID $meeting_id"
        return 0
    fi

    if [[ ! -r "$recording_dir/metadata.xml" ]] \
        || [[ -z "$(find "$recording_dir" -mindepth 1 -type f -print -quit)" ]]; then
        log "Published presentation bundle is incomplete for $recording_id"
        return 1
    fi

    if grep -qx 'callback=sent' "$state_path" 2>/dev/null \
        && ! grep -qx 'playback=verified' "$state_path" 2>/dev/null; then
        if verify_playback_bundle "$recording_id"; then
            write_state "$state_path" \
                'upload=done' \
                'playback=verified' \
                'callback=sent' \
                "$(grep '^event_id=' "$state_path")" \
                "completed_at_epoch=$(date +%s)"
        else
            log "Drive playback bundle is not available for $recording_id"
            return 1
        fi

        return 0
    fi

    filename="${meeting_id}-${recording_id}-presentation"
    size_bytes="$(du -sb "$recording_dir" | awk '{print $1}')"
    remote_path="$(drive_path_for "$meeting_id" "$recording_id")"

    if ! grep -qx 'upload=done' "$state_path" 2>/dev/null; then
        if ! upload_to_drive "$recording_dir" "$remote_path"; then
            log "Drive upload failed for $recording_id"
            return 1
        fi
        write_state "$state_path" 'upload=done'
    fi

    file_id="$(drive_file_id "$remote_path" || true)"
    file_url="$(drive_link "$remote_path" || true)"

    if [[ -z "$file_id" ]]; then
        if ! upload_to_drive "$recording_dir" "$remote_path"; then
            log "Drive folder disappeared for $recording_id"
            return 1
        fi
        file_id="$(drive_file_id "$remote_path" || true)"
        file_url="$(drive_link "$remote_path" || true)"
    fi

    if [[ -z "$file_id" || ! "$file_url" =~ ^https:// ]] || ! verify_drive_link "$file_url"; then
        log "Drive metadata is incomplete for $recording_id"
        return 1
    fi

    if ! verify_playback_bundle "$recording_id"; then
        log "Drive playback bundle is not available for $recording_id"
        return 1
    fi

    event_id="$(printf '%s' "$meeting_id:$recording_id" | sha256sum | awk '{print $1}')"
    body="$(callback_body \
        "$event_id" \
        "$meeting_id" \
        "$recording_id" \
        "$file_id" \
        "$file_url" \
        "$playback_url" \
        "$filename" \
        "$size_bytes" \
        "$duration_seconds")"
    signature="$(callback_signature "$body")"
    callback_response="$STATE_DIR/$recording_id.callback.response"

    if send_callback "$body" "$signature" "$callback_response"; then
        write_state "$state_path" \
            'upload=done' \
            'playback=verified' \
            'callback=sent' \
            "event_id=$event_id" \
            "completed_at_epoch=$(date +%s)"
        rm -f "$callback_response"
        log "Completed recording $recording_id"
        return 0
    fi

    if [[ "$CALLBACK_RESULT" == 'rejected' ]]; then
        write_state "$state_path" \
            'upload=done' \
            'callback=rejected' \
            "event_id=$event_id"
    fi

    return 1
}

cleanup_completed_recordings() {
    local recording_dir
    local recording_id
    local state_path
    local completed_at_epoch
    local retention_seconds
    local now_epoch

    retention_seconds=$((RECORDING_KEEP_LOCAL_DAYS * 86400))
    now_epoch="$(date +%s)"

    while IFS= read -r recording_dir; do
        recording_id="$(basename "$recording_dir")"
        state_path="$(state_file "$recording_id")"

        if [[ ! -f "$state_path" ]] \
            || ! grep -qx 'upload=done' "$state_path" \
            || ! grep -qx 'playback=verified' "$state_path" \
            || ! grep -qx 'callback=sent' "$state_path"; then
            continue
        fi

        completed_at_epoch="$(
            sed -n 's/^completed_at_epoch=//p' "$state_path" | tail -n 1
        )"

        if [[ ! "$completed_at_epoch" =~ ^[0-9]+$ ]]; then
            completed_at_epoch="$(stat -c %Y "$state_path")"
        fi

        if ((now_epoch - completed_at_epoch < retention_seconds)); then
            continue
        fi

        if command -v bbb-record >/dev/null 2>&1 \
            && bbb-record --delete "$recording_id"; then
            printf '%s\n' 'cleanup=done' >> "$state_path"
            log "Removed local recording $recording_id"
        else
            log "Failed to remove local recording $recording_id"
        fi
    done < <(find "$LOCAL_REC_DIR" -mindepth 1 -maxdepth 1 -type d -print)
}

main() {
    local status_file
    local recording_id
    local recording_dir
    local had_failures=0

    validate_runtime

    if [[ ! -d "$LOCAL_REC_DIR" || ! -d "$PUBLISHED_STATUS_DIR" ]]; then
        log "BBB recording directories are not available"
        return 0
    fi

    while IFS= read -r status_file; do
        recording_id="$(basename "$status_file" '-presentation.done')"
        recording_dir="$LOCAL_REC_DIR/$recording_id"

        if [[ -d "$recording_dir" ]]; then
            if ! (process_recording "$recording_dir"); then
                had_failures=1
            fi
        fi
    done < <(find "$PUBLISHED_STATUS_DIR" -maxdepth 1 -type f -name '*-presentation.done' -print)

    cleanup_completed_recordings

    return "$had_failures"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
