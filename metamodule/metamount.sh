#!/system/bin/sh
############################################
# overlayfsx metamount.sh
# Module mount handler for dual-directory mounting
# ViPER-safe adaptation: ViPER4Android-RE-AIDL is mounted granularly.
############################################

META_DIR="/data/adb/metamodule"

. "$META_DIR"/utils.sh || exit 1

# Persistent mutable state is external to /data/adb/modules/meta-overlayfsx so
# KernelSU can atomically replace the metamodule directory without EBUSY.
OVERLAYFSX_DATA_DIR="/data/adb/overlayfsx-data"
IMG_FILE="$OVERLAYFSX_DATA_DIR/modules.img"
MNT_DIR="$OVERLAYFSX_DATA_DIR/mnt"
LEGACY_IMG_FILE="$META_DIR/modules.img"
LEGACY_MNT_DIR="$META_DIR/mnt"
RW_ROOT="/data/adb/modules/.rw"
PARTITIONS="system vendor product system_ext odm oem"
MODULE_METADATA_DIR_REAL="/data/adb/modules"
LOG_FILE="$META_DIR/overlayfsx.log"
OVERLAYFSX_BIN="$META_DIR/overlayfsx"

# Re-export after overriding defaults from utils.sh.
export OVERLAYFSX_DATA_DIR IMG_FILE MNT_DIR LEGACY_IMG_FILE LEGACY_MNT_DIR LOG_FILE OVERLAYFSX_BIN

. "$META_DIR"/viper_safe.sh || exit 1
. "$META_DIR"/viper_lifecycle.sh || exit 1

log INFO "Starting module mount process"

# If an old release is somehow still mounted under the metamodule directory,
# activating the new layout in the same kernel boot would preserve the exact
# EBUSY condition this release fixes. Fail closed and require a real reboot.
if mountpoint -q "$LEGACY_MNT_DIR" 2>/dev/null; then
    log ERROR "Legacy OverlayFSx mount is still active at $LEGACY_MNT_DIR"
    log ERROR "Full reboot required before external-state layout can activate"
    exit 75
fi

ensure_overlayfsx_data_dir || {
    log ERROR "Failed to initialize external OverlayFSx state directory"
    exit 1
}

if [ ! -f "$IMG_FILE" ]; then
    migrate_legacy_image_if_needed || {
        rc=$?
        log ERROR "Persistent modules image unavailable (rc=$rc)"
        exit "$rc"
    }
fi

# Ensure ext4 image is mounted externally, never below the metamodule path.
ensure_image_mounted || exit $?

BINARY="$META_DIR/overlayfsx"
if [ ! -f "$BINARY" ]; then
    log ERROR "Binary not found: $BINARY"
    exit 1
fi

