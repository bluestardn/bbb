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
sudo apt install -y git curl wget gnupg apt-transport-https ca-certificates

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
# Chạy script tùy biến giao diện
cd /opt/bbb
sudo bash scripts/apply-theme.sh
```

Script này sẽ:
- Đổi logo, favicon sang thương hiệu trung tâm
- Đổi màu sắc chủ đạo
- Bổ sung số hotline hỗ trợ
- Ẩn branding mặc định của BBB

### Bước 6 — Cấu hình Recording tự động lên Google Drive

```bash
# Copy file cấu hình
cp config/.env.example config/.env

# Sửa thông tin Google Drive
nano config/.env
```

Cấu hình cron job tự động upload:

```bash
# Đăng ký cron
sudo crontab -e

# Thêm dòng (chạy mỗi giờ)
0 * * * * /opt/bbb/scripts/sync-recordings.sh >> /var/log/bbb-recording-sync.log 2>&1
```

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
│   ├── bbb-web.properties     # Override cấu hình BBB web
│   ├── turnserver.conf        # Cấu hình Coturn mẫu
│   └── nginx-bbb.conf         # Override Nginx nếu cần
├── theme/
│   ├── logo.png               # Logo trung tâm
│   ├── favicon.ico            # Favicon
│   ├── custom.css             # CSS override giao diện
│   └── branding.json          # Tên, màu sắc, hotline
├── scripts/
│   ├── apply-theme.sh         # Script áp dụng theme lên BBB
│   ├── sync-recordings.sh     # Script đồng bộ recording → Google Drive
│   ├── backup-config.sh       # Backup cấu hình BBB
│   ├── test-api.sh            # Script test API nhanh
│   └── healthcheck.sh         # Kiểm tra trạng thái server
└── docs/
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

Số hotline hỗ trợ kỹ thuật hiển thị trên giao diện BBB được cấu hình trong `theme/branding.json`.

---

## Team

| Vai trò | Tên |
|---|---|
| Lead & Infra | Tom Nguyen |
| Backend + Config | Quang |
