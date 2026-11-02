# LG V50 ThinQ 5G - Safe Wired Screen Mirroring (1:1) Restoration

> **Phục hồi khả năng phản chiếu màn hình có dây 1:1 (Wired Screen Mirroring qua DisplayPort Alt Mode / Type-C) trên LG V50 ThinQ 5G (`LM-V500`) chạy LineageOS 20 (Android 13, Shark Kernel 4.14.215) với cơ chế bảo vệ an toàn điện áp PMIC PM8150B.**

[![Device](https://img.shields.io/badge/Device-LG%20V50%20(LM--V500)-blue.svg)](#)
[![SoC](https://img.shields.io/badge/SoC-Snapdragon%20855-orange.svg)](#)
[![Root](https://img.shields.io/badge/Root-Magisk%20Root-red.svg)](#)
[![Safety](https://img.shields.io/badge/PM8150B-Protected-success.svg)](#)

---

## 📌 Cơ chế phần cứng & Kiến trúc an toàn (Milestone 2)

Trên ROM gốc LG UX, phần cứng xuất màn hình hoạt động bình thường. Nhưng trên Custom ROM LineageOS 20:
1. **Chuyển mạch SBU (Auxiliary Differential Pairs)**: LG V50 sử dụng 2 chân GPIO phần cứng rời: **GPIO 119** (bật công tắc SBU / nguồn LDO EDID) và **GPIO 87** (đảo cực CC1/CC2). Driver mặc định của kernel đóng băng SBU (`GPIO 119 = 0`), khiến tín hiệu AUX không thông mạch sang màn hình rời.
2. **Khóa liên động an toàn điện áp PMIC PM8150B**: 
   - Tuyệt đối **KHÔNG can thiệp lúc khởi động sớm (early-boot)**: can thiệp boot sớm sẽ làm crash `vendor.lineage.livedisplay@2.1-service.lge_msmnile` dẫn đến init SIGABRT và Magisk bật Safe Mode.
   - Tuyệt đối **KHÔNG cưỡng ép VCONN (`powers_vconn = y`) khi chưa có thiết bị hoặc khi cắm vào máy tính (PC USB Host)**: xung đột điện áp 5V VBUS từ máy tính sẽ kích hoạt mạch ngắt khẩn cấp của chip sạc PM8150B (`VBUS : lowered`, `hard_reset`) làm sập nguồn phần cứng (hard reboot).

---

## 🔌 Yêu cầu kết nối phần cứng

Sử dụng cáp Type-C sang HDMI/DisplayPort hoặc Hub USB-C:

```text
[ Củ sạc Type-C PD (30W - 65W) ]
                |
                v (Cắm vào cổng PD-IN của Hub nếu cần sạc)
   +--------------------------+
   |   Hub USB-C đa năng      |====== Cáp HDMI/DP ======> [ Màn hình rời / TV ]
   +--------------------------+
                ^
                | (Cắm đầu cáp Type-C của Hub vào điện thoại)
        [ LG V50 ThinQ 5G ]
```

---

## 🚀 Hướng dẫn vận hành an toàn (Runtime / On-Demand)

### Cách 1: Sử dụng công cụ tương tác trên Windows (`install.bat`)
1. Kết nối điện thoại với máy tính qua Wi-Fi ADB (`adb connect 192.168.100.33:5555`) hoặc cáp USB.
2. Nhấp đúp chuột vào file **`install.bat`**.
3. Chọn:
   - `[1]`: Kích hoạt xuất màn hình 1:1 ngay lập tức (`manual-on`).
   - `[2]`: Khởi chạy dịch vụ Daemon nền tự động kích hoạt khi cắm cáp (`start`).
   - `[3]`: Kiểm tra trạng thái kết nối và an toàn điện áp PM8150B (`status`).
   - `[4]`: Dừng dịch vụ và khôi phục phần cứng về mặc định (`stop`).

### Cách 2: Chạy trực tiếp qua ADB Shell (Linux/macOS/Windows)
```bash
# Đẩy script an toàn vào thiết bị
adb push scripts/v50_safe_mirror.sh /data/local/tmp/v50_safe_mirror.sh
adb shell "su -c 'chmod 755 /data/local/tmp/v50_safe_mirror.sh'"

# Khởi chạy daemon nền
adb shell "su -c '/data/local/tmp/v50_safe_mirror.sh start'"

# Xem trạng thái
adb shell "su -c '/data/local/tmp/v50_safe_mirror.sh status'"

# Dừng dịch vụ
adb shell "su -c '/data/local/tmp/v50_safe_mirror.sh stop'"
```

---

## 🛠 Danh mục tệp tin

* **`scripts/v50_safe_mirror.sh`**: Kịch bản quản trị an toàn thời gian chạy (Runtime Controller) tích hợp khóa an toàn điện áp PM8150B, bảo vệ LiveDisplay, và phản chiếu màn hình 1:1 native.
* **`lg-v50-dp-altmode-fix/install.bat`**: Giao diện tương tác 1-Click an toàn cho người dùng Windows.
* **`lg-v50-dp-altmode-fix/v50_dp_fix.sh`**: Wrapper điều hướng an toàn sang `v50_safe_mirror.sh`.
* **`lg-v50-dp-altmode-fix/v50_dp_altmode_desktop.zip`**: Gói Magisk an toàn đã vô hiệu hóa boot-hook, bảo vệ thiết bị.

---

## 📄 Bản quyền (License)
Dự án phát hành theo giấy phép [MIT License](./LICENSE).
