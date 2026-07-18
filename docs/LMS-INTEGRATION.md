# Hướng dẫn tích hợp LMS Laravel với BigBlueButton (BBB)

Tài liệu này hướng dẫn các nhà phát triển tích hợp hệ thống LMS hiện tại (Laravel) với máy chủ BigBlueButton (BBB).

---

## 1. Cấu hình file `.env` của Laravel

```dotenv
BBB_SERVER_BASE_URL=https://bbb.your-domain.com/bigbluebutton/api/
BBB_SECURITY_SALT=your_bbb_security_salt_here
```

---

## 2. File cấu hình Laravel: `config/bbb.php`

**Quang** tạo file `config/bbb.php` với nội dung dưới đây để load cấu hình từ `.env`:

```php
<?php

return [
    'base_url' => env('BBB_SERVER_BASE_URL'),
    'security_salt' => env('BBB_SECURITY_SALT'),
];
```

---

## 3. Database Migration

**Quang** tạo file migration bằng lệnh:
```bash
php artisan make:migration add_bbb_to_online_session_platform
```

Nội dung file migration:
```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (!Schema::hasTable('table_center_online_session')
            || !Schema::hasColumn('table_center_online_session', 'meeting_platform')) {
            return;
        }

        // Cập nhật enum để thêm giá trị 'bbb'
        DB::statement(
            "ALTER TABLE table_center_online_session MODIFY COLUMN meeting_platform "
            . "ENUM('zoom','google_meet','webrtc','external','jitsi','bbb') NOT NULL DEFAULT 'external'"
        );
    }

    public function down(): void
    {
        if (!Schema::hasTable('table_center_online_session')) {
            return;
        }

        // Đưa các session có platform là 'bbb' về 'external' trước khi xóa giá trị enum
        DB::table('table_center_online_session')
            ->where('meeting_platform', 'bbb')
            ->update([
                'meeting_platform' => 'external',
                'updated_at' => now(),
            ]);

        DB::statement(
            "ALTER TABLE table_center_online_session MODIFY COLUMN meeting_platform "
            . "ENUM('zoom','google_meet','webrtc','external','jitsi') NOT NULL DEFAULT 'external'"
        );
    }
};
```

---

## 4. Code mẫu `app/Services/BbbService.php`

**Quang** tạo file `app/Services/BbbService.php` để đóng gói các hàm tương tác API.

