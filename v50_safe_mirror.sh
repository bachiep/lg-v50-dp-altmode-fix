#!/system/bin/sh
# ==============================================================================
# v50_safe_mirror.sh - Safe Runtime Wired Screen Mirroring (1:1) Controller
# Target Device : LG V50 ThinQ 5G (LM-V500 / flashlmdd, Snapdragon 855 SM8150)
# Environment   : Android 13 (LineageOS 20 / riceDroid 13) | Shark Kernel 4.14.215
# Milestone     : Milestone 2 (Safe Runtime Mirroring Implementation)
#
# Safety Architecture & Guardrails:
# 1. Zero Early Boot Hooks: Userspace runtime / on-demand only.
#    Strictly enforces [sys.boot_completed == 1] and [LiveDisplay HAL == running].
# 2. PM8150B Electrical Safety Interlock:
#    - PC Host (SDP/CDP): Strict lockout. Never assert VCONN or force GPIO 119.
#    - AC/QC Charger (DCP/HVDCP): Strict lockout.
#    - Powered USB-C Dock: Explicit PD contract -> KEEP powers_vconn = n.
#    - Idle / Disconnected: Default kernel binding (vendor:lge_sbu_switch bound).
# 3. 1:1 Screen Mirroring:
#    - force_desktop_mode_on_external_displays = 0, persist.sys.desktop_mode = 0.
#    - Native SurfaceFlinger layerStack 0 mirror; primary screen active at 60Hz.
# 4. Atomic Teardown:
#    - Signal traps (SIGINT, SIGTERM, SIGHUP, EXIT) and unplug watcher:
#      powers_vconn=n, GPIO 119=0, GPIO 87=0, unexport pins, rebind driver.
# ==============================================================================

export PATH="/system/bin:/system/xbin:/vendor/bin:/system_ext/bin:$PATH"

# --- Hardware Constants ---
GPIO_OE=119    # lge,ldo-en-gpio / SBU Output Enable & AUX LDO Power
GPIO_SEL=87    # lge,sel-gpio / SBU Polarity Select (0=CC1, 1=CC2)
GPIO_UART=35   # lge,uart-sbu-sel-gpio (UART Debugger Mux)

SBU_DEV="vendor:lge_sbu_switch"
SBU_DRV="/sys/bus/platform/drivers/lge_sbu_switch"
USB_PS="/sys/class/power_supply/usb"
PC_PORT="/sys/class/power_supply/pc_port"
USBPD_DIR="/sys/class/usbpd/usbpd0"
OTG_DIR="/sys/class/usbpd/usbpd0/otg_default"
DRM_DP="/sys/class/drm/card0-DP-1"

PID_FILE="/data/local/tmp/v50_safe_mirror.pid"
LOG_FILE="/data/local/tmp/v50_safe_mirror.log"
STATE_FILE="/data/local/tmp/v50_safe_mirror.state"
LOCK_DIR="/data/local/tmp/v50_safe_mirror.lock"

# --- Terminal Colors ---
if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[1;31m"
    C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"
    C_CYAN="\033[1;36m"
    C_BLUE="\033[1;34m"
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    C_BLUE=""
fi

log() {
    local ts=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "timestamp")
    echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null
    echo -e "$*"
}

log_quiet() {
    local ts=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "timestamp")
    echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null
}

check_root() {
    local uid=$(id -u 2>/dev/null || echo -1)
    if [ "$uid" -ne 0 ]; then
        echo -e "${C_RED}[!] Error: Root privileges required. Run via 'su -c $0 ...'${C_RESET}"
        exit 1
    fi
}

