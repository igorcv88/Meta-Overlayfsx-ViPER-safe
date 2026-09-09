#!/system/bin/sh
############################################
# overlayfsx metauninstall.sh
# Regular-module uninstallation hook
############################################

MNT_DIR="/data/adb/overlayfsx-data/mnt"

[ -n "$MODULE_ID" ] || exit 1

# During normal KernelSU pruning this runs before metamount.sh, so the image may
# not be mounted yet. In that case metamount.sh's orphan cleanup removes the
# payload later in the same activation sequence.
if ! mountpoint -q "$MNT_DIR" 2>/dev/null; then
    exit 0
fi

rm -rf "$MNT_DIR/$MODULE_ID" "$MNT_DIR/${MODULE_ID}_update" 2>/dev/null
sync
exit 0