# Apply staged updates before generating the mount tree.
log INFO "Applying pending module updates in image..."
for update_dir in "$MNT_DIR"/*_update; do
    if [ -d "$update_dir" ]; then
        original_dir="${update_dir%_update}"
        MODULE_NAME=$(basename "$original_dir")
        log INFO "Swapping staged update for: $MODULE_NAME"
        rm -rf "$original_dir"
        mv "$update_dir" "$original_dir"
    fi
done

# Cleanup orphaned/skip_mount modules from image.
log INFO "Checking for orphaned modules and skip_mount flags..."
REMOVED_COUNT=0
for module_dir in "$MNT_DIR"/*; do
    if [ ! -d "$module_dir" ] || [ "$(basename "$module_dir")" = "lost+found" ] || echo "$module_dir" | grep -q "_update$"; then
        continue
    fi

    MODULE_NAME=$(basename "$module_dir")
    METADATA_PATH="$MODULE_METADATA_DIR_REAL/$MODULE_NAME"
    SHOULD_REMOVE=false
    REMOVE_REASON=""

    if [ ! -d "$METADATA_PATH" ]; then
        SHOULD_REMOVE=true
        REMOVE_REASON="orphaned"
    elif [ -f "$METADATA_PATH/skip_mount" ]; then
        SHOULD_REMOVE=true
        REMOVE_REASON="skip_mount"
    fi

    if [ "$SHOULD_REMOVE" = true ]; then
        log INFO "Removing $REMOVE_REASON module from image: $MODULE_NAME"
        rm -rf "$module_dir"
        REMOVED_COUNT=$((REMOVED_COUNT + 1))
    fi
done

if [ "$REMOVED_COUNT" -gt 0 ]; then
    log INFO "Removed $REMOVED_COUNT module(s) from image"
else
    log INFO "No modules to remove from image"
fi

# Refuse to stack this safe implementation over a stale ViPER root overlay.
v4a_check_stale_root_overlay || exit $?

# A root overlay from another module is outside the ViPER exception.
v4a_warn_other_root_overlays

# Apply SELinux contexts for .rw partition structures.
if [ -d "$RW_ROOT" ]; then
    log INFO "Applying SELinux contexts for RW partition structures"
    for part in $PARTITIONS; do
        PART_DIR="$RW_ROOT/$part"
        REFERENCE_PATH="/$part"
        if [ -d "$PART_DIR" ] && [ -e "$REFERENCE_PATH" ]; then
            chcon --reference="$REFERENCE_PATH" "$PART_DIR" 2>/dev/null
            [ -d "$PART_DIR/upperdir" ] && chcon --reference="$PART_DIR" "$PART_DIR/upperdir" 2>/dev/null
            [ -d "$PART_DIR/workdir" ] && chcon --reference="$PART_DIR" "$PART_DIR/workdir" 2>/dev/null
        fi
    done
fi

# Exclude only ViPER from the normal partition-root OverlayFS pass. All other
# modules continue through the upstream OverlayFSx engine unchanged.
V4A_ACTIVE=0
if v4a_enabled; then
    V4A_ACTIVE=1
    log INFO "$V4A_ID detected; excluding it from partition-root OverlayFS"
    build_filtered_metadata || {
        log ERROR "Failed to create filtered metadata view for ViPER"
        exit 1
    }
    export MODULE_METADATA_DIR="$V4A_TMP_META"
else
    export MODULE_METADATA_DIR="$MODULE_METADATA_DIR_REAL"
fi
export MODULE_CONTENT_DIR="$MNT_DIR"

"$BINARY" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
    log ERROR "Mount failed with exit code $EXIT_CODE"
    exit "$EXIT_CODE"
fi

# Mount ViPER only at audio_effects config files and soundfx directories.
if [ "$V4A_ACTIVE" -eq 1 ]; then
    v4a_cleanup_deleted_binds || {
        log ERROR "Failed to remove stale deleted-backed ViPER bind(s)"
        exit 76
    }

    v4a_mount_granular || {
        log ERROR "ViPER-safe mount failed; broad partition fallback is disabled"
        exit 76
    }

    v4a_reload_audio_stack_if_needed || {
        log ERROR "ViPER mounts are live but audio stack reload/verification failed"
        exit 77
    }
fi

# Restore the real metadata view for inspector/WebUI.
export MODULE_METADATA_DIR="$MODULE_METADATA_DIR_REAL"
cleanup_v4a_tmp

log INFO "Analyzing mount state to update UI description..."
INSPECT_JSON=$("$BINARY" inspect -r 2>/dev/null)
if echo "$INSPECT_JSON" | grep -q '"status": "success"'; then
    MODULE_COUNT=$(echo "$INSPECT_JSON" | grep -o '"id":' | wc -l)
    CONFLICT_COUNT=$(echo "$INSPECT_JSON" | grep -o '"total_conflicted": [0-9]*' | grep -o '[0-9]*')

    HAS_CONFLICT="🟢 False"
    if [ -n "$CONFLICT_COUNT" ] && [ "$CONFLICT_COUNT" -gt 0 ]; then
        HAS_CONFLICT="☢️ True"
    fi

    if [ "$V4A_ACTIVE" -eq 1 ]; then
        NEW_DESC="📦 Modules Mounted: $MODULE_COUNT | ViPER: 🛡️ Granular | File Conflicts: $HAS_CONFLICT | OverlayFSx ViPER-safe."
    else
        NEW_DESC="📦 Modules Mounted: $MODULE_COUNT | File Conflicts: $HAS_CONFLICT | OverlayFSx with ViPER-safe support."
    fi
    modify_prop "description" "$NEW_DESC" "$META_DIR/module.prop"
fi

log INFO "Persistent state: $OVERLAYFSX_DATA_DIR"
exit 0