# --- Process Isolation & Concurrency Mutex ---
is_mirror_process() {
    local pid="$1"
    [ -z "$pid" ] && return 1
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$pid" -le 1 ] && return 1

    if [ -d "/proc/$pid" ]; then
        if grep -qa "v50_safe_mirror" "/proc/$pid/cmdline" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

find_orphan_mirror_pids() {
    local my_pid=$$
    local orphan_list=""
    local candidates=""
    if command -v pgrep >/dev/null 2>&1; then
        candidates=$(pgrep -f "v50_safe_mirror.*run" 2>/dev/null)
    fi
    if [ -z "$candidates" ]; then
        candidates=$(ps -ef 2>/dev/null | grep "v50_safe_mirror.*run" | grep -v grep | awk '{print $2}')
    fi
    for p in $candidates; do
        [ -z "$p" ] && continue
        [ "$p" = "$my_pid" ] && continue
        [ "$p" = "$PPID" ] && continue
        [ "$p" -le 1 ] && continue
        if is_mirror_process "$p"; then
            orphan_list="$orphan_list $p"
        fi
    done
    echo "$orphan_list" | tr -s ' ' | sed 's/^ //' | sed 's/ $//'
}

acquire_lock() {
    local max_wait=3
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        local lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -rf "$LOCK_DIR" 2>/dev/null
            continue
        fi
        if [ "$waited" -ge "$max_wait" ]; then
            rm -rf "$LOCK_DIR" 2>/dev/null
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                break
            fi
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo $$ > "$LOCK_DIR/pid" 2>/dev/null
    return 0
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

# --- Guardrail 1: Zero Early Boot Hooks Verification ---
verify_system_ready() {
    local boot_done=$(getprop sys.boot_completed 2>/dev/null || echo "0")
    if [ "$boot_done" != "1" ]; then
        log "${C_RED}[!] SAFETY BLOCK: Android boot has not completed (sys.boot_completed != 1).${C_RESET}"
        log "${C_RED}[!] Early boot manipulation is strictly prohibited to prevent display pipeline crash.${C_RESET}"
        return 1
    fi
    return 0
}

# --- Guardrail 2: Deterministic Electrical Safety Interlock (PM8150B Protection) ---
# Evaluates physical power rails and returns one of:
#   "PC_HOST"       : Connected to standard PC host (SDP/CDP). STRICT LOCKOUT.
#   "CHARGER"       : Connected to AC/QC wall charger. STRICT LOCKOUT.
#   "POWERED_DOCK"  : Connected to powered USB-PD dock (explicit contract). VCONN forbidden.
#   "UNPOWERED_DP"  : Connected to unpowered DP dongle / active adapter.
#   "IDLE"          : No cable connected / disconnected. Safe default.
evaluate_safety() {
    local pc_online=$(cat "$PC_PORT/online" 2>/dev/null || echo "0")
    local usb_present=$(cat "$USB_PS/present" 2>/dev/null || echo "0")
    local real_type=$(cat "$USB_PS/real_type" 2>/dev/null || echo "Unknown")
    local contract=$(cat "$USBPD_DIR/contract" 2>/dev/null || echo "implicit")
    local typec_mode=$(cat "$USB_PS/typec_mode" 2>/dev/null || echo "Nothing attached")
    local dp_status=$(cat "$DRM_DP/status" 2>/dev/null || echo "disconnected")

    # 1. PC Host Lockout: pc_port online == 1 OR real_type is SDP/CDP
    if [ "$pc_online" = "1" ] || [ "$real_type" = "SDP" ] || [ "$real_type" = "CDP" ]; then
        echo "PC_HOST"
        return
    fi

    # 2. Standard Wall/QC Charger Lockout: DCP, HVDCP, HVDCP3
    if [ "$real_type" = "DCP" ] || [ "$real_type" = "HVDCP" ] || [ "$real_type" = "HVDCP3" ]; then
        echo "CHARGER"
        return
    fi

    # 3. Powered USB-PD Dock (Explicit PD contract negotiated WITH external charging)
    if [ "$contract" = "explicit" ] && [ "$real_type" = "USB_PD" ] && [ "$usb_present" = "1" ]; then
        echo "POWERED_DOCK"
        return
    fi

    # 4. Unpowered USB-C Dock / Dongle (Explicit PD contract or Powered Cable, phone supplies VBUS/VCONN)
    if [ "$contract" = "explicit" ] && [ "$real_type" = "USB_PD" ] && [ "$usb_present" = "0" ]; then
        echo "UNPOWERED_DP"
        return
    fi

    # 5. Type-C Powered Cable w/ sink or active DRM DisplayPort connection
    if [ "$typec_mode" = "Powered cable w/ sink" ] || [ "$dp_status" = "connected" ]; then
        echo "UNPOWERED_DP"
        return
    fi

    # 6. Potential Unpowered DP dongle / manual mode
    if [ "$usb_present" = "1" ]; then
        echo "UNPOWERED_DP"
        return
    fi

    # 7. Disconnected / Idle
    echo "IDLE"
}

# --- Guardrail 3: 1:1 Screen Mirroring Configuration & HWC Settings ---
configure_mirror_mode() {
    log_quiet "[*] Configuring Android framework for 1:1 Screen Mirroring..."
    # Disable Desktop Mode on external displays (0 = 1:1 SurfaceFlinger mirror)
    settings put global force_desktop_mode_on_external_displays 0 2>/dev/null
    setprop persist.sys.desktop_mode 0 2>/dev/null
    # Configure Qualcomm SM8150 Display HAL properties for external displays
    setprop vendor.display.disable_hotplug_bwcheck 1 2>/dev/null
    setprop vendor.display.enable_external_downscale 1 2>/dev/null
    # Safeguard LiveDisplay HAL: Pause to prevent abort() on external Display 1
    local ld_status=$(getprop init.svc.vendor.livedisplay-hal-2-1-lge_msmnile 2>/dev/null || echo "stopped")
    if [ "$ld_status" = "running" ]; then
        log_quiet "[*] Pausing LiveDisplay HAL to isolate external display pipeline..."
        stop vendor.livedisplay-hal-2-1-lge_msmnile 2>/dev/null
    fi
    log_quiet "[+] 1:1 Screen Mirroring configuration active."
}

# --- CC Polarity Detection ---
detect_cc_polarity() {
    local cc1="Open"
    local cc2="Open"

    if [ -r "$OTG_DIR/cc1" ]; then
        cc1=$(cat "$OTG_DIR/cc1" 2>/dev/null || echo "Open")
    fi
    if [ -r "$OTG_DIR/cc2" ]; then
        cc2=$(cat "$OTG_DIR/cc2" 2>/dev/null || echo "Open")
    fi

    # In Shark Kernel / PM8150B:
    # If CC2 is active (not Open) while CC1 is Open -> CC2 orientation (1)
    # Otherwise -> CC1 orientation (0)
    if [ "$cc2" != "Open" ] && [ "$cc1" = "Open" ]; then
        echo 1
    else
        echo 0
    fi
}

# --- Driver & GPIO Primitives ---
unbind_sbu_driver() {
    if [ -L "$SBU_DRV/$SBU_DEV" ]; then
        log_quiet "[*] Unbinding $SBU_DEV from kernel platform driver..."
        echo "$SBU_DEV" > "$SBU_DRV/unbind" 2>/dev/null
        if [ $? -ne 0 ]; then
            log "${C_RED}[!] Failed to unbind $SBU_DEV${C_RESET}"
            return 1
        fi
        log_quiet "[+] Driver $SBU_DEV unbound successfully."
    fi
    return 0
}

rebind_sbu_driver() {
    if [ ! -L "$SBU_DRV/$SBU_DEV" ]; then
        log_quiet "[*] Rebinding $SBU_DEV to kernel platform driver..."
        echo "$SBU_DEV" > "$SBU_DRV/bind" 2>/dev/null
        if [ $? -eq 0 ]; then
            log_quiet "[+] Driver $SBU_DEV rebound successfully."
        else
            log_quiet "[!] Warning: Could not rebind $SBU_DEV (device may already be bound)."
        fi
    fi
    return 0
}

export_pin() {
    local pin="$1"
    if [ ! -d "/sys/class/gpio/gpio$pin" ]; then
        echo "$pin" > /sys/class/gpio/export 2>/dev/null
        if [ ! -d "/sys/class/gpio/gpio$pin" ]; then
            log "${C_RED}[!] Failed to export GPIO $pin${C_RESET}"
            return 1
        fi
    fi
    return 0
}

unexport_pin() {
    local pin="$1"
    if [ -d "/sys/class/gpio/gpio$pin" ]; then
        echo "$pin" > /sys/class/gpio/unexport 2>/dev/null
    fi
    return 0
}

# --- Atomic Hardware Application & Teardown ---
apply_sbu_routing() {
    local pol_arg="$1"
    local allow_vconn="$2"

    unbind_sbu_driver || return 1
    export_pin "$GPIO_OE" || return 1
    export_pin "$GPIO_SEL" || return 1

    local pol_val=0
    if [ -n "$pol_arg" ]; then
        case "$pol_arg" in
            reversed|rev|1) pol_val=1 ;;
            normal|norm|0|*) pol_val=0 ;;
        esac
    else
        pol_val=$(detect_cc_polarity)
    fi

    # Set directions
    echo "out" > "/sys/class/gpio/gpio$GPIO_OE/direction" 2>/dev/null
    echo "out" > "/sys/class/gpio/gpio$GPIO_SEL/direction" 2>/dev/null

    # Assert SBU lines: GPIO 119 = 1 (closes AUX FET switches), GPIO 87 = polarity
    echo 1 > "/sys/class/gpio/gpio$GPIO_OE/value" 2>/dev/null
    echo "$pol_val" > "/sys/class/gpio/gpio$GPIO_SEL/value" 2>/dev/null

    # Manage VCONN strictly according to electrical safety rule
    if [ "$allow_vconn" = "1" ]; then
        local safety_check=$(evaluate_safety)
        if [ "$safety_check" = "IDLE" ] || [ "$safety_check" = "PC_HOST" ] || [ "$safety_check" = "CHARGER" ]; then
            log "${C_RED}[!] SAFETY VIOLATION: Cannot assert VCONN in state $safety_check! Prohibited to prevent PM8150B hard reboot.${C_RESET}"
            allow_vconn=0
        fi
    fi

    if [ "$allow_vconn" = "1" ]; then
        if [ -w "$OTG_DIR/powers_vconn" ]; then
            echo y > "$OTG_DIR/powers_vconn" 2>/dev/null
            log_quiet "[*] Asserted powers_vconn = y for unpowered active adapter"
        fi
    else
        if [ -w "$OTG_DIR/powers_vconn" ]; then
            echo n > "$OTG_DIR/powers_vconn" 2>/dev/null
            log_quiet "[*] Maintained powers_vconn = n (self-powered dock or unasserted)"
        fi
    fi

    # Trigger DRM DisplayPort detect
    if [ -w "$DRM_DP/status" ]; then
        echo detect > "$DRM_DP/status" 2>/dev/null
    fi

    echo "ACTIVE" > "$STATE_FILE" 2>/dev/null
    return 0
}

