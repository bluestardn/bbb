# Hướng dẫn tích hợp LMS Laravel với BigBlueButton (BBB)

Tài liệu này hướng dẫn các nhà phát triển tích hợp hệ thống LMS hiện tại (Laravel) với máy chủ BigBlueButton (BBB).

---

## 1. Cấu hình file `.env` của Laravel

```dotenv
BBB_SERVER_BASE_URL=https://bbb.your-domain.com/bigbluebutton/api/
BBB_SECURITY_SALT=your_bbb_security_salt_here
```

---

## 2. Cách tính toán Checksum (Mã xác thực)

Tất cả các API request gửi đến BBB đều bắt buộc phải kèm theo tham số `checksum`. Checksum được tạo bằng cách băm chuỗi kết hợp theo thuật toán SHA1:

$$\text{checksum} = \text{sha1}(\text{action} + \text{query\_string} + \text{shared\_secret})$$

*   `action`: Tên hàm API (ví dụ: `create`, `join`, `end`).
*   `query_string`: Các tham số truyền vào (ví dụ: `meetingID=123&name=LopHoc`). Lưu ý các tham số cần được sắp xếp theo thứ tự bảng chữ cái hoặc theo đúng thứ tự lúc ghép chuỗi để khớp với checksum.
*   `shared_secret`: Khóa bảo mật lấy từ lệnh `bbb-conf --secret` trên server BBB.

### Ví dụ code PHP tính Checksum:

```php
public function generateChecksum(string $action, array $params, string $secret): string
{
    // Sắp xếp các tham số theo key để đảm bảo tính nhất quán
    ksort($params);
    $queryString = http_build_query($params);
    return sha1($action . $queryString . $secret);
}
```

---

## 3. Các API cần thiết

### A. API Tạo Phòng (`create`)
*   **Mục đích:** Khởi tạo phòng học. API này có tính chất **idempotent** (gọi nhiều lần với cùng `meetingID` sẽ không làm mất phòng cũ mà chỉ trả về trạng thái của phòng đó). Do đó, LMS có thể gọi API này mỗi khi có người nhấn nút "Vào lớp" để đảm bảo phòng luôn sẵn sàng.
*   **Tham số chính:**
    *   `meetingID`: Mã duy nhất định danh buổi học (ví dụ: `lhp_session_{id}`).
    *   `name`: Tên lớp học hiển thị cho user.
    *   `moderatorPW`: Mật khẩu cho Giáo viên (ví dụ: `mp`).
    *   `attendeePW`: Mật khẩu cho Học viên (ví dụ: `ap`).
    *   `record`: `true` (nếu muốn tự động bật tính năng ghi hình lớp học).

### B. API Tham Gia Phòng (`join`)
*   **Mục đích:** Lấy URL cho người dùng truy cập.
*   **Tham số chính:**
    *   `meetingID`: Định danh phòng đã tạo.
    *   `fullName`: Tên hiển thị của học viên/giáo viên khi vào phòng.
    *   `password`: Truyền `moderatorPW` để vào với quyền giáo viên (Moderator), truyền `attendeePW` để vào với quyền học viên (Viewer).
    *   `redirect`: `true` (mặc định, trình duyệt tự động nhảy vào phòng).

### C. API Kết Thúc Phòng (`end`)
*   **Mục đích:** Giáo viên chủ động kết thúc phòng học, kick toàn bộ học viên ra ngoài.
*   **Tham số chính:**
    *   `meetingID`: Định danh phòng cần đóng.
    *   `password`: Mật khẩu giáo viên (`moderatorPW`).

---

## 4. Flutter Integration (Dành cho Tuấn)

Đối với ứng dụng di động Flutter:
1.  **Luồng hoạt động:** 
    App di động gọi lên API Laravel của LMS (`/api/v1/live-sessions/{id}/join`) → Laravel xử lý kiểm tra thời gian học sinh được vào lớp → Tạo phòng BBB (nếu chưa chạy) → Trả về **Join URL** đầy đủ kèm checksum.
2.  **Khuyến nghị triển khai:**
    Sử dụng gói `url_launcher` trong Flutter để mở link trực tiếp bằng trình duyệt mặc định của hệ điều hành (Chrome trên Android / Safari trên iOS).
    *   **Tại sao?** Giúp bypass toàn bộ vấn đề cấp quyền Camera/Mic native trên điện thoại, đồng thời tận dụng tối đa khả năng tăng tốc phần cứng WebRTC của trình duyệt hệ thống.
3.  **Mẫu code Flutter:**
    ```dart
    import 'package:url_launcher/url_launcher.dart';

    Future<void> joinBbbClass(String joinUrl) async {
      final Uri url = Uri.parse(joinUrl);
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not launch $joinUrl');
      }
    }
    ```
