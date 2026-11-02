@echo off
chcp 65001 >nul
title LG V50 DisplayPort Alt Mode & Desktop Mode Fix
cls

echo ==============================================================================
echo        LG V50 THINQ 5G - CÔNG CỤ PHỤC HỒI XUẤT MÀN HÌNH RỜI
echo           (DisplayPort Alt Mode ^& Android Desktop Mode Fix)
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
echo Chọn hành động bạn muốn thực hiện:
echo   [1] Kích hoạt xuất màn hình NGAY LẬP TỨC (Không cần khởi động lại)
echo   [2] Cài đặt VĨNH VIỄN (Tự động kích hoạt mỗi khi khởi động máy - Magisk/KernelSU)
echo   [3] Thoát
echo.
set /p choice="Nhập lựa chọn của bạn (1-3): "

if "%choice%"=="1" goto ONESHOT
if "%choice%"=="2" goto PERSISTENT
if "%choice%"=="3" goto EXIT

echo [!] Lựa chọn không hợp lệ.
pause
exit /b 0

:ONESHOT
echo.
echo [*] Đang đẩy script vào thiết bị...
adb push "%~dp0v50_dp_fix.sh" /data/local/tmp/v50_dp_fix.sh >nul
adb shell "chmod 755 /data/local/tmp/v50_dp_fix.sh"
echo [*] Đang kích hoạt DisplayPort và Desktop Mode qua quyền Root...
adb shell "su -c 'sh /data/local/tmp/v50_dp_fix.sh'"
echo.
echo ==============================================================================
echo [✓] HOÀN TẤT! Hãy cắm Hub USB-C (có cắm nguồn sạc PD) vào điện thoại để xuất hình.
echo ==============================================================================
pause
exit /b 0

:PERSISTENT
echo.
echo [*] Đang cài đặt dịch vụ tự khởi động vào /data/adb/service.d/...
adb push "%~dp0v50_dp_fix.sh" /data/local/tmp/v50_dp_fix.sh >nul
adb shell "su -c 'mkdir -p /data/adb/service.d && cp /data/local/tmp/v50_dp_fix.sh /data/adb/service.d/99-v50-dp-fix.sh && chmod 755 /data/adb/service.d/99-v50-dp-fix.sh'"
echo [*] Đang chạy kích hoạt thử nghiệm lần đầu...
adb shell "su -c 'sh /data/adb/service.d/99-v50-dp-fix.sh'"
echo.
echo ==============================================================================
echo [✓] CÀI ĐẶT THÀNH CÔNG!
echo     Từ bây giờ, tính năng xuất màn hình sẽ tự động bật mỗi khi bạn khởi động máy.
echo     (Bạn cũng có thể nén file .zip trong thư mục này để flash qua app Magisk).
echo ==============================================================================
pause
exit /b 0

:EXIT
exit /b 0