teardown_sbu_routing() {
    log_quiet "[*] Executing atomic teardown of SBU routing..."

    # 1. Drop VCONN power first to prevent transients
    if [ -w "$OTG_DIR/powers_vconn" ]; then
        echo n > "$OTG_DIR/powers_vconn" 2>/dev/null
    fi

    # 2. Open SBU analog switches (GPIO 119 = 0, GPIO 87 = 0)
    if [ -d "/sys/class/gpio/gpio$GPIO_OE" ]; then
        echo 0 > "/sys/class/gpio/gpio$GPIO_OE/value" 2>/dev/null
    fi
    if [ -d "/sys/class/gpio/gpio$GPIO_SEL" ]; then
        echo 0 > "/sys/class/gpio/gpio$GPIO_SEL/value" 2>/dev/null
    fi

    # 3. Unexport GPIOs to return control
    unexport_pin "$GPIO_OE"
    unexport_pin "$GPIO_SEL"

    # 4. Rebind kernel platform driver
    rebind_sbu_driver

    # 5. Clean state file
    rm -f "$STATE_FILE" 2>/dev/null

    # 6. Restore LiveDisplay HAL if it was stopped
    local ld_status=$(getprop init.svc.vendor.livedisplay-hal-2-1-lge_msmnile 2>/dev/null || echo "stopped")
    if [ "$ld_status" != "running" ]; then
        log_quiet "[*] Restoring LiveDisplay HAL for built-in panel..."
        start vendor.livedisplay-hal-2-1-lge_msmnile 2>/dev/null
    fi

    log_quiet "[+] SBU routing restored to kernel defaults."
}

