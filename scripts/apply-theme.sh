#!/usr/bin/env bash

# ==============================================================================
# Script áp dụng Custom Theme & Hotline cho BigBlueButton
# Chạy với quyền sudo: sudo bash scripts/apply-theme.sh
# ==============================================================================

set -e

# Đọc cấu hình từ branding.json
BRANDING_FILE="/opt/bbb/theme/branding.json"
if [ ! -f "$BRANDING_FILE" ]; then
    echo "❌ Không tìm thấy file theme/branding.json!"
    exit 1
fi

HOTLINE=$(grep -o '"hotline": "[^"]*' "$BRANDING_FILE" | grep -o '[^"]*$')
CENTER_NAME=$(grep -o '"center_name": "[^"]*' "$BRANDING_FILE" | grep -o '[^"]*$')

echo "====== Đang áp dụng theme cho $CENTER_NAME (Hotline: $HOTLINE) ======"

# 1. Đổi logo mặc định trên trang ngoài (default landing page)
if [ -f "/opt/bbb/theme/logo.png" ]; then
    echo "-> Cập nhật logo trang chủ..."
    cp /opt/bbb/theme/logo.png /var/www/bigbluebutton-default/assets/images/logo.png
    cp /opt/bbb/theme/logo.png /var/www/bigbluebutton-default/logo.png || true
fi

# 2. Cập nhật Favicon
if [ -f "/opt/bbb/theme/favicon.ico" ]; then
    echo "-> Cập nhật favicon..."
    cp /opt/bbb/theme/favicon.ico /var/www/bigbluebutton-default/favicon.ico
fi

# 3. Tùy biến HTML5 client (nơi học trực tuyến diễn ra)
HTML5_ASSETS_DIR="/usr/share/meteor/bundle/programs/web.browser/app"
if [ -d "$HTML5_ASSETS_DIR" ]; then
    echo "-> Cập nhật logo & style trong lớp học HTML5 client..."
    
    # Copy logo vào thư mục assets của client
    cp /opt/bbb/theme/logo.png "$HTML5_ASSETS_DIR/resources/images/custom-logo.png" || true
    
    # Append custom CSS
    if [ -f "/opt/bbb/theme/custom.css" ]; then
        # Backup css gốc nếu chưa có backup
        if [ ! -f "$HTML5_ASSETS_DIR/head.html.bak" ]; then
            cp "$HTML5_ASSETS_DIR/head.html" "$HTML5_ASSETS_DIR/head.html.bak"
        fi
        
        # Tạo file css trong client
        cp /opt/bbb/theme/custom.css "$HTML5_ASSETS_DIR/custom-vku.css"
        
        # Inject stylesheet link vào head.html nếu chưa có
        if ! grep -q "custom-vku.css" "$HTML5_ASSETS_DIR/head.html"; then
            sed -i 's|</head>|<link rel="stylesheet" href="/html5client/custom-vku.css"></head>|g' "$HTML5_ASSETS_DIR/head.html"
        fi
    fi
else
    echo "⚠️ Không tìm thấy thư mục HTML5 Client ($HTML5_ASSETS_DIR), có thể phiên bản BBB này có cấu trúc khác."
fi

# 4. Thay đổi tiêu đề trang welcome
WELCOME_HTML="/var/www/bigbluebutton-default/index.html"
if [ -f "$WELCOME_HTML" ]; then
    echo "-> Cập nhật tiêu đề trang index..."
    sed -i "s|<title>.*</title>|<title>$CENTER_NAME - Phòng học trực tuyến</title>|g" "$WELCOME_HTML"
fi

# 5. Cấu hình Hotline trong file welcome message của lớp học
# File: /etc/bigbluebutton/bbb-web.properties
BBB_WEB_CONFIG="/etc/bigbluebutton/bbb-web.properties"
if [ -f "$BBB_WEB_CONFIG" ]; then
    echo "-> Cập nhật câu chào mừng mặc định khi vào phòng..."
    
    WELCOME_MSG="Chào mừng bạn đến với lớp học trực tuyến của <b>$CENTER_NAME</b>!<br><br>Để được hỗ trợ kỹ thuật, vui lòng gọi Hotline: <b>$HOTLINE</b>."
    
    # Escape các ký tự đặc biệt
    WELCOME_MSG_ESCAPED=$(echo "$WELCOME_MSG" | sed 's/\//\\\//g')
    
    sudo sed -i "s/defaultWelcomeMessage=.*/defaultWelcomeMessage=$WELCOME_MSG_ESCAPED/g" "$BBB_WEB_CONFIG"
fi

echo "-> Đang khởi động lại BBB để áp dụng thay đổi..."
sudo bbb-conf --restart

echo "✅ Đã áp dụng Custom Theme & Hotline thành công!"
