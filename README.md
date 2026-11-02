# LG V50 ThinQ 5G - DisplayPort Alt Mode & Desktop Mode Fix

> **Phục hồi khả năng xuất màn hình rời (HDMI / DisplayPort over Type-C) và giao diện AOSP Desktop Mode trên LG V50 ThinQ 5G (`LM-V500`) chạy Custom ROM (LineageOS 20, AOSP Android 12/13/14).**

[![Device](https://img.shields.io/badge/Device-LG%20V50%20(LM--V500)-blue.svg)](#)
[![SoC](https://img.shields.io/badge/SoC-Snapdragon%20855-orange.svg)](#)
[![Root](https://img.shields.io/badge/Root-Magisk%20%2F%20KernelSU-red.svg)](#)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](#)

---

## 📌 Nguyên nhân & Bản chất lỗi trên ROM Custom

Trên ROM gốc LG UX, máy xuất màn hình bình thường. Nhưng khi lên Custom ROM (như LineageOS), tính năng này biến mất do 2 nguyên nhân phần cứng:
1. **Mạch chuyển mạch SBU bị ngắt**: LG V50 không dùng chip tự động `FSA4480` như máy khác mà dùng 2 chân vi mạch riêng: **GPIO 119** (bật nguồn cổng AUX/EDID) và **GPIO 87** (đảo chiều cáp Type-C). Trên Custom ROM, driver của LG bị vô hiệu hóa khiến **GPIO 119 luôn tắt (`0`)**, làm màn hình ngoài không thể đọc được tín hiệu nhận diện.
2. **Thiếu nguồn VCONN**: Chip sạc PM8150B yêu cầu một hợp đồng sạc USB-PD rõ ràng để cấp nguồn 5V VCONN cho chip chuyển đổi HDMI trong sợi cáp.

---

## 🔌 Yêu cầu kết nối phần cứng (Rất quan trọng!)

Bạn **bắt buộc phải sử dụng Hub/Dock USB-C đa năng có cổng cắm sạc Type-C PD** (như Ugreen, Anker, Baseus, Dell, v.v.):

```text
[ Củ sạc Type-C PD (30W - 65W) ]
                |
                v (Cắm vào cổng sạc PD-IN của Hub)
   +--------------------------+
   |   Hub USB-C đa năng      |====== Cáp HDMI/DP ======> [ Màn hình rời / TV ]
   +--------------------------+
                ^
                | (Cắm đầu cáp Type-C của Hub vào điện thoại)
        [ LG V50 ThinQ 5G ]
```

---

## 🚀 Hướng dẫn cài đặt (Chọn 1 trong 2 cách)

### Cách 1: Flash trực tiếp qua ứng dụng Magisk trên điện thoại (Nhanh nhất)
1. Tải file **[`v50_dp_altmode_desktop.zip`](./v50_dp_altmode_desktop.zip)** về điện thoại.
2. Mở ứng dụng **Magisk** $\rightarrow$ chọn tab **Mô-đun (Modules)**.
3. Chọn **Cài đặt từ bộ nhớ** $\rightarrow$ chọn file `v50_dp_altmode_desktop.zip`.
4. Khởi động lại máy. Từ bây giờ, tính năng xuất màn hình sẽ tự động kích hoạt mỗi khi mở máy!

---

### Cách 2: Cài đặt 1-Click từ máy tính (Windows)
1. Kết nối LG V50 với máy tính qua cáp USB (hoặc kết nối qua ADB Wi-Fi).
2. Nhấp đúp chuột vào file **`install.bat`**.
3. Chọn:
   - Phím `1`: Kích hoạt xuất màn hình **ngay lập tức** (không cần khởi động lại máy).
   - Phím `2`: Cài đặt **tự chạy vĩnh viễn** mỗi khi khởi động lại máy.

---

## 🛠 Thư mục dự án bao gồm

* **`v50_dp_fix.sh`**: Kịch bản All-in-One chạy trực tiếp trên điện thoại (tự động unbind driver cũ, bật GPIO 119=1, cấp VCONN và mở AOSP Desktop Mode).
* **`v50_dp_altmode_desktop.zip`**: Module Magisk hoàn chỉnh đóng gói sẵn để flash.
* **`install.bat`**: Công cụ cài đặt tự động 1-click cho máy tính Windows.

---

## 📄 Bản quyền (License)

Dự án phát hành theo giấy phép [MIT License](./LICENSE). Tự do sử dụng, chỉnh sửa và chia sẻ cho cộng đồng người dùng LG V50 ThinQ.