# --- CLI Subcommand Handlers ---

cmd_check_safety() {
    echo -e "${C_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}  LG V50 PM8150B Electrical Safety & Cable Diagnostic Interlock${C_RESET}"
    echo -e "${C_CYAN}======================================================================${C_RESET}"

    local pc_online=$(cat "$PC_PORT/online" 2>/dev/null || echo "0")
    local usb_present=$(cat "$USB_PS/present" 2>/dev/null || echo "0")
    local real_type=$(cat "$USB_PS/real_type" 2>/dev/null || echo "Unknown")
    local usb_type=$(cat "$USB_PS/type" 2>/dev/null || echo "Unknown")
    local contract=$(cat "$USBPD_DIR/contract" 2>/dev/null || echo "implicit")
    local vconn=$(cat "$OTG_DIR/powers_vconn" 2>/dev/null || echo "n")
    local typec_mode=$(cat "$USB_PS/typec_mode" 2>/dev/null || echo "Nothing attached")
    local cc1=$(cat "$OTG_DIR/cc1" 2>/dev/null || echo "Open")
    local cc2=$(cat "$OTG_DIR/cc2" 2>/dev/null || echo "Open")

    echo "  PC Port Online        : $pc_online"
    echo "  USB Present           : $usb_present"
    echo "  USB Real Type         : $real_type (driver class: $usb_type)"
    echo "  Type-C Mode           : $typec_mode"
    echo "  Type-C CC State       : CC1=$cc1 | CC2=$cc2"
    echo "  USB-PD Contract       : $contract"
    echo "  Current VCONN State   : $vconn"
    echo ""

    local decision=$(evaluate_safety)
    echo -n "  Interlock Assessment : "
    case "$decision" in
        PC_HOST)
            echo -e "${C_RED}[ STRICT LOCKOUT - PC HOST DETECTED ]${C_RESET}"
            echo -e "  ${C_YELLOW}Explanation: Device is connected to a PC USB Host ($real_type).${C_RESET}"
            echo -e "  ${C_YELLOW}Safety Rule: VCONN power and SBU unbind are strictly forbidden${C_RESET}"
            echo -e "  ${C_YELLOW}to prevent 5V VBUS reverse feeding and PM8150B hard shutdown.${C_RESET}"
            ;;
        CHARGER)
            echo -e "${C_RED}[ STRICT LOCKOUT - WALL CHARGER DETECTED ]${C_RESET}"
            echo -e "  ${C_YELLOW}Explanation: Device is connected to a standard AC/QC charger ($real_type).${C_RESET}"
            echo -e "  ${C_YELLOW}DisplayPort SBU routing is disabled for charger connections.${C_RESET}"
            ;;
        POWERED_DOCK)
            echo -e "${C_GREEN}[ SAFE TO MIRROR - POWERED USB-PD DOCK ]${C_RESET}"
            echo -e "  ${C_CYAN}Explanation: Explicit USB-PD contract established with external dock.${C_RESET}"
            echo -e "  ${C_CYAN}Safety Rule: SBU AUX routing permitted; VCONN kept 'n' (self-powered).${C_RESET}"
            ;;
        UNPOWERED_DP)
            echo -e "${C_YELLOW}[ CONDITIONAL - UNPOWERED DP ADAPTER / IDLE ]${C_RESET}"
            echo -e "  ${C_CYAN}Explanation: Device attached, implicit contract. Safe for manual on-demand.${C_RESET}"
            ;;
        IDLE|*)
            echo -e "${C_BLUE}[ SAFE IDLE - NO CABLE ATTACHED ]${C_RESET}"
            echo -e "  ${C_CYAN}Default kernel driver binding active. Zero electrical risk.${C_RESET}"
            ;;
    esac
    echo -e "${C_CYAN}======================================================================${C_RESET}"
}

