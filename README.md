# BigBlueButton — VKU Center Deployment

Bộ công cụ triển khai & tùy biến BigBlueButton cho hệ thống LMS VKU Center.

> **Mục tiêu:** Clone repo này về máy Ubuntu mới tinh → chạy theo hướng dẫn → có ngay server BBB với theme riêng, sẵn sàng tích hợp LMS.

---

## Yêu cầu Server

| Thông số | Tối thiểu | Khuyến nghị |
|---|---|---|
| OS | Ubuntu 22.04 LTS (64-bit) | Ubuntu 22.04 LTS |
| CPU | 8 vCPU | 16 vCPU |
| RAM | 16 GB | 32 GB |
| Ổ cứng | 100 GB SSD | 200 GB SSD |
| Mạng | IP Public hoặc NAT ra ngoài | IP Public tĩnh |
| Domain | Có domain trỏ về IP server | HTTPS bắt buộc |

---

## Cài đặt từ A-Z (Ubuntu mới tinh)

### Bước 1 — Chuẩn bị hệ thống

```bash
# Cập nhật hệ thống
sudo apt update && sudo apt upgrade -y

# Cài các gói cần thiết
sudo apt install -y \
  git curl wget gnupg apt-transport-https ca-certificates \
  jq yq gzip

# Clone repo này
cd /opt
git clone git@github.com:bluestardn/bbb.git
cd bbb
```

### Bước 2 — Cài đặt BigBlueButton

Sử dụng script cài đặt chính thức của BBB. Thay `bbb.your-domain.com` bằng domain thật.

```bash
# Tải và chạy script cài đặt BBB 3.0
# -v noble-300: version BBB 3.0 trên Ubuntu 24.04 (noble) hoặc jammy-300 cho Ubuntu 22.04
# -s: domain
# -e: email cho Let's Encrypt SSL
# -g: cài Greenlight (trang quản trị mặc định, tùy chọn)

wget -qO- https://raw.githubusercontent.com/bigbluebutton/bbb-install/v3.0.x-release/bbb-install.sh | bash -s -- \
  -v jammy-300 \
  -s bbb.your-domain.com \
  -e admin@your-domain.com \
  -w
```

