# Cấu hình nâng cao & Các Option tích hợp LMS - BigBlueButton (BBB)

Tài liệu này tổng hợp các biến cấu hình `.env` mở rộng và tham số API giúp tối ưu hóa phòng học trực tuyến, quản lý tính năng (ghi âm, phát biểu, webcam, tài liệu, webhook).

---

## 1. Các cấu hình mở rộng trong `.env` (Laravel LMS)

Dưới đây là các cấu hình khuyên dùng để thêm vào `.env` của Laravel giúp kiểm soát linh hoạt hành vi phòng học mà không cần sửa code cứng:

```dotenv
# --- Cấu hình ghi hình tự động ---
# Tự động ghi âm khi lớp học bắt đầu (true/false)
BBB_AUTO_START_RECORDING=true
# Cho phép giáo viên tạm dừng/tiếp tục ghi âm trong lớp (true/false)
BBB_ALLOW_START_STOP_RECORDING=true

# --- Cấu hình âm thanh/video ban đầu ---
# Tự động tắt mic của tất cả mọi người khi mới join (true/false)
BBB_MUTE_ON_START=true
# Khóa camera của học viên ngay khi join, chỉ giáo viên mới có thể mở (true/false)
BBB_LOCK_CAM_FOR_STUDENTS=false
# Khóa mic của học viên, chỉ giáo viên mới có thể unmute (true/false)
BBB_LOCK_MIC_FOR_STUDENTS=false

# --- Cấu hình tính năng trong lớp ---
# Cho phép học viên nhắn tin riêng với nhau (true/false)
BBB_ALLOW_PRIVATE_CHAT=true
# URL điều hướng người dùng về sau khi kết thúc buổi học hoặc bấm Logout
BBB_LOGOUT_URL=https://your-lms-domain.com/trungtam/lop-hoc

# --- Cấu hình webhook thời gian thực (nếu cài bbb-webhooks) ---
BBB_WEBHOOK_CALLBACK_URL=https://your-lms-domain.com/api/v1/bbb/webhooks
```

---

## 2. Áp dụng vào hàm tạo phòng (`create` API)

Khi viết hàm `createMeeting` trong `BbbService.php`, **Quang** nên map các biến cấu hình trên vào mảng tham số gửi đi:

```php
$params = [
    'meetingID' => $meetingId,
    'name' => $name,
    'attendeePW' => $attendeePw,
    'moderatorPW' => $moderatorPw,
    
    // Ghi âm
    'record' => 'true', 
    'autoStartRecording' => config('bbb.auto_start_recording', true) ? 'true' : 'false',
    'allowStartStopRecording' => config('bbb.allow_start_stop_recording', true) ? 'true' : 'false',
    
    // Cấu hình mic/cam ban đầu
    'muteOnStart' => config('bbb.mute_on_start', true) ? 'true' : 'false',
    
    // Khóa tính năng đối với học viên (Viewer)
    'lockSettingsDisableCam' => config('bbb.lock_cam_for_students', false) ? 'true' : 'false',
    'lockSettingsDisableMic' => config('bbb.lock_mic_for_students', false) ? 'true' : 'false',
    'lockSettingsDisablePrivateChat' => config('bbb.allow_private_chat', true) ? 'false' : 'true',
    
    // URL chuyển hướng khi logout
    'logoutURL' => config('bbb.logout_url', route('home')),
];
```

---

## 3. Tự động nạp tài liệu giảng dạy lên slide (Pre-upload Slides)

Một tính năng cực kỳ mạnh mẽ của BBB là cho phép hiển thị sẵn file slide (PDF/Word/PPT) ngay khi giáo viên bước vào phòng, không cần đợi giáo viên nhấn nút upload thủ công.

### Cách triển khai:
LMS gửi thêm nút XML chứa link tải file tài liệu khi gọi API `create`. BBB sẽ tự động tải file này về và convert thành slide.