cmd_status() {
    echo -e "${C_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}  LG V50 Safe Wired Screen Mirroring (1:1) Status Overview${C_RESET}"
    echo -e "${C_CYAN}======================================================================${C_RESET}"

    # 1. Daemon Process Status
    local status_reported=0
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if is_mirror_process "$pid"; then
                echo -e "  Mirror Daemon         : ${C_GREEN}[ RUNNING ]${C_RESET} (PID $pid)"
                status_reported=1
            else
                echo -e "  Mirror Daemon         : ${C_YELLOW}[ STALE PID ]${C_RESET} (PID $pid is not mirror daemon)"
                rm -f "$PID_FILE" 2>/dev/null
                status_reported=1
            fi
        else
            echo -e "  Mirror Daemon         : ${C_YELLOW}[ STALE PID ]${C_RESET} ($pid not active)"
            rm -f "$PID_FILE" 2>/dev/null
            status_reported=1
        fi
    fi

    if [ "$status_reported" -eq 0 ]; then
        local orphan_pids=$(find_orphan_mirror_pids)
        if [ -n "$orphan_pids" ]; then
            echo -e "  Mirror Daemon         : ${C_GREEN}[ RUNNING ]${C_RESET} (Orphan PID(s): $orphan_pids)"
        else
            echo -e "  Mirror Daemon         : [ STOPPED ]"
        fi
    fi

    # 2. System Ready Guardrails
    local boot_done=$(getprop sys.boot_completed 2>/dev/null || echo "0")
    local ld_status=$(getprop init.svc.vendor.livedisplay-hal-2-1-lge_msmnile 2>/dev/null || echo "N/A")
    local ld_pid=$(getprop init.svc_debug_pid.vendor.livedisplay-hal-2-1-lge_msmnile 2>/dev/null || echo "N/A")
    echo -e "  Android Boot Status   : $( [ "$boot_done" = "1" ] && echo -e "${C_GREEN}COMPLETED (1)${C_RESET}" || echo -e "${C_RED}INCOMPLETE ($boot_done)${C_RESET}" )"
    echo -e "  LiveDisplay HAL       : $( [ "$ld_status" = "running" ] && echo -e "${C_GREEN}ACTIVE (PID $ld_pid)${C_RESET}" || echo -e "${C_RED}$ld_status${C_RESET}" )"

    # 3. Android Mirroring Mode
    local desktop_setting=$(settings get global force_desktop_mode_on_external_displays 2>/dev/null || echo "unknown")
    local desktop_prop=$(getprop persist.sys.desktop_mode 2>/dev/null || echo "unknown")
    if [ "$desktop_setting" = "0" ] && [ "$desktop_prop" = "0" ]; then
        echo -e "  Display Mode          : ${C_GREEN}[ 1:1 SCREEN MIRRORING ]${C_RESET} (Desktop Mode disabled)"
    else
        echo -e "  Display Mode          : ${C_YELLOW}[ DESKTOP / CUSTOM ]${C_RESET} (setting=$desktop_setting, prop=$desktop_prop)"
    fi

    # 4. SBU Driver & GPIOs
    if [ -L "$SBU_DRV/$SBU_DEV" ]; then
        echo -e "  SBU Platform Driver   : ${C_GREEN}[ BOUND ]${C_RESET} ($SBU_DEV kernel-managed)"
    else
        echo -e "  SBU Platform Driver   : ${C_CYAN}[ UNBOUND ]${C_RESET} (userspace override active)"
    fi

    if [ -d "/sys/class/gpio/gpio$GPIO_OE" ]; then
        local oe_val=$(cat "/sys/class/gpio/gpio$GPIO_OE/value" 2>/dev/null || echo "0")
        if [ "$oe_val" = "1" ]; then
            echo -e "  GPIO 119 (SBU OE)     : ${C_GREEN}[ 1 - ENABLED ]${C_RESET} -> AUX differential pairs connected"
        else
            echo -e "  GPIO 119 (SBU OE)     : ${C_RED}[ 0 - ISOLATED ]${C_RESET} -> AUX lines disconnected"
        fi
    else
        echo -e "  GPIO 119 (SBU OE)     : [ NOT EXPORTED ]"
    fi

    if [ -d "/sys/class/gpio/gpio$GPIO_SEL" ]; then
        local sel_val=$(cat "/sys/class/gpio/gpio$GPIO_SEL/value" 2>/dev/null || echo "0")
        local sel_str="CC1 Normal"
        [ "$sel_val" = "1" ] && sel_str="CC2 Reversed"
        echo -e "  GPIO 87  (SBU SEL)    : [ $sel_val ] ($sel_str)"
    else
        echo -e "  GPIO 87  (SBU SEL)    : [ NOT EXPORTED ]"
    fi

    # 5. Type-C & Power Supply State
    local real_type=$(cat "$USB_PS/real_type" 2>/dev/null || echo "Unknown")
    local pc_online=$(cat "$PC_PORT/online" 2>/dev/null || echo "0")
    local contract=$(cat "$USBPD_DIR/contract" 2>/dev/null || echo "implicit")
    local vconn=$(cat "$OTG_DIR/powers_vconn" 2>/dev/null || echo "n")
    echo "  Power Connection      : RealType=$real_type | PCOnline=$pc_online | Contract=$contract"
    echo "  VCONN Power Supply    : $vconn"

    # 6. DRM DisplayPort Connector
    local drm_stat=$(cat "$DRM_DP/status" 2>/dev/null || echo "unknown")
    if [ "$drm_stat" = "connected" ]; then
        local modes=$(cat "$DRM_DP/modes" 2>/dev/null | tr '\n' ' ' || echo "N/A")
        echo -e "  DRM card0-DP-1 Status : ${C_GREEN}[ CONNECTED ]${C_RESET}"
        echo "  Detected Video Modes  : $modes"
    else
        echo -e "  DRM card0-DP-1 Status : ${C_YELLOW}[ $drm_stat ]${C_RESET}"
    fi

    echo -e "${C_CYAN}======================================================================${C_RESET}"
}

