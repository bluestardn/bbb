# Luồng xử lý recording

Các dịch vụ recording của BBB xử lý buổi học đến trạng thái `published`.
Worker đồng bộ chỉ xử lý recording đáp ứng đồng thời hai điều kiện:

- Có marker trạng thái publish kết thúc bằng `-presentation.done`.
- Có thư mục published chứa file `metadata.xml` hợp lệ.

Worker bỏ qua recording có meeting ID không đúng định dạng LMS
`lms-session-{session_id}`.

## Cấu hình

Sao chép file môi trường mẫu và điền cấu hình trên máy chủ BBB:

```bash
sudo install -o bigbluebutton -g bigbluebutton -m 0640 \
  config/.env.example /opt/bbb/config/.env
sudoedit /opt/bbb/config/.env
```

Các giá trị cần cấu hình:

```dotenv
GDRIVE_FOLDER_ID=...
LMS_RECORDING_CALLBACK_URL=https://lms.example.com/api/internal/bbb/recordings/completed
BBB_RECORDING_CALLBACK_SECRET=...
BBB_RECORDING_CALLBACK_TIMEOUT=15
BBB_RECORDING_MAX_RETRIES=5
BBB_RECORDING_RETRY_BASE_DELAY=2
BBB_RECORDING_RCLONE_TPS_LIMIT=8
BBB_RECORDING_ALLOW_HTTP_CALLBACK=false
RCLONE_CONFIG=/opt/bbb/config/rclone.conf
RCLONE_REMOTE=gdrive
RCLONE_SERVE_URL=http://127.0.0.1:8081
RCLONE_SERVE_ADDR=127.0.0.1:8081
RCLONE_SERVE_CACHE_MODE=full
RCLONE_SERVE_CACHE_DIR=/var/cache/bbb-rclone
RCLONE_SERVE_CACHE_MAX_SIZE=50G
RCLONE_SERVE_CACHE_MAX_AGE=72h
RCLONE_SERVE_CACHE_POLL_INTERVAL=1m
RECORDING_KEEP_LOCAL_DAYS=3
```

Secret phải trùng chính xác với `BBB_RECORDING_CALLBACK_SECRET` trong LMS.
Không commit file môi trường hoặc thông tin xác thực Google.

Chỉ khi test trên máy ảo local mới đặt
`BBB_RECORDING_ALLOW_HTTP_CALLBACK=true` để cho phép callback HTTP đến
localhost hoặc IP private. Môi trường production phải giữ giá trị `false`.

Cấu hình rclone remote tên `gdrive` trong
`/opt/bbb/config/rclone.conf`. Remote phải có quyền upload file và tạo link xem.
Môi trường local có thể dùng OAuth; production sử dụng Service Account hoặc
tài khoản Google Workspace/Shared Drive đã được phê duyệt.

`BBB_RECORDING_RCLONE_TPS_LIMIT` giới hạn số request Drive API khi upload bundle
có nhiều file nhỏ.

Kiểm tra remote trước khi bật timer:

```bash
sudo -u bigbluebutton rclone lsd gdrive: \
  --config=/opt/bbb/config/rclone.conf
```

## Cài worker

Worker sử dụng systemd timer thay cho cron job không được quản lý:

```bash
sudo bash /opt/bbb/scripts/install-recording-worker.sh
sudo systemctl status bbb-recording-sync.timer
sudo journalctl -u bbb-recording-sync.service -n 100 --no-pager
```

Timer chạy sau mỗi năm phút và tiếp tục hoạt động sau khi server khởi động lại.
Mỗi recording có lock và file trạng thái riêng trong
`/opt/bbb/config/recording-state`, tránh hai worker upload trùng recording.
Nếu callback lỗi, worker giữ trạng thái upload và thử callback lại ở lần chạy
tiếp theo.

Worker upload toàn bộ presentation bundle lên một thư mục Google Drive.
Bundle bao gồm media, slide, annotation, con trỏ, ghi chú và metadata playback.
Mỗi recording được lưu trực tiếp dưới Drive root theo cấu trúc
`{recording_id}/`, đúng với đường dẫn BBB playback.

`rclone-serve-gdrive.service` phục vụ Drive root qua địa chỉ HTTP nội bộ được
cấu hình bằng `RCLONE_SERVE_ADDR`. Nginx ánh xạ dịch vụ này qua route
`/presentation/`, còn người dùng tiếp tục mở URL:

```text
https://<bbb-domain>/playback/presentation/2.3/{recording_id}
```

Rclone dùng VFS cache ở chế độ `full`. Cache nằm trên ổ cứng server, có giới
hạn mặc định 50 GB và tự dọn dữ liệu không được truy cập trong 72 giờ. Khi đạt
giới hạn, rclone có thể loại dữ liệu cache cũ trước 72 giờ để giữ dung lượng
trong mức cấu hình. Cache chỉ là vùng đệm; Google Drive vẫn là nguồn lưu trữ
lâu dài sau khi recording local bị xóa.

Trước khi gửi callback, worker kiểm tra `metadata.xml` và thư mục
`presentation/` thông qua dịch vụ HTTP của rclone. Sau số ngày cấu hình trong
`RECORDING_KEEP_LOCAL_DAYS`, worker chỉ xóa recording local khi upload, kiểm tra
playback và callback đều đã thành công. Thời gian giữ local được tính từ lúc
pipeline hoàn tất, không tính từ thời điểm thư mục recording được tạo.

## Callback về LMS

Sau khi bundle được upload và link thư mục Drive HTTPS được kiểm tra, worker
tạo một JSON body duy nhất và ký chính xác body đó bằng HMAC-SHA256. Các lần
retry giữ nguyên `event_id`, `recording_id` và dữ liệu JSON.

Payload gồm Drive folder ID/link, BBB `playback_url`, `format=presentation`,
kích thước bundle, thời lượng và `status=ready`.

Worker gửi request:

```http
POST /api/internal/bbb/recordings/completed
Content-Type: application/json
X-BBB-Callback-Signature: <hex hmac-sha256>
```

Worker không retry response HTTP 4xx. Lỗi mạng, timeout và HTTP 5xx được retry
có giới hạn với exponential backoff.

## Kiểm thử nhanh

1. Tạo phòng BBB từ LMS với meeting ID, ví dụ `lms-session-123`.
2. Xác nhận recording tự động bắt đầu.
3. Kết thúc buổi học và chờ BBB xử lý recording.
4. Xác nhận xuất hiện marker `*-presentation.done`.
5. Chạy worker:

   ```bash
   sudo systemctl start bbb-recording-sync.service
   ```

6. Kiểm tra systemd journal và thư mục Google Drive đã cấu hình.
7. Xác nhận URL `http://127.0.0.1:8081/{recording_id}/metadata.xml` truy cập
   được và playback URL mở đúng recording.
8. Xác nhận callback LMS trả HTTP 200 và chạy lại worker không tạo recording
   trùng.

Để kiểm tra xử lý lỗi, tạm thời trỏ callback URL sang endpoint test hoặc dừng
LMS, sau đó khôi phục cấu hình và chạy lại service. Không đưa callback secret
vào command history hoặc log.
