@echo off
chcp 65001 >nul
title LG V50 Safe Wired Screen Mirroring (1:1) Controller
cls

echo ==============================================================================
echo        LG V50 THINQ 5G - CÔNG CỤ PHỤC HỒI XUẤT MÀN HÌNH RỜI (1:1 MIRROR)
echo        (DisplayPort Alt Mode ^& PM8150B Electrical Safety Interlock)
echo ==============================================================================
echo.

:: Check ADB
where adb >nul 2>nul
if %errorlevel% neq 0 (
    echo [!] Không tìm thấy lệnh ADB trên máy tính.
    echo     Vui lòng cài đặt Platform Tools hoặc chạy từ thư mục có adb.exe.
    pause
    exit /b 1
)

:: Check device connection
echo [*] Đang tìm kiếm thiết bị LG V50 qua ADB...
adb get-state >nul 2>nul
if %errorlevel% neq 0 (
    echo [!] Không tìm thấy thiết bị nào kết nối qua ADB.
    echo     Vui lòng bật 'Gỡ lỗi USB' hoặc kết nối 'adb connect ^<IP^>:5555'.
    echo.
    pause
    exit /b 1
)

echo [✓] Đã kết nối với thiết bị thành công!
echo.
echo [*] Đang đồng bộ kịch bản an toàn v50_safe_mirror.sh vào thiết bị...
adb push "%~dp0..\scripts\v50_safe_mirror.sh" /data/local/tmp/v50_safe_mirror.sh >nul
adb shell "su -c 'chmod 755 /data/local/tmp/v50_safe_mirror.sh; rm -f /data/adb/service.d/99-v50-dp-fix.sh 2>/dev/null'" >nul

echo.
echo ==============================================================================
echo Chọn hành động bạn muốn thực hiện (Runtime / On-Demand an toàn):
echo   [1] Kích hoạt xuất màn hình 1:1 NGAY LẬP TỨC (Manual Override On)
echo   [2] Khởi chạy dịch vụ Daemon giám sát cắm cáp an toàn ở nền (Daemon Start)
echo   [3] Kiểm tra trạng thái xuất hình và an toàn điện áp PM8150B (Status Check)
echo   [4] Dừng xuất hình và khôi phục phần cứng về mặc định (Stop ^& Teardown)
echo   [5] Thoát
echo ==============================================================================
echo Lưu ý: Theo tiêu chuẩn an toàn Milestone 2, hệ thống KHÔNG can thiệp lúc boot
echo để bảo vệ chip nguồn PM8150B và tránh crash LiveDisplay HAL.
echo ==============================================================================
echo.
set /p choice="Nhập lựa chọn của bạn (1-5): "

if "%choice%"=="1" goto MANUAL_ON
if "%choice%"=="2" goto DAEMON_START
if "%choice%"=="3" goto STATUS_CHECK
if "%choice%"=="4" goto STOP_ALL
if "%choice%"=="5" goto EXIT

echo [!] Lựa chọn không hợp lệ.
pause
exit /b 0

:MANUAL_ON
echo.
echo [*] Đang kích hoạt DisplayPort SBU và cấu hình phản chiếu màn hình 1:1...
adb shell "su -c '/data/local/tmp/v50_safe_mirror.sh manual-on'"
echo.
echo ==============================================================================
echo [✓] HOÀN TẤT! Hãy cắm cáp Type-C sang HDMI/DP hoặc Hub USB-C vào màn hình.
echo ==============================================================================
pause
exit /b 0

:DAEMON_START
echo.
echo [*] Đang khởi chạy daemon giám sát cắm cáp tự động ở chế độ nền...
adb shell "su -c '/data/local/tmp/v50_safe_mirror.sh start'"
echo.
echo ==============================================================================
echo [✓] Daemon đã được kích hoạt! Tự động bật SBU khi cắm dock/cáp DP.
echo ==============================================================================
pause
exit /b 0

:STATUS_CHECK
echo.
adb shell "su -c '/data/local/tmp/v50_safe_mirror.sh status'"
echo.
pause
exit /b 0

:STOP_ALL
echo.
echo [*] Đang dừng daemon và đưa phần cứng về trạng thái mặc định an toàn...
adb shell "su -c '/data/local/tmp/v50_safe_mirror.sh stop'"
echo.
echo ==============================================================================
echo [✓] Phần cứng đã được khôi phục an toàn.
echo ==============================================================================
pause
exit /b 0

:EXIT
exit /b 0
