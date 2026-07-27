# BigBlueButton Center Theme

Theme này hỗ trợ BigBlueButton 3.0 và chỉ sử dụng các file override trong
`/etc/bigbluebutton` cùng asset tĩnh dưới `/var/www/bigbluebutton-default/site`.
Không chỉnh sửa bundle HTML5 hoặc file cấu hình thuộc package BBB.

## Cấu hình thương hiệu

Cập nhật `theme/branding.json` trước khi áp dụng:

```json
{
  "center_name": "Edura",
  "client_title": "Edura - Phòng học trực tuyến",
  "copyright": "© 2026 Edura",
  "hotline": "0914 491 211",
  "support_email": "cskh@edura.vn",
  "colors": {
    "primary": "#dc2626",
    "secondary": "#991b1b",
    "background": "#f8fafc",
    "text": "#1e293b"
  }
}
```

Các trường chuỗi phải có giá trị và màu phải dùng định dạng `#RRGGBB`.

## Áp dụng

```bash
sudo bash scripts/apply-theme.sh
```

Script tự lấy domain từ `bbb-conf --secret`. Có thể ghi đè khi cần:

```bash
sudo env BBB_DOMAIN=bbb.example.com bash scripts/apply-theme.sh
```

Khi cài đặt thành công, script tạo:

- `/etc/bigbluebutton/edura-theme`
- Snapshot các key cấu hình bị theme quản lý trong
  `/etc/bigbluebutton/edura-theme/previous-config.json`
- `/etc/bigbluebutton/nginx/edura-branding.nginx`
- Các override cần thiết trong `/etc/bigbluebutton/bbb-html5.yml`
- Welcome message và footer trong `/etc/bigbluebutton/bbb-web.properties`
- Slide mở đầu mặc định từ `theme/slide-1.png`
- CSS và metadata thương hiệu cho trang playback bản ghi
- Locale tiếng Việt cho trạng thái lỗi, kết thúc và mất kết nối
- Hook trong `/etc/bigbluebutton/bbb-conf/apply-config.sh`

Hook gọi lại script với `--no-restart` sau khi BBB được nâng cấp.

Logo và thông tin hỗ trợ trong sidebar dùng selector
`data-test="messageTitle"` của BBB 3.0. Cần kiểm tra lại selector này sau mỗi
lần nâng cấp major/minor HTML5 client.

Error screen của HTML5 client dùng `data-test="errorScreenMessage"` để hiển thị
logo và thông tin hỗ trợ. Theme cũng áp dụng locale `vi-VN` và bổ sung các thông
báo phòng không tồn tại, hết hạn, bị từ chối, mất kết nối và kết thúc buổi học.
Locale được lưu bản gốc để script gỡ theme có thể khôi phục.

Playback error dùng `#error` và `.error-wrapper`. Khi recording đang xử lý,
không tồn tại hoặc tải thất bại, người dùng sẽ thấy thông báo Edura thay vì chỉ
một mã lỗi kỹ thuật.

## Kiểm tra

```bash
sudo nginx -t
sudo bbb-conf --check
curl -I https://bbb.example.com/branding/custom.css
curl -I https://bbb.example.com/branding/playback.css
curl -I https://bbb.example.com/logo.png
curl -I https://bbb.example.com/favicon.ico
curl -I https://bbb.example.com/branding/slide-1.png
```

Tạo một meeting mới sau khi áp dụng để kiểm tra welcome message, footer, slide
mở đầu và giao diện HTML5. Meeting đã tồn tại giữ welcome message và
presentation cũ.

Mở một recording đã publish để kiểm tra tiêu đề
`Edura - Xem lại bài giảng`, favicon, màu điều khiển, logo và thông tin hỗ trợ.
Script chỉ chèn stylesheet riêng vào playback page, không commit hoặc thay thế
bundle JavaScript/CSS đã build của package BBB.

Theme hiển thị logo trực tiếp từ asset phía server. LMS và các trang test không
truyền thêm tham số `logo` trong request `create`; nếu truyền, BBB sẽ mở thêm
branding area và hiển thị logo lần thứ hai.

Hotline trong footer được lấy từ `defaultWelcomeMessageFooter`. Để hotline
hiển thị ở banner phía trên phòng, request `create` của LMS cần truyền
`bannerText` và `bannerColor`; BBB không có cấu hình server mặc định tương ứng
cho mọi meeting.

## Gỡ theme

```bash
sudo bash scripts/remove-theme.sh
```

Script gỡ asset, Nginx override và hook do theme tạo. Các key HTML5 và welcome
message được khôi phục về giá trị trước lần cài đầu tiên, sau đó Nginx được
kiểm tra trước khi restart BBB.