> ⚠️ **Lưu ý:**
> - Script cần chạy với quyền root hoặc sudo
> - Quá trình cài đặt mất khoảng 15-30 phút
> - Domain phải trỏ về IP server trước khi chạy (để Let's Encrypt xác thực)

### Bước 3 — Kiểm tra cài đặt

```bash
# Kiểm tra trạng thái BBB
sudo bbb-conf --check

# Xem thông tin API (lấy Secret Key)
sudo bbb-conf --secret
```

Kết quả sẽ hiện:

```
URL: https://bbb.your-domain.com/bigbluebutton/
Secret: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

> 📌 **Lưu lại URL và Secret** — cần dùng để cấu hình LMS (file `.env` Laravel).

### Bước 4 — Cấu hình NAT (nếu server sau router)

Nếu server nằm sau NAT (ví dụ chạy tại văn phòng), cần port forward:

```bash
# Sửa file cấu hình
sudo nano /etc/bigbluebutton/bbb-web.properties
```

Thêm/sửa:

```properties
# IP public thật (hoặc domain)
defaultGuestPolicy=ALWAYS_ACCEPT
```

Port forward trên router:

| Port | Protocol | Mô tả |
|---|---|---|
| 80 | TCP | HTTP (redirect sang HTTPS) |
| 443 | TCP | HTTPS (web + WebSocket) |
| 16384-32768 | UDP | Media (audio/video WebRTC) |

```bash
# Nếu cần Coturn (TURN server) cho mạng strict
sudo apt install coturn -y
# Xem file cấu hình mẫu: config/turnserver.conf
```

### Bước 5 — Áp dụng Custom Theme

```bash
# Cập nhật theme/branding.json trước khi chạy.
cd /opt/bbb
sudo bash scripts/apply-theme.sh
```

Script yêu cầu `bbb-conf`, `jq`, `yq`, `gzip`, `nginx`, `python3` và
`sha256sum`. Các công cụ này đã được cài ở bước chuẩn bị hệ thống hoặc đi kèm
gói BBB.

Script này sẽ:
- Cài logo, favicon và CSS thương hiệu vào đường dẫn web ổn định.
- Dùng `theme/slide-1.png` làm slide mở đầu mặc định của phòng mới.
- Cập nhật tên và copyright của HTML5 client.
- Áp dụng logo, favicon, màu sắc và tiêu đề cho phòng học trực tuyến.
- Việt hóa trạng thái phòng không tồn tại, hết hạn, bị từ chối, mất kết nối và
  kết thúc buổi học.
- Hiển thị logo và hotline hỗ trợ trên màn hình lỗi và màn hình kết thúc.
- Áp dụng giao diện Edura cho trang xem lại bản ghi, gồm cả chế độ sáng/tối.
- Hiển thị thông báo tiếng Việt khi bản ghi đang xử lý, không tồn tại hoặc tải
  thất bại.
- Hiển thị hotline/email hỗ trợ trong welcome footer.
- Merge cấu hình vào `/etc/bigbluebutton` mà không xóa override hiện có.
- Tự đăng ký hook để áp dụng lại theme sau khi nâng cấp BBB.

Theme sử dụng logo phía server. Ứng dụng tạo meeting không cần truyền thêm
tham số `logo`, tránh hiển thị trùng logo trong phòng học.

Các trạng thái đã được tùy biến:

| Khu vực | Nội dung |
|---|---|
| Phòng học | Logo, favicon, tên Edura, màu thương hiệu và hotline hỗ trợ |
| Lỗi tham gia | Thông báo tiếng Việt cho link sai, phòng hết hạn, bị từ chối hoặc không có quyền |
| Mất kết nối | Thông báo kiểm tra mạng và trạng thái đang kết nối lại |
| Kết thúc buổi học | Logo, nội dung tiếng Việt và hướng dẫn chuyển về LMS |
| Playback | Logo, màu điều khiển, tiêu đề và thông tin hỗ trợ |
| Playback lỗi | Thông báo bản ghi đang xử lý, không tồn tại hoặc tạm thời không tải được |

Locale mặc định của HTML5 client được đặt thành `vi-VN`. Các chuỗi bổ sung nằm
trong `theme/locale-overrides.json`. Script lưu bản locale trước khi chỉnh sửa
để `remove-theme.sh` có thể khôi phục.

Kiểm tra theme:

```bash
sudo nginx -t
sudo bbb-conf --check
curl -I https://bbb.your-domain.com/branding/custom.css
curl -I https://bbb.your-domain.com/branding/playback.css
curl -I https://bbb.your-domain.com/logo.png
curl -I https://bbb.your-domain.com/favicon.ico
curl -I https://bbb.your-domain.com/branding/slide-1.png
```

Kiểm tra thủ công sau khi áp dụng:

1. Tạo meeting mới và xác nhận chỉ hiển thị một logo Edura cùng slide mở đầu.
2. Mở link phòng không hợp lệ để kiểm tra thông báo và hotline.
3. Kết thúc meeting và kiểm tra màn hình chuyển về LMS.
4. Mở recording đã publish để kiểm tra playback.
5. Mở URL playback với recording ID không tồn tại để kiểm tra trạng thái lỗi.

Meeting đã tạo trước khi áp dụng có thể giữ welcome message hoặc tham số
branding cũ. Hãy tạo meeting ID mới khi kiểm tra.

Gỡ theme:

```bash
sudo bash scripts/remove-theme.sh
```

Chi tiết xem [docs/THEME.md](docs/THEME.md).

### Bước 6 — Cấu hình Recording tự động lên Google Drive và LMS

```bash
# Copy file cấu hình
sudo install -o bigbluebutton -g bigbluebutton -m 0640 \
  config/.env.example /opt/bbb/config/.env

# Sửa thông tin Google Drive
sudoedit /opt/bbb/config/.env
```

Cấu hình rclone remote tên `gdrive` trong `/opt/bbb/config/rclone.conf`, sau đó
cài systemd timer:

```bash
sudo bash scripts/install-recording-worker.sh
sudo systemctl status bbb-recording-sync.timer
sudo journalctl -u bbb-recording-sync.service -n 100 --no-pager
```

Worker chỉ xử lý recording đã có marker `*-presentation.done`, có meeting ID
dạng `lms-session-{session_id}` và đã có `metadata.xml`. Worker upload toàn bộ
presentation bundle lên Drive, kiểm tra bundle qua `rclone serve`, kiểm tra
HTTPS link và ký callback HMAC-SHA256. Playback BBB vẫn dùng URL:
`/playback/presentation/2.3/{recording_id}`; dữ liệu bundle được đọc từ Drive
qua route nội bộ `/presentation/`. Sau thời gian giữ local cấu hình được, worker
xóa recording local sau khi upload, playback verification và callback thành
công. Playback sử dụng VFS cache local tối đa 50 GB; Google Drive là nguồn lưu
trữ lâu dài sau khi bản gốc trên server được xóa.

Chi tiết biến môi trường, callback, retry và kiểm thử xem
[docs/RECORDING-PIPELINE.md](docs/RECORDING-PIPELINE.md).

### Bước 7 — Kiểm tra hoàn tất

```bash
# Kiểm tra BBB hoạt động
sudo bbb-conf --check

# Test tạo phòng qua API (thay secret và domain thật)
# Xem file scripts/test-api.sh
sudo bash scripts/test-api.sh

# Restart nếu cần
sudo bbb-conf --restart
```

---

## Cấu trúc thư mục

```
bbb/
├── README.md                  # File này
├── config/
│   ├── .env.example           # Biến môi trường mẫu (Google Drive, LMS, ...)
│   ├── bbb-recording-sync.service
│   ├── bbb-recording-sync.timer
│   ├── rclone-serve-gdrive.service
│   ├── recording-playback.nginx
│   ├── bbb-web.properties     # Override cấu hình BBB web
│   ├── turnserver.conf        # Cấu hình Coturn mẫu
│   └── nginx-bbb.conf         # Override Nginx nếu cần
├── theme/
│   ├── logo.png               # Logo trung tâm
│   ├── favicon.ico            # Favicon
│   ├── slide-1.png            # Slide mở đầu mặc định
│   ├── custom.css.template    # CSS template giao diện
│   ├── playback.css.template  # CSS template trang xem lại bản ghi
│   ├── locale-overrides.json  # Chuỗi tiếng Việt bổ sung
│   └── branding.json          # Tên, màu sắc, hotline
├── scripts/
│   ├── apply-theme.sh         # Script áp dụng theme lên BBB
│   ├── remove-theme.sh        # Script gỡ theme
│   ├── sync-recordings.sh     # Worker đồng bộ recording → Drive → LMS
│   ├── serve-recordings.sh     # Phục vụ bundle Drive cho BBB playback
│   ├── install-recording-worker.sh
│   ├── backup-config.sh       # Backup cấu hình BBB
│   ├── test-api.sh            # Script test API nhanh
│   └── healthcheck.sh         # Kiểm tra trạng thái server
└── docs/
    ├── THEME.md               # Chi tiết theme, trạng thái lỗi và playback
    ├── NAT-SETUP.md           # Hướng dẫn chi tiết NAT
    ├── RECORDING-PIPELINE.md  # Chi tiết pipeline recording
    └── LMS-INTEGRATION.md     # Hướng dẫn tích hợp LMS Laravel
```

---

## Tích hợp LMS (Laravel)

Sau khi cài xong BBB, cấu hình bên Laravel `.env`:

```dotenv
BBB_SERVER_BASE_URL=https://bbb.your-domain.com/bigbluebutton/api/
BBB_SECURITY_SALT=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
BBB_RECORDING_BACKUP_DRIVER=google_drive
```

Chi tiết tích hợp xem: [docs/LMS-INTEGRATION.md](docs/LMS-INTEGRATION.md)

---

## Hotline & Hỗ trợ

Tên trung tâm, hotline, email hỗ trợ và bảng màu được cấu hình trong
`theme/branding.json`. Phải xác nhận lại thông tin hỗ trợ trước mỗi lần triển
khai lên môi trường chính thức.

---

## Team

| Vai trò | Tên |
|---|---|
| Lead & Infra | Tom Nguyen |
| Backend + Config | Quang |
