# Hướng dẫn cấu hình Google Drive & Rclone để lưu trữ Recording BBB

Tài liệu này dành cho **Quang** và **Lead** để cấu hình đồng bộ video ghi hình từ máy chủ BBB lên Google Drive tự động thông qua công cụ Rclone sử dụng **Google Service Account**.

---

## 1. Tạo Google Cloud Service Account (Lead / Quang thực hiện)

Vì server chạy tự động (cron job) nên ta sử dụng **Service Account** thay vì tài khoản cá nhân OAuth2 (để không bị hết hạn token).

### Bước 1: Tạo dự án và kích hoạt Drive API
1. Truy cập [Google Cloud Console](https://console.cloud.google.com/).
2. Tạo một Project mới (ví dụ: `vku-lms-bbb`).
3. Vào mục **API & Services** > **Library**, tìm kiếm **Google Drive API** và bấm **Enable**.

### Bước 2: Tạo Service Account
1. Vào mục **API & Services** > **Credentials**.
2. Chọn **Create Credentials** > **Service Account**.
3. Điền tên Service Account (ví dụ: `bbb-recording-uploader`) và bấm **Create**.
4. Các quyền truy cập (Role) có thể bỏ qua (hoặc để trống) rồi chọn **Done**.

### Bước 3: Tạo và tải về File Key JSON
1. Bấm vào Service Account vừa tạo trong danh sách.
2. Chọn tab **Keys** > **Add Key** > **Create new key**.
3. Chọn định dạng **JSON** rồi bấm **Create**.
4. Trình duyệt sẽ tải về một file `.json` (ví dụ: `vku-lms-bbb-xxxxxx.json`).
5. **Đổi tên file này thành `gdrive-service-account.json`** và lưu vào thư mục `/opt/bbb/config/` trên server BBB.

### Bước 4: Lấy Email của Service Account
1. Email có định dạng tương tự: `bbb-recording-uploader@vku-lms-bbb.iam.gserviceaccount.com`.
2. Copy email này.

---

## 2. Tạo Thư mục Google Drive lưu trữ và Chia sẻ quyền

1. Đăng nhập vào Google Drive cá nhân của trung tâm/trường học.
2. Tạo một thư mục mới (ví dụ: `BBB_Class_Recordings`).
3. Chuột phải vào thư mục > **Share** (Chia sẻ).
4. Dán **Email của Service Account** đã copy ở trên vào và cấp quyền **Editor** (Người chỉnh sửa).
5. Copy **ID của Thư mục** từ thanh địa chỉ URL:
   * URL dạng: `https://drive.google.com/drive/folders/1A2B3C4D5E6F7G8H9I0J`
   * ID Thư mục là: `1A2B3C4D5E6F7G8H9I0J`
6. Điền ID này vào biến `GDRIVE_FOLDER_ID` trong file `/opt/bbb/config/.env`.

---

## 3. Cấu hình Rclone trên Server BBB

### Bước 1: Cài đặt Rclone
```bash
sudo apt install -y rclone
```

### Bước 2: Tạo cấu hình cho Rclone
Tạo file `/opt/bbb/config/rclone.conf` với nội dung sau:

```ini
[gdrive]
type = drive
scope = drive
service_account_file = /opt/bbb/config/gdrive-service-account.json
```

---

## 4. Test đồng bộ thủ công

Để kiểm tra cấu hình rclone đã hoạt động chưa, chạy lệnh:

```bash
# Liệt kê danh sách thư mục/file trên Google Drive (thư mục được share với Service Account)
rclone lsd gdrive: --config="/opt/bbb/config/rclone.conf"

# Thử tạo 1 file test và upload lên thư mục được chỉ định
echo "test" > /tmp/test.txt
rclone copy /tmp/test.txt "gdrive:$GDRIVE_FOLDER_ID" --config="/opt/bbb/config/rclone.conf"
```

Nếu thành công, file `test.txt` sẽ xuất hiện trên Google Drive của bạn.