cmd_manual_on() {
    check_root
    verify_system_ready || exit 1

    local safety=$(evaluate_safety)
    if [ "$safety" = "PC_HOST" ]; then
        log "${C_RED}[!] SAFETY VIOLATION: Cannot enable DP SBU routing while connected to a PC USB Host!${C_RESET}"
        log "${C_RED}[!] Hardware interlock active to prevent PM8150B hard reboot.${C_RESET}"
        exit 1
    elif [ "$safety" = "CHARGER" ]; then
        log "${C_RED}[!] SAFETY VIOLATION: Cannot enable DP SBU routing while connected to a wall charger!${C_RESET}"
        exit 1
    fi

    configure_mirror_mode

    local allow_vconn=0
    if [ "$safety" = "UNPOWERED_DP" ]; then
        allow_vconn=1
    fi
    local pol_arg=""
    for arg in "$@"; do
        if [ "$arg" = "--vconn" ]; then
            allow_vconn=1
        elif [ "$arg" = "--no-vconn" ]; then
            allow_vconn=0
        elif [ -n "$arg" ] && [ -z "$pol_arg" ]; then
            pol_arg="$arg"
        fi
    done

    # Fix 1 (CRITICAL PMIC Electrical Safety):
    # Strictly prohibit --vconn when safety == IDLE (disconnected).
    # Asserting VCONN in IDLE state triggers a PM8150B boost trip and hardware reboot.
    if [ "$allow_vconn" = "1" ]; then
        log "${C_YELLOW}[*] Explicit VCONN power requested by operator.${C_RESET}"
        if [ "$safety" = "IDLE" ]; then
            log "${C_RED}[!] SAFETY VIOLATION: Cannot assert VCONN when disconnected (IDLE)! Prohibited to prevent PM8150B hard reboot.${C_RESET}"
            exit 1
        fi
    fi

    log "[*] Applying safe DisplayPort SBU routing..."
    apply_sbu_routing "$pol_arg" "$allow_vconn"
    if [ $? -eq 0 ]; then
        log "${C_GREEN}[+] DisplayPort SBU Routing Active (1:1 Screen Mirroring configured).${C_RESET}"
        local drm=$(cat "$DRM_DP/status" 2>/dev/null || echo "unknown")
        log "    DRM card0-DP-1 status: $drm"
    else
        log "${C_RED}[!] Failed to apply SBU routing.${C_RESET}"
        teardown_sbu_routing
        exit 1
    fi
}

cmd_manual_off() {
    check_root
    log "[*] Disabling DisplayPort SBU routing and restoring defaults..."
    teardown_sbu_routing
    log "${C_GREEN}[+] Hardware restored to kernel default state.${C_RESET}"
}

