#!/system/bin/sh

# 1. Architecture Detection & Binary Extraction
ui_print "- Detecting device architecture..."
ABI=$(grep_get_prop ro.product.cpu.abi)
ui_print "- Detected ABI: $ABI"

case "$ABI" in
    arm64-v8a)
        ARCH_BINARY="overlayfsx-aarch64"
        REMOVE_BINARY="overlayfsx-x86_64"
        ui_print "- Selected architecture: ARM64"
        ;;
    x86_64)
        ARCH_BINARY="overlayfsx-x86_64"
        REMOVE_BINARY="overlayfsx-aarch64"
        ui_print "- Selected architecture: x86_64"
        ;;
    *)
        abort "- Unsupported architecture: $ABI"
        ;;
esac

[ ! -f "$MODPATH/$ARCH_BINARY" ] && abort "- Binary not found: $ARCH_BINARY"

ui_print "- Installing $ARCH_BINARY as overlayfsx"
mv "$MODPATH/$ARCH_BINARY" "$MODPATH/overlayfsx" || abort "- Failed to rename binary"
rm -f "$MODPATH/$REMOVE_BINARY"
chmod 755 "$MODPATH/overlayfsx" || abort "- Failed to set permissions"
ui_print "- Architecture-specific binary installed successfully"

# 2. Persistent Ext4 Image Setup
#
# IMPORTANT: the live ext4 mountpoint must not live below $MODPATH. KernelSU
# 3.3.0 promotes module updates by removing /data/adb/modules/<id> first; a
# mounted $MODPATH/mnt makes that operation fail with EBUSY and leaves the
# metamodule permanently in "update pending" state.
OVERLAYFSX_DATA_DIR="/data/adb/overlayfsx-data"
IMG_FILE="$OVERLAYFSX_DATA_DIR/modules.img"
LEGACY_IMG="/data/adb/modules/$MODID/modules.img"
IMG_SIZE_MB=2048
IS_FIRST_INSTALL=false

mkdir -p "$OVERLAYFSX_DATA_DIR" || abort "- Failed to create persistent OverlayFSx data directory"
chmod 0700 "$OVERLAYFSX_DATA_DIR" 2>/dev/null || true
chcon u:object_r:ksu_file:s0 "$OVERLAYFSX_DATA_DIR" 2>/dev/null || true

# Never ship or retain the mutable image inside the metamodule directory.
rm -f "$MODPATH/modules.img"
rm -rf "$MODPATH/mnt" "$MODPATH/mnt_temp"

if [ -f "$IMG_FILE" ]; then
    ui_print "- Reusing external OverlayFSx modules image"
elif [ -f "$LEGACY_IMG" ]; then
    ui_print "- Migrating legacy in-module image to external persistent storage"
    TMP_IMG="$OVERLAYFSX_DATA_DIR/.modules.img.install.$$"
    rm -f "$TMP_IMG"
    sync
    "$MODPATH/overlayfsx" xcp "$LEGACY_IMG" "$TMP_IMG" || {
        rm -f "$TMP_IMG"
        abort "- Failed to migrate legacy modules image"
    }
    sync
    chcon u:object_r:ksu_file:s0 "$TMP_IMG" 2>/dev/null || true
    mv -f "$TMP_IMG" "$IMG_FILE" || abort "- Failed to finalize migrated modules image"
    chmod 0600 "$IMG_FILE" 2>/dev/null || true
    chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null || true
    ui_print "- Legacy image migrated to $IMG_FILE"
else
    ui_print "- Creating 2GB ext4 image in external persistent storage"
    IS_FIRST_INSTALL=true
    truncate -s ${IMG_SIZE_MB}M "$IMG_FILE" || abort "- Failed to create image file"
    /system/bin/mke2fs -t ext4 -O ^has_journal -F "$IMG_FILE" >/dev/null 2>&1 || abort "- Failed to format ext4 image"
    chmod 0600 "$IMG_FILE" 2>/dev/null || true
    chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null || true
    ui_print "- Image created successfully (sparse file)"
fi

# 3. First-Time Module Sync (Existing/Pending Modules)
if [ "$IS_FIRST_INSTALL" = true ]; then
    . "$MODPATH/utils.sh"

    ui_print " "
    ui_print "- WARNING: Module sync is an experimental feature."
    ui_print "- It works, but behavior varies across environments."
    ui_print "- Proceeding may cause unexpected boot issues."
    ui_print " "
    ui_print "- Sync existing and pending modules now?"
    ui_print "- [ Vol UP = Yes  |  Vol DOWN = No ]"

    if chooseport 10; then
        ui_print " "
        ui_print "- Initializing first-time module sync..."

        export OVERLAYFSX_DATA_DIR
        export IMG_FILE
        export MNT_DIR="$OVERLAYFSX_DATA_DIR/mnt_install.$$"

        silent_check_requires_move() {
            [ -f "$MODPATH/skip_mount" ] && return 1
            for part in system vendor product system_ext odm oem; do
                [ -d "$MODPATH/$part" ] && return 0
            done
            return 1
        }

        sync
        chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null
        mkdir -p "$MNT_DIR"

        if mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR"; then
            ORIG_MODPATH="$MODPATH"
            ORIG_MODID="$MODID"
            SYNC_COUNT=0

            for base_dir in /data/adb/modules /data/adb/modules_update; do
                [ ! -d "$base_dir" ] && continue

                for target_mod in "$base_dir"/*/; do
                    [ ! -d "$target_mod" ] && continue

                    target_id=$(basename "$target_mod")

                    [ "$target_id" = "$ORIG_MODID" ] && continue
                    [ "$target_id" = "overlayfsx" ] && continue
                    [ "$target_id" = "meta-overlayfsx" ] && continue

                    export MODPATH="$target_mod"
                    export MODID="$target_id"

                    if silent_check_requires_move; then
                        dir_label="active"
                        [ "$base_dir" = "/data/adb/modules_update" ] && dir_label="pending"

                        ui_print "- Syncing [$dir_label] module: $MODID"
                        check_conflicts
                        post_install_to_image
                        SYNC_COUNT=$((SYNC_COUNT + 1))
                    fi
                done
            done

            export MODPATH="$ORIG_MODPATH"
            export MODID="$ORIG_MODID"

            sync
            umount "$MNT_DIR" || umount -l "$MNT_DIR"
            rmdir "$MNT_DIR" 2>/dev/null

            if [ "$SYNC_COUNT" -gt 0 ]; then
                ui_print "- Successfully synced $SYNC_COUNT module(s)!"
            else
                ui_print "- No existing/pending modules required syncing."
            fi
        else
            ui_print "- Warning: Could not mount image for initial sync."
            rmdir "$MNT_DIR" 2>/dev/null
        fi
    else
        ui_print " "
        ui_print "- Skipping module sync."
    fi
fi

ui_print " "
if [ -f "$LEGACY_IMG" ]; then
    ui_print "- Upgrade note: perform one FULL reboot before reacquiring late-load root."
    ui_print "- This clears the legacy in-module mount so KernelSU can promote this update safely."
fi
ui_print "- Installation complete. Reboot to apply changes."