**Ví dụ định dạng payload gửi kèm API `create`:**
Để gửi tài liệu, ta truyền thêm parameter `preUploadedPresentation` dưới dạng XML URL-encoded hoặc truyền trực tiếp qua POST request body:

```xml
<modules>
  <module name="presentation">
    <document url="https://your-lms-domain.com/storage/materials/bai_hoc_so_1.pdf" filename="bai_hoc_so_1.pdf" />
  </module>
</modules>
```

**Trong code PHP:**
```php
// Thêm tham số này vào API create
$params['preUploadedPresentation'] = urlencode(
    '<modules><module name="presentation"><document url="' . $materialUrl . '" filename="' . $filename . '" /></module></modules>'
);
```

---

## 4. Xử lý webhook realtime (Webhooks vs. Polling)

Mặc định, ta dùng cron job quét API để lấy link recording. Tuy nhiên, nếu cài thêm package `bbb-webhooks` trên server BBB, ta có thể nhận sự kiện realtime.

### Các event hữu ích:
1.  `meeting_created`: Lớp học bắt đầu được tạo.
2.  `user_joined` / `user_left`: Điểm danh thời gian thực (LMS ghi nhận chính xác thời gian vào/ra lớp của từng học viên).
3.  `meeting_ended`: Giáo viên kết thúc lớp.
4.  `recording_ready`: File ghi hình đã render xong, LMS có thể lập tức cập nhật link xem lại mà không cần đợi cron job hàng giờ.

**Quang** có thể viết một Controller xử lý webhook nhận POST request từ BBB gửi về `BBB_WEBHOOK_CALLBACK_URL`:

```php
public function handleWebhook(Request $request)
{
    $eventData = json_decode($request->input('event'), true);
    
    if ($eventData['header']['name'] === 'meeting_ended') {
        $meetingId = $eventData['payload']['meeting_id'];
        // Ghi nhận trạng thái lớp học đã kết thúc vào DB
    }
    
    if ($eventData['header']['name'] === 'recording_ready') {
        $meetingId = $eventData['payload']['meeting_id'];
        $playUrl = $eventData['payload']['play_url'];
        // Lưu playUrl vào DB và hiển thị cho học sinh xem lại
    }
    
    return response()->json(['status' => 'ok']);
}
```

---

## 5. Xem lịch rảnh/bận của Server (Kiểm tra tải hệ thống)

BBB là media server rất nặng. Để tránh việc xếp quá nhiều lớp trực tuyến diễn ra cùng một thời điểm gây sập server, LMS cần kiểm tra tải trước khi cho phép tạo lớp mới.

### Cách triển khai:
Trước khi tạo phòng mới, gọi API `getMeetings` để lấy danh sách các phòng đang chạy và số lượng user đang online:

```php
public function getServerLoadInfo(): array
{
    $url = $this->buildUrl('getMeetings', []);
    $response = Http::get($url);
    
    $activeMeetingsCount = 0;
    $totalParticipantsCount = 0;
    
    if ($response->successful()) {
        $xml = simplexml_load_string($response->body());
        if ($xml->returncode === 'SUCCESS' && isset($xml->meetings->meeting)) {
            $activeMeetingsCount = count($xml->meetings->meeting);
            foreach ($xml->meetings->meeting as $meeting) {
                $totalParticipantsCount += (int) $meeting->participantCount;
            }
        }
    }
    
    return [
        'active_rooms' => $activeMeetingsCount,
        'total_users' => $totalParticipantsCount,
        // Cảnh báo nếu số người online vượt ngưỡng chịu tải (ví dụ 80 người với server 16GB RAM)
        'is_overloaded' => $totalParticipantsCount > 80, 
    ];
}
```

LMS có thể kiểm tra: Nếu `is_overloaded === true`, hiển thị thông báo khuyên giáo viên dời lịch học hoặc chuyển sang platform khác (như Zoom) để đảm bảo chất lượng đường truyền.
