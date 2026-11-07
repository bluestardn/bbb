#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/.env" <<'ENV'
GDRIVE_FOLDER_ID=test-folder
LMS_RECORDING_CALLBACK_URL=https://lms.example.com/api/internal/bbb/recordings/completed
BBB_RECORDING_CALLBACK_SECRET=test-secret
BBB_RECORDING_CALLBACK_TIMEOUT=1
BBB_RECORDING_MAX_RETRIES=3
BBB_RECORDING_RETRY_BASE_DELAY=1
ENV

export ENV_FILE="$TEST_DIR/.env"
export STATE_DIR="$TEST_DIR/state"

# shellcheck source=../scripts/sync-recordings.sh
source "$ROOT_DIR/scripts/sync-recordings.sh"

assert_equal() {
    if [[ "$1" != "$2" ]]; then
        printf 'Expected: %s\nActual: %s\n' "$1" "$2" >&2
        exit 1
    fi
}

test_callback_body_and_signature() {
    local body
    local signature
    local expected

    body="$(callback_body \
        'event-1' \
        'lms-session-123' \
        'recording-1' \
        'file-1' \
        'https://drive.google.com/drive/folders/file-1' \
        'https://bbb.example.com/playback/presentation/2.3/recording-1' \
        'Bài giảng & 日本語-presentation' \
        '123456' \
        '3600')"
    signature="$(callback_signature "$body")"
    expected="$(printf '%s' "$body" | python3 -c \
        'import hashlib,hmac,sys; print(hmac.new(b"test-secret", sys.stdin.buffer.read(), hashlib.sha256).hexdigest())')"

    assert_equal "$expected" "$signature"
    assert_equal 'Bài giảng & 日本語-presentation' "$(jq -r '.filename' <<< "$body")"
    assert_equal 'presentation' "$(jq -r '.format' <<< "$body")"
    assert_equal 'https://bbb.example.com/playback/presentation/2.3/recording-1' \
        "$(jq -r '.playback_url' <<< "$body")"

    if [[ "$signature" == "$(callback_signature "${body}x")" ]]; then
        echo 'A modified callback body kept the same signature.' >&2
        exit 1
    fi
}

test_metadata() {
    local recording_dir="$TEST_DIR/lms-recording"
    local metadata

    mkdir -p "$recording_dir"
    cat > "$recording_dir/metadata.xml" <<'XML'
<recording>
  <id>recording-1</id>
  <start_time>1000</start_time>
  <end_time>61000</end_time>
  <meta><meetingId>lms-session-123</meetingId></meta>
  <playback>
    <duration>60000</duration>
    <size>2048</size>
    <link>https://bbb.example.com/playback/presentation/2.3/recording-1</link>
  </playback>
</recording>
XML

    metadata="$(metadata_for_recording "$recording_dir" 'recording-1')"
    assert_equal \
        $'recording-1\tlms-session-123\t2048\t60\thttps://bbb.example.com/playback/presentation/2.3/recording-1' \
        "$metadata"
}

test_drive_path() {
    assert_equal 'recording-1' "$(drive_path_for 'lms-session-123' 'recording-1')"
}

test_local_http_callback_policy() {
    ALLOW_HTTP_CALLBACK=true
    is_allowed_local_http_callback 'http://192.168.122.1:8000/callback'
    is_allowed_local_http_callback 'http://127.0.0.1:8000/callback'

    if is_allowed_local_http_callback 'http://example.com/callback'; then
        echo 'A public HTTP callback URL was accepted.' >&2
        exit 1
    fi

    ALLOW_HTTP_CALLBACK=false

    if is_allowed_local_http_callback 'http://192.168.122.1:8000/callback'; then
        echo 'A local HTTP callback URL was accepted without the development flag.' >&2
        exit 1
    fi
}

test_callback_retry_policy() {
    local response_file="$TEST_DIR/response"
    local status_file="$TEST_DIR/statuses"
    local body_log="$TEST_DIR/bodies"

    curl() {
        local argument
        local capture_next=false

        for argument in "$@"; do
            if $capture_next; then
                printf '%s\n' "$argument" >> "$body_log"
                capture_next=false
            elif [[ "$argument" == '--data-binary' ]]; then
                capture_next=true
            fi
        done

        head -n 1 "$status_file"
        sed -i '1d' "$status_file"
    }

    sleep() {
        :
    }

    printf '500\n200\n' > "$status_file"
    send_callback '{"event_id":"stable"}' 'signature' "$response_file"
    assert_equal '2' "$(wc -l < "$body_log" | tr -d ' ')"
    assert_equal '1' "$(sort -u "$body_log" | wc -l | tr -d ' ')"

    : > "$body_log"
    printf '422\n200\n' > "$status_file"

    if send_callback '{"event_id":"invalid"}' 'signature' "$response_file"; then
        echo 'A 4xx callback response was treated as successful.' >&2
        exit 1
    fi

    assert_equal '1' "$(wc -l < "$body_log" | tr -d ' ')"

    : > "$body_log"
    printf '500\n500\n500\n' > "$status_file"

    if send_callback '{"event_id":"max-retries"}' 'signature' "$response_file"; then
        echo 'A callback succeeded after exhausting all retries.' >&2
        exit 1
    fi

    assert_equal '3' "$(wc -l < "$body_log" | tr -d ' ')"
}

test_duplicate_recording() {
    local recording_id='recording-duplicate'
    local recording_dir="$TEST_DIR/$recording_id"

    mkdir -p "$recording_dir"
    write_state "$(state_file "$recording_id")" \
        'upload=done' \
        'playback=verified' \
        'callback=sent' \
        'event_id=stable'

    process_recording "$recording_dir"
}

test_callback_body_and_signature
test_metadata
test_drive_path
test_local_http_callback_policy
test_callback_retry_policy
test_duplicate_recording

echo 'recording-worker tests passed'