```php
<?php

namespace App\Services;

use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

class BbbService
{
    private string $baseUrl;
    private string $salt;

    public function __construct()
    {
        $this->baseUrl = rtrim(config('bbb.base_url', ''), '/') . '/';
        $this->salt = config('bbb.security_salt', '');
    }

    /**
     * Kiểm tra service đã được cấu hình chưa.
     */
    public function isConfigured(): bool
    {
        return !empty($this->baseUrl) && !empty($this->salt);
    }

    /**
     * Tạo mã xác thực checksum SHA1.
     */
    private function generateChecksum(string $action, string $queryString): string
    {
        return sha1($action . $queryString . $this->salt);
    }

    /**
     * Build URL hoàn chỉnh gửi tới BBB.
     */
    private function buildUrl(string $action, array $params): string
    {
        ksort($params);
        $queryString = http_build_query($params);
        $checksum = $this->generateChecksum($action, $queryString);
        return $this->baseUrl . $action . '?' . $queryString . '&checksum=' . $checksum;
    }

    /**
     * Tạo phòng học (idempotent API).
     */
    public function createMeeting(string $meetingId, string $name, string $attendeePw, string $moderatorPw): bool
    {
        if (!$this->isConfigured()) return false;

        $params = [
            'meetingID' => $meetingId,
            'name' => $name,
            'attendeePW' => $attendeePw,
            'moderatorPW' => $moderatorPw,
            'record' => 'true', // Mặc định tự động ghi hình
            'autoStartRecording' => 'true',
            'allowStartStopRecording' => 'false',
        ];

        $url = $this->buildUrl('create', $params);

        try {
            $response = Http::get($url);
            if ($response->successful()) {
                $xml = simplexml_load_string($response->body());
                return (string) $xml->returncode === 'SUCCESS';
            }
        } catch (\Exception $e) {
            Log::error('BBB createMeeting error: ' . $e->getMessage());
        }

        return false;
    }

    /**
     * Lấy URL để người dùng join vào lớp.
     */
    public function getJoinUrl(string $meetingId, string $userName, string $password, string $userId): string
    {
        $params = [
            'meetingID' => $meetingId,
            'fullName' => $userName,
            'password' => $password,
            'userID' => $userId,
            'redirect' => 'true',
        ];

        return $this->buildUrl('join', $params);
    }

    /**
     * Kiểm tra phòng học có đang hoạt động không.
     */
    public function isMeetingRunning(string $meetingId): bool
    {
        if (!$this->isConfigured()) return false;

        $url = $this->buildUrl('isMeetingRunning', ['meetingID' => $meetingId]);

        try {
            $response = Http::get($url);
            if ($response->successful()) {
                $xml = simplexml_load_string($response->body());
                return (string) $xml->running === 'true';
            }
        } catch (\Exception $e) {
            Log::error('BBB isMeetingRunning error: ' . $e->getMessage());
        }

        return false;
    }

    /**
     * Đóng phòng học từ xa.
     */
    public function endMeeting(string $meetingId, string $moderatorPw): bool
    {
        if (!$this->isConfigured()) return false;

        $url = $this->buildUrl('end', [
            'meetingID' => $meetingId,
            'password' => $moderatorPw,
        ]);

        try {
            $response = Http::get($url);
            if ($response->successful()) {
                $xml = simplexml_load_string($response->body());
                return (string) $xml->returncode === 'SUCCESS';
            }
        } catch (\Exception $e) {
            Log::error('BBB endMeeting error: ' . $e->getMessage());
        }

        return false;
    }
}
```

---

## 5. Tích hợp với `MeetingAccessService.php`

**Quang** cập nhật logic trong hàm `getMeetingUrl` để xử lý chuyển hướng khi lớp học dùng BBB:

```php
use App\Services\BbbService;

// Khai báo Dependency Injection trong __construct
public function __construct(
    private readonly BbbService $bbbService,
    // ...
) {}

// Trong hàm getMeetingUrl(object $session, ?object $config = null, bool $isAdmin = false)
$platform = $session->meeting_platform ?? ($config ? $config->room_type : null) ?? 'external';

if ($platform === 'bbb') {
    return $this->buildBbbUrl($session, $isAdmin);
}

// Viết thêm hàm buildBbbUrl:
private function buildBbbUrl(object $session, bool $isTeacher): ?string
{
    if (!$this->bbbService->isConfigured()) {
        return null;
    }

    $meetingId = 'session_' . $session->id;
    $meetingName = $session->ten_lop ?? ('Lớp học ' . $meetingId);
    
    // Mật khẩu cố định hoặc sinh tự động theo thuật toán riêng của LMS
    $attendeePw = md5($meetingId . '_student');
    $moderatorPw = md5($meetingId . '_teacher');

    // Luôn đảm bảo phòng đã được tạo trước khi sinh Join URL
    $this->bbbService->createMeeting($meetingId, $meetingName, $attendeePw, $moderatorPw);

    $userEmail = session()->get('email') ?? session()->get('emailtrungtam') ?? 'guest';
    $userName = session()->get('ten') ?? session()->get('ho_ten') ?? $userEmail;
    
    $password = $isTeacher ? $moderatorPw : $attendeePw;

    return $this->bbbService->getJoinUrl($meetingId, $userName, $password, $userEmail);
}
```

---

## 6. Flutter Integration (Dành cho Tuấn)

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
