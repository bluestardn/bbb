#!/usr/bin/env bash

# ==============================================================================
# Script test nhanh API BigBlueButton và tính checksum SHA1
# Chạy: bash scripts/test-api.sh
# ==============================================================================

set -e

# Đọc cấu hình
ENV_FILE="/opt/bbb/config/.env"
if [ ! -f "$ENV_FILE" ]; then
    # Thử lấy trực tiếp từ bbb-conf nếu chưa cấu hình .env
    if command -v bbb-conf &> /dev/null; then
        BBB_DOMAIN=$(bbb-conf --secret | grep "URL:" | awk '{print $2}' | sed 's|/bigbluebutton/||' | sed 's|https://||')
        BBB_SECRET=$(bbb-conf --secret | grep "Secret:" | awk '{print $2}')
    else
        echo "❌ Lỗi: Cần chạy trên máy cài BBB hoặc cấu hình file config/.env"
        exit 1
    fi
else
    source "$ENV_FILE"
fi

API_URL="https://$BBB_DOMAIN/bigbluebutton/api"

echo "Domain: $BBB_DOMAIN"
echo "Secret: $BBB_SECRET"
echo "--------------------------------------------------"

# 1. Gọi API getMeetings (Xem danh sách phòng đang hoạt động)
ACTION="getMeetings"
PARAMS=""
CHECKSUM=$(echo -n "${ACTION}${PARAMS}${BBB_SECRET}" | sha1sum | awk '{print $1}')
FULL_URL="${API_URL}/${ACTION}?checksum=${CHECKSUM}"

echo "1. Gọi API getMeetings..."
curl -s "$FULL_URL" | grep -o "<returncode>[^<]*" || echo "Không nhận được phản hồi"
echo -e "\nURL: $FULL_URL\n"

# 2. Gọi API create (Tạo phòng test)
MEETING_ID="test-room-123"
MEETING_NAME="Lop-Hoc-Thu-Nghiem-VKU"
ACTION="create"
PARAMS="meetingID=${MEETING_ID}&name=${MEETING_NAME}"
CHECKSUM=$(echo -n "${ACTION}${PARAMS}${BBB_SECRET}" | sha1sum | awk '{print $1}')
FULL_URL="${API_URL}/${ACTION}?${PARAMS}&checksum=${CHECKSUM}"

echo "2. Tạo phòng học thử nghiệm ($MEETING_ID)..."
curl -s "$FULL_URL" | grep -o "<returncode>[^<]*" || echo "Không nhận được phản hồi"
echo -e "\nURL: $FULL_URL\n"

# 3. Tạo link Join cho Giáo viên (Moderator)
ACTION="join"
PARAMS="fullName=Giao-Vien-VKU&meetingID=${MEETING_ID}&password=mp&role=MODERATOR"
CHECKSUM=$(echo -n "${ACTION}${PARAMS}${BBB_SECRET}" | sha1sum | awk '{print $1}')
JOIN_URL="${API_URL}/${ACTION}?${PARAMS}&checksum=${CHECKSUM}"

echo "3. Link Join cho Giáo viên (Moderator):"
echo -e "$JOIN_URL\n"

# 4. Tạo link Join cho Học sinh (Viewer)
ACTION="join"
PARAMS="fullName=Hoc-Sinh-VKU&meetingID=${MEETING_ID}&password=ap&role=VIEWER"
CHECKSUM=$(echo -n "${ACTION}${PARAMS}${BBB_SECRET}" | sha1sum | awk '{print $1}')
JOIN_URL="${API_URL}/${ACTION}?${PARAMS}&checksum=${CHECKSUM}"

echo "4. Link Join cho Học sinh (Viewer):"
echo -e "$JOIN_URL\n"
echo "Copy các link trên dán vào trình duyệt để test kết nối WebRTC."
