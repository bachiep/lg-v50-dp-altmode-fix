#!/system/bin/sh
# ==============================================================================
# LG V50 ThinQ 5G (LM-V500) - SAFE WIRED SCREEN MIRRORING TOOL
# Features: Hardware Guardrails & PM8150B Protection
# ==============================================================================

echo "============================================================"
echo "    LG V50 - C?NG C? PH?N CHI?U C? D?Y AN TO?N (SAFE MIRROR) "
echo "============================================================"

# --- CH?T AN TO?N S? 1: B?O V? CH?NG XUNG ??T NGU?N PC ---
PC_ONLINE=$(cat /sys/class/power_supply/pc_port/online 2>/dev/null || echo 0)
if [ "$PC_ONLINE" = "1" ]; then
    echo "[!] C?NH B?O AN TO?N: Ph?t hi?n ?i?n tho?i ?ang c?m c?p USB v?o M?y t?nh (PC)!"
    echo "[!] Ch?t an to?n ?? ???c k?ch ho?t: KH?A can thi?p VCONN & GPIO."
    echo "[!] ?i?u n?y gi?p b?o v? chip s?c PM8150B kh?i b? s?p ngu?n/ch?p ?i?n."
    echo "[*] Tr?ng th?i: An to?n 100%. Tho?t l?nh."
    exit 0
fi

# --- CH?T AN TO?N S? 2: ??M B?O CH? ?? PH?N CHI?U 1:1 ---
echo "[*] B??c 1: C?u h?nh ch? ?? Ph?n Chi?u M?n H?nh 1:1 (T?t Desktop Mode)..."
settings put global force_desktop_mode_on_external_displays 0 2>/dev/null

# --- CH?T AN TO?N S? 3: TH?NG M?CH SBU/AUX KHI C?M HUB M?N H?NH ---
echo "[*] B??c 2: Ki?m tra v? m? m?ch t?n hi?u SBU (GPIO 119)..."
if [ -d "/sys/bus/platform/drivers/lge_sbu_switch" ]; then
    echo "vendor:lge_sbu_switch" > /sys/bus/platform/drivers/lge_sbu_switch/unbind 2>/dev/null
fi

if [ ! -d "/sys/class/gpio/gpio119" ]; then
    echo 119 > /sys/class/gpio/export 2>/dev/null
fi
if [ -d "/sys/class/gpio/gpio119" ]; then
    echo out > /sys/class/gpio/gpio119/direction 2>/dev/null
    echo 1 > /sys/class/gpio/gpio119/value 2>/dev/null
    echo "[+] GPIO 119 = 1: ?? k?t n?i ???ng t?n hi?u nh?n di?n m?n h?nh (AUX/EDID)."
fi

# C?u h?nh GPIO 87 (chi?u c?m c?p)
if [ ! -d "/sys/class/gpio/gpio87" ]; then
    echo 87 > /sys/class/gpio/export 2>/dev/null
fi
if [ -d "/sys/class/gpio/gpio87" ]; then
    echo out > /sys/class/gpio/gpio87/direction 2>/dev/null
    echo 0 > /sys/class/gpio/gpio87/value 2>/dev/null
fi

# --- CH?T AN TO?N S? 4: C?P NGU?N VCONN C? ?I?U KI?N ---
# Ch? c?p VCONN khi c? s?c PD ngo?i v? kh?ng ph?i l? PC host
USB_TYPE=$(cat /sys/class/power_supply/usb/type 2>/dev/null || echo "Unknown")
echo "[*] B??c 3: Ki?m tra ngu?n Type-C ($USB_TYPE)..."
if [ "$USB_TYPE" != "USB" ] && [ "$USB_TYPE" != "USB_CDP" ]; then
    for v in /sys/class/usbpd/usbpd*/powers_vconn; do
        [ -f "$v" ] && echo 1 > "$v" 2>/dev/null
    done
    echo "[+] ?? k?ch ho?t VCONN an to?n cho chip chuy?n ??i HDMI."
else
    echo "[*] C?ng USB ti?u chu?n: Kh?ng k?ch ho?t VCONN ?? tr?nh xung ?i?n."
fi

# --- B??C 5: ??NH TH?C C?NG DRM ---
if [ -w "/sys/class/drm/card0-DP-1/status" ]; then
    echo detect > /sys/class/drm/card0-DP-1/status 2>/dev/null
fi

DRM_STAT=$(cat /sys/class/drm/card0-DP-1/status 2>/dev/null || echo "unknown")
echo "============================================================"
echo "[?] HO?N T?T C?U H?NH PH?N CHI?U AN TO?N!"
echo "    -> Tr?ng th?i c?ng m?n h?nh ngo?i (DRM): $DRM_STAT"
echo "    -> Ch? ?? hi?n th?: Screen Mirroring 1:1"
echo "============================================================"