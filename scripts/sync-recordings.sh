#!/usr/bin/env bash

# ==============================================================================
# Script đồng bộ Recording từ BBB lên Google Drive (sử dụng rclone)
# Chạy định kỳ bằng Cron: 0 * * * * /opt/bbb/scripts/sync-recordings.sh
# ==============================================================================

set -e

# Đọc cấu hình
ENV_FILE="/opt/bbb/config/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Không tìm thấy file cấu hình /opt/bbb/config/.env"
    exit 1
fi

source "$ENV_FILE"

# Thư mục lưu trữ local của recordings BBB
LOCAL_REC_DIR="/var/bigbluebutton/published/presentation"
STATE_FILE="/opt/bbb/config/sync_state.txt"
touch "$STATE_FILE"

echo "====== Bắt đầu tiến trình đồng bộ recordings: $(date) ======"

if [ ! -d "$LOCAL_REC_DIR" ]; then
    echo "⚠️ Thư mục local $LOCAL_REC_DIR không tồn tại hoặc chưa có recording nào."
    exit 0
fi

# Quét qua danh sách các thư mục ghi hình (mỗi thư mục tương ứng 1 meetingID-sessionID)
cd "$LOCAL_REC_DIR"
for meeting_id in *; do
    # Bỏ qua nếu không phải thư mục hoặc là các ký tự đại diện
    if [ ! -d "$meeting_id" ] || [ "$meeting_id" == "*" ]; then
        continue
    fi

    # Kiểm tra xem đã sync thư mục này chưa
    if grep -q "^$meeting_id$" "$STATE_FILE"; then
        echo "✓ $meeting_id đã được đồng bộ trước đó. Bỏ qua."
        continue
    fi

    echo "⚡ Phát hiện recording mới: $meeting_id. Bắt đầu upload lên Google Drive..."

    # Sử dụng rclone để upload thư mục recording lên Google Drive
    # rclone copy <thư mục nguồn> gdrive:<thư mục đích>
    # Cần cấu hình rclone remote tên là 'gdrive' trỏ về service account hoặc token
    
    if rclone copy "$meeting_id" "gdrive:$GDRIVE_FOLDER_ID/$meeting_id" --config="/opt/bbb/config/rclone.conf"; then
        echo "✓ Upload thành công: $meeting_id"
        
        # Ghi nhận trạng thái đã sync thành công
        echo "$meeting_id" >> "$STATE_FILE"
        
        # Gọi webhook thông báo cho LMS (nếu cấu hình)
        if [ -n "$LMS_CALLBACK_URL" ]; then
            echo "-> Gửi webhook thông báo cho LMS..."
            curl -X POST \
              -H "Content-Type: application/json" \
              -d "{\"event\":\"recording_ready\",\"meeting_id\":\"$meeting_id\",\"gdrive_folder\":\"$GDRIVE_FOLDER_ID\"}" \
              "$LMS_CALLBACK_URL" || echo "⚠️ Lỗi gửi webhook cho LMS"
        fi
    else
        echo "❌ Lỗi khi upload $meeting_id lên Google Drive!"
    fi
done

# Cleanup: Xóa các recording local cũ hơn X ngày để tiết kiệm dung lượng
echo "-> Bắt đầu tiến trình dọn dẹp local storage..."
find "$LOCAL_REC_DIR" -maxdepth 1 -type d -mtime +"$RECORDING_KEEP_LOCAL_DAYS" | while read -r old_dir; do
    dir_name=$(basename "$old_dir")
    if [ "$dir_name" != "presentation" ] && [ -n "$dir_name" ]; then
        # Chỉ xóa nếu đã chắc chắn được sync lên Drive thành công
        if grep -q "^$dir_name$" "$STATE_FILE"; then
            echo "🗑 Xóa local recording đã đồng bộ quá hạn: $dir_name"
            # Gọi bbb-record để xóa sạch cả raw và published files an toàn
            bbb-record --delete "$dir_name" || rm -rf "$old_dir"
        fi
    fi
done

echo "====== Hoàn thành tiến trình đồng bộ: $(date) ======"
