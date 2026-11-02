#!/system/bin/sh
# ==============================================================================
# v50_dp_fix.sh - LG V50 Safe Screen Mirroring Redirector
# Refactored for Milestone 2: PM8150B Electrical Safety & LiveDisplay Protection
# ==============================================================================

if [ -f "/data/local/tmp/v50_safe_mirror.sh" ]; then
    exec /data/local/tmp/v50_safe_mirror.sh "$@"
elif [ -f "$(dirname "$0")/../scripts/v50_safe_mirror.sh" ]; then
    exec "$(dirname "$0")/../scripts/v50_safe_mirror.sh" "$@"
fi

echo "[!] Error: v50_safe_mirror.sh not found."
exit 1