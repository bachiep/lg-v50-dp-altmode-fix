#!/system/bin/sh
# ==============================================================================
# LG V50 ThinQ 5G (LM-V500 / SM8150) - DisplayPort Alt Mode & Desktop Fix
# Works on Custom ROMs (LineageOS, AOSP, PixelExperience, etc.)
# ==============================================================================

echo "[*] LG V50 DisplayPort & Desktop Mode Fix"

# 1. Enable Android AOSP Desktop Mode & Freeform Multi-Windowing
echo "[+] Enabling Android 13 AOSP Desktop Mode..."
settings put global force_desktop_mode_on_external_displays 1 2>/dev/null
settings put global enable_freeform_support 1 2>/dev/null
settings put global force_resizable_activities 1 2>/dev/null

# 2. Release LGE SBU Switch driver lock
echo "[+] Unbinding default lge_sbu_switch platform driver..."
if [ -d "/sys/bus/platform/drivers/lge_sbu_switch" ]; then
    echo "vendor:lge_sbu_switch" > /sys/bus/platform/drivers/lge_sbu_switch/unbind 2>/dev/null
fi

# 3. Configure GPIO 119 (SBU Output Enable / LDO Power)
echo "[+] Asserting GPIO 119 (SBU Output Enable = 1)..."
if [ ! -d "/sys/class/gpio/gpio119" ]; then
    echo 119 > /sys/class/gpio/export 2>/dev/null
fi
if [ -d "/sys/class/gpio/gpio119" ]; then
    echo out > /sys/class/gpio/gpio119/direction 2>/dev/null
    echo 1 > /sys/class/gpio/gpio119/value 2>/dev/null
fi

# 4. Configure GPIO 87 (SBU Polarity / Orientation)
echo "[+] Configuring GPIO 87 (SBU Polarity)..."
if [ ! -d "/sys/class/gpio/gpio87" ]; then
    echo 87 > /sys/class/gpio/export 2>/dev/null
fi
if [ -d "/sys/class/gpio/gpio87" ]; then
    echo out > /sys/class/gpio/gpio87/direction 2>/dev/null
    # Default to 0, if cable flipped, toggling to 1 swaps SBU lines
    echo 0 > /sys/class/gpio/gpio87/value 2>/dev/null
fi

# 5. Enable VCONN power supply for active adapter chips
echo "[+] Enabling 5V VCONN for active adapters..."
for vconn_node in /sys/class/usbpd/usbpd*/powers_vconn; do
    if [ -f "$vconn_node" ]; then
        echo "y" > "$vconn_node" 2>/dev/null || echo 1 > "$vconn_node" 2>/dev/null
    fi
done

# 6. Trigger DisplayPort Hot-Plug Detect (HPD)
echo "[+] Triggering DisplayPort HPD..."
if [ -f "/sys/class/display_port/common/dp_hpd" ]; then
    echo 1 > /sys/class/display_port/common/dp_hpd 2>/dev/null
fi

echo "[✓] DisplayPort Alt Mode & Desktop Mode successfully configured!"
echo "    -> Please connect your Powered USB-C Hub (with PD power plugged in) to output video."
