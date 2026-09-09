#!/system/bin/sh
############################################
# overlayfsx uninstall.sh
# Cleanup script for metamodule removal
############################################

DATA_DIR="/data/adb/overlayfsx-data"
IMG_FILE="$DATA_DIR/modules.img"
MNT_DIR="$DATA_DIR/mnt"
TMP_MNT="$DATA_DIR/uninstall-mnt.$$"
LEGACY_MNT="/data/adb/metamodule/mnt"

# Disable modules whose payloads depend on this metamodule before removing the
# external image. Prefer the already-mounted image; otherwise mount it briefly.
SCAN_DIR=""
MOUNTED_TEMP=0

if mountpoint -q "$MNT_DIR" 2>/dev/null; then
    SCAN_DIR="$MNT_DIR"
elif [ -f "$IMG_FILE" ]; then
    mkdir -p "$TMP_MNT"
    chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null
    if mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$TMP_MNT" 2>/dev/null; then
        SCAN_DIR="$TMP_MNT"
        MOUNTED_TEMP=1
    fi
fi

if [ -n "$SCAN_DIR" ]; then
    for module_dir in "$SCAN_DIR"/*; do
        [ -d "$module_dir" ] || continue
        module_name=$(basename "$module_dir")
        [ "$module_name" = "lost+found" ] && continue
        case "$module_name" in *_update) module_name="${module_name%_update}" ;; esac
        if [ -d "/data/adb/modules/$module_name" ]; then
            touch "/data/adb/modules/$module_name/disable" 2>/dev/null
        fi
    done
fi

if [ "$MOUNTED_TEMP" = "1" ]; then
    umount "$TMP_MNT" 2>/dev/null || true
    rmdir "$TMP_MNT" 2>/dev/null
fi

# A live external mount should normally be absent when KernelSU prunes the
# metamodule on a fresh boot. Do not force/lazy-unmount it if it is unexpectedly
# busy; leaving state behind is safer than tearing backing storage out from
# under active OverlayFS/bind mounts.
if mountpoint -q "$MNT_DIR" 2>/dev/null; then
    if ! umount "$MNT_DIR" 2>/dev/null; then
        echo "[overlayfsx] external image still busy; preserving $DATA_DIR for safety" >&2
        exit 0
    fi
fi

rmdir "$MNT_DIR" 2>/dev/null || true
rm -rf "$DATA_DIR" 2>/dev/null

# Legacy directories should be empty after a full reboot. Never lazy-unmount a
# legacy live mount during uninstall; preserve it until the kernel reboot clears it.
if ! mountpoint -q "$LEGACY_MNT" 2>/dev/null; then
    rmdir "$LEGACY_MNT" 2>/dev/null || true
fi

exit 0