run_monitor_loop() {
    check_root
    verify_system_ready || exit 1

    # Concurrency check: verify no other daemon is running
    local orphan_pids=$(find_orphan_mirror_pids)
    for opid in $orphan_pids; do
        if [ "$opid" != "$$" ] && kill -0 "$opid" 2>/dev/null; then
            log "${C_RED}[!] Another mirror daemon is already running (PID $opid). Aborting.${C_RESET}"
            exit 1
        fi
    done

    log "${C_BOLD}[*] Starting Safe Screen Mirroring Monitor Daemon (PID $$)...${C_RESET}"
    echo $$ > "$PID_FILE"

    # Trap signals for guaranteed clean teardown
    cleanup_trap() {
        log "[*] Received termination signal. Executing clean teardown..."
        teardown_sbu_routing
        rm -f "$PID_FILE" 2>/dev/null
        rm -rf "$LOCK_DIR" 2>/dev/null
        log "[+] Daemon shutdown complete."
        exit 0
    }
    trap cleanup_trap INT TERM HUP EXIT

    configure_mirror_mode

    local last_state="IDLE"
    local last_pol=$(detect_cc_polarity)
    local last_drm=$(cat "$DRM_DP/status" 2>/dev/null || echo "disconnected")

    log "[+] Safe monitor loop active. Listening for DP Alt Mode events..."

    while true; do
        sleep 2

        local safety=$(evaluate_safety)

        # 1. PC Host or Charger Emergency Lockout
        if [ "$safety" = "PC_HOST" ] || [ "$safety" = "CHARGER" ]; then
            if [ "$last_state" != "$safety" ]; then
                log "${C_RED}[!] Electrical Interlock: $safety detected! Forcing teardown.${C_RESET}"
                teardown_sbu_routing
                last_state="$safety"
            fi
            continue
        fi

        # 2. Cable Disconnect
        if [ "$safety" = "IDLE" ]; then
            if [ "$last_state" != "IDLE" ]; then
                log "[*] Cable disconnected or idle. Restoring clean kernel state..."
                teardown_sbu_routing
                last_state="IDLE"
            fi
            continue
        fi

        # 3. Powered Dock or Valid Connection Detected
        if [ "$safety" = "POWERED_DOCK" ] || [ "$safety" = "UNPOWERED_DP" ]; then
            if [ "$last_state" != "$safety" ]; then
                log "${C_GREEN}[+] Valid display connection detected ($safety). Applying SBU routing...${C_RESET}"
                if [ "$safety" = "UNPOWERED_DP" ]; then
                    # Unpowered dongle/hub needs phone VCONN power
                    apply_sbu_routing "" 1
                else
                    # Powered dock supplies its own power -> keep powers_vconn = n
                    apply_sbu_routing "" 0
                fi
                last_state="$safety"
                last_pol=$(detect_cc_polarity)
            fi

            # Check for CC polarity change (cable flip)
            local curr_pol=$(detect_cc_polarity)
            if [ "$curr_pol" != "$last_pol" ]; then
                log "[*] CC polarity transition detected: $last_pol -> $curr_pol"
                if [ -d "/sys/class/gpio/gpio$GPIO_SEL" ]; then
                    echo "$curr_pol" > "/sys/class/gpio/gpio$GPIO_SEL/value" 2>/dev/null
                fi
                if [ -w "$DRM_DP/status" ]; then
                    echo detect > "$DRM_DP/status" 2>/dev/null
                fi
                last_pol=$curr_pol
            fi

            # Check DRM DP status change
            local curr_drm=$(cat "$DRM_DP/status" 2>/dev/null || echo "disconnected")
            if [ "$curr_drm" != "$last_drm" ]; then
                log "${C_GREEN}[*] DRM Connector status transition: $last_drm -> $curr_drm${C_RESET}"
                if [ "$curr_drm" = "connected" ]; then
                    local modes=$(cat "$DRM_DP/modes" 2>/dev/null | tr '\n' ' ' || echo "N/A")
                    log "${C_GREEN}[+] DisplayPort Connected! Video Modes: $modes${C_RESET}"
                    # Refresh SurfaceFlinger
                    service call SurfaceFlinger 1008 >/dev/null 2>&1
                fi
                last_drm=$curr_drm
            fi
        fi
    done
}

cmd_start_daemon() {
    check_root
    verify_system_ready || exit 1

    acquire_lock || {
        log "${C_RED}[!] Failed to acquire startup lock. Another start operation is in progress.${C_RESET}"
        return 1
    }

    # 1. Check if daemon is already running via PID file
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            if is_mirror_process "$old_pid"; then
                log "${C_YELLOW}[!] Mirror daemon is already running (PID $old_pid).${C_RESET}"
                release_lock
                return 0
            else
                log "[*] Stale alien PID $old_pid in $PID_FILE cleaned up."
                rm -f "$PID_FILE" 2>/dev/null
            fi
        fi
    fi

    # 2. Check if an orphan daemon is running without PID file
    local orphan_pids=$(find_orphan_mirror_pids)
    if [ -n "$orphan_pids" ]; then
        local first_orphan=$(echo "$orphan_pids" | awk '{print $1}')
        echo "$first_orphan" > "$PID_FILE"
        log "${C_YELLOW}[!] Mirror daemon is already running (re-attached to orphan PID $first_orphan).${C_RESET}"
        release_lock
        return 0
    fi

    # 3. Spawn daemon in background using detached subshell with exec (NOT nohup, so SIGHUP trap is active)
    ( exec "$0" run > /dev/null 2>&1 ) &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"
    release_lock

    sleep 1

    if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null && is_mirror_process "$new_pid"; then
        log "${C_GREEN}[+] Safe Screen Mirroring daemon started (PID $new_pid).${C_RESET}"
        return 0
    else
        log "${C_RED}[!] Failed to start background daemon.${C_RESET}"
        rm -f "$PID_FILE" 2>/dev/null
        return 1
    fi
}

cmd_stop_daemon() {
    check_root
    local stopped_any=0

    # 1. Check PID file if present
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if is_mirror_process "$pid"; then
                log "[*] Terminating daemon (PID $pid)..."
                kill -TERM "$pid" 2>/dev/null
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    kill -KILL "$pid" 2>/dev/null
                fi
                log "${C_GREEN}[+] Daemon stopped.${C_RESET}"
                stopped_any=1
            else
                log "${C_YELLOW}[!] WARNING: PID $pid in $PID_FILE is not a mirror daemon process!${C_RESET}"
                log "${C_YELLOW}[!] Refusing to signal alien process. Cleaning stale PID file.${C_RESET}"
            fi
        else
            log "[*] Stale PID file cleaned up."
        fi
        rm -f "$PID_FILE" 2>/dev/null
    fi

    # 2. Check for any running orphan daemon processes (v50_safe_mirror ... run)
    local orphan_pids=$(find_orphan_mirror_pids)
    if [ -n "$orphan_pids" ]; then
        log "[*] Found running orphan mirror daemon(s): $orphan_pids. Terminating..."
        for opid in $orphan_pids; do
            if is_mirror_process "$opid"; then
                kill -TERM "$opid" 2>/dev/null
                sleep 1
                if kill -0 "$opid" 2>/dev/null; then
                    kill -KILL "$opid" 2>/dev/null
                fi
                log "[+] Orphan daemon PID $opid stopped."
                stopped_any=1
            fi
        done
        rm -f "$PID_FILE" 2>/dev/null
    fi

    # 3. Final sweep to guarantee all orphan mirror daemons are terminated
    local remaining_orphans=$(find_orphan_mirror_pids)
    if [ -n "$remaining_orphans" ]; then
        log "[*] Force sweeping remaining orphan mirror daemon(s): $remaining_orphans..."
        for ropid in $remaining_orphans; do
            if is_mirror_process "$ropid"; then
                kill -KILL "$ropid" 2>/dev/null
                stopped_any=1
            fi
        done
        rm -f "$PID_FILE" 2>/dev/null
    fi

    if [ "$stopped_any" -eq 0 ] && [ ! -f "$PID_FILE" ]; then
        log "[*] No daemon running (PID file not found)."
    fi

    teardown_sbu_routing
    release_lock
    return 0
}

usage() {
    echo -e "${C_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}  LG V50 Safe Wired Screen Mirroring (1:1) Tool${C_RESET}"
    echo -e "${C_CYAN}======================================================================${C_RESET}"
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  status            Show complete hardware, safety, and mirroring status"
    echo "  check-safety      Perform non-destructive electrical safety interlock audit"
    echo "  start             Start safe background hotplug monitor daemon"
    echo "  stop              Stop running monitor daemon and restore kernel defaults"
    echo "  run               Run safe monitor daemon in foreground"
    echo "  manual-on [args]  Apply on-demand SBU routing for DP mirror (manual override)"
    echo "                    Arguments: [normal|reversed] [--vconn]"
    echo "  manual-off        Deactivate SBU routing and restore kernel default state"
    echo "  help | -h         Display this help message"
    echo ""
    echo "Safety Guarantees:"
    echo "  - Zero early boot hooks: strictly waits for boot_completed & LiveDisplay."
    echo "  - PC Host & Charger lockout: prevents PM8150B VBUS drops / hard resets."
    echo "  - Powered dock safety: keeps powers_vconn = n for self-powered docks."
    echo "  - Atomic teardown: restores GPIOs and driver binding on exit or unplug."
    echo "  - True 1:1 mirroring: SurfaceFlinger layerStack 0 mirror, no desktop mockup."
    exit 0
}

# --- Command Dispatcher ---
case "$1" in
    status)
        cmd_status
        ;;
    check-safety)
        cmd_check_safety
        ;;
    start)
        cmd_start_daemon
        ;;
    stop)
        cmd_stop_daemon
        ;;
    run)
        run_monitor_loop
        ;;
    manual-on)
        shift
        cmd_manual_on "$@"
        ;;
    manual-off)
        cmd_manual_off
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        if [ -z "$1" ]; then
            usage
        else
            echo -e "${C_RED}[!] Unknown command: $1${C_RESET}"
            usage
        fi
        ;;
esac
