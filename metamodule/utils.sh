#!/system/bin/sh
############################################
# overlayfsx utils.sh
# Shared utility functions for module management
############################################

# Persistent OverlayFSx state must live outside the metamodule directory.
# KernelSU replaces /data/adb/modules/<id> atomically on module updates; keeping
# a live mountpoint below that directory makes remove_dir_all() fail with EBUSY.
OVERLAYFSX_DATA_DIR="${OVERLAYFSX_DATA_DIR:-/data/adb/overlayfsx-data}"
IMG_FILE="${IMG_FILE:-$OVERLAYFSX_DATA_DIR/modules.img}"
MNT_DIR="${MNT_DIR:-$OVERLAYFSX_DATA_DIR/mnt}"
LEGACY_IMG_FILE="${LEGACY_IMG_FILE:-/data/adb/metamodule/modules.img}"
LEGACY_MNT_DIR="${LEGACY_MNT_DIR:-/data/adb/metamodule/mnt}"
LOG_FILE="${LOG_FILE:-/data/adb/metamodule/overlayfsx.log}"
OVERLAYFSX_BIN="${OVERLAYFSX_BIN:-/data/adb/metamodule/overlayfsx}"

# Unified smart logger (Handles level switching dynamically)
log() {
    if [ "$#" -eq 2 ]; then
        local level="$1"
        local msg="$2"
        echo "- $msg"
        case "$level" in
            INFO|WARN|ERROR)
                [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"
                echo "[$level overlayfsx::script] $msg" >> "$LOG_FILE"
                ;;
        esac
    else
        echo "- $1"
    fi
}

# Extract property value from file
get_prop() {
    prop="$1"
    target_file="$2"

    if [ ! -f "$target_file" ]; then
        echo "Name not found"
        return
    fi

    grep "^$prop=" "$target_file" | cut -d'=' -f2 || echo "unknown"
}

# Safely modify module properties without breaking line structures
modify_prop() {
    local prop_key="$1"
    local prop_value="$2"
    local target_file="${3:-$MODDIR/module.prop}"

    if [ ! -f "$target_file" ]; then
        log ERROR "File $target_file not found."
        return 1
    fi

    if grep -q "^$prop_key=" "$target_file"; then
        local safe_value
        safe_value=$(printf '%s\n' "$prop_value" | sed 's/[~&]/\\&/g')
        sed -i "s~^$prop_key=.*~$prop_key=$safe_value~" "$target_file" || {
            log ERROR "Failed to modify $prop_key in $(basename "$target_file")"
            return 1
        }

        log INFO "Set $prop_key to $prop_value in $(basename "$target_file")"
    else
        log WARN "Property $prop_key not found in $(basename "$target_file"), skipping set"
    fi
}

ensure_overlayfsx_data_dir() {
    mkdir -p "$OVERLAYFSX_DATA_DIR" || return 1
    chmod 0700 "$OVERLAYFSX_DATA_DIR" 2>/dev/null || true
    chcon u:object_r:ksu_file:s0 "$OVERLAYFSX_DATA_DIR" 2>/dev/null || true
    return 0
}

# Migrate the legacy image that lived inside /data/adb/metamodule. This is only
# a fallback for upgrades where customize.sh could not externalize it earlier.
# Never migrate while the legacy mountpoint is live: the old layout must first
# be cleared by a full kernel reboot so KernelSU can safely promote the update.
migrate_legacy_image_if_needed() {
    [ -f "$IMG_FILE" ] && return 0
    [ -f "$LEGACY_IMG_FILE" ] || return 1

    if mountpoint -q "$LEGACY_MNT_DIR" 2>/dev/null; then
        log ERROR "Legacy in-module OverlayFSx mount is still active at $LEGACY_MNT_DIR"
        log ERROR "A full reboot is required before migrating persistent state"
        return 75
    fi

    ensure_overlayfsx_data_dir || return 1

    local tmp_img="$OVERLAYFSX_DATA_DIR/.modules.img.migrate.$$"
    rm -f "$tmp_img"
    sync

    if [ -x "$OVERLAYFSX_BIN" ]; then
        "$OVERLAYFSX_BIN" xcp "$LEGACY_IMG_FILE" "$tmp_img" || {
            rm -f "$tmp_img"
            log ERROR "Failed to migrate legacy modules image with overlayfsx xcp"
            return 1
        }
    else
        cp -af "$LEGACY_IMG_FILE" "$tmp_img" || {
            rm -f "$tmp_img"
            log ERROR "Failed to migrate legacy modules image"
            return 1
        }
    fi

    sync
    chcon u:object_r:ksu_file:s0 "$tmp_img" 2>/dev/null || true
    mv -f "$tmp_img" "$IMG_FILE" || {
        rm -f "$tmp_img"
        return 1
    }
    chmod 0600 "$IMG_FILE" 2>/dev/null || true
    chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null || true

    log INFO "Migrated OverlayFSx image to persistent external state: $IMG_FILE"
    return 0
}

# Mount ext4 image if not already mounted
ensure_image_mounted() {
    ensure_overlayfsx_data_dir || return 1

    if mountpoint -q "$LEGACY_MNT_DIR" 2>/dev/null; then
        log ERROR "Refusing to activate while legacy mountpoint is still live: $LEGACY_MNT_DIR"
        log ERROR "Perform one full reboot before using this release"
        return 75
    fi

    if [ ! -f "$IMG_FILE" ]; then
        migrate_legacy_image_if_needed || {
            log ERROR "Modules image not found at $IMG_FILE"
            return 1
        }
    fi

    if ! mountpoint -q "$MNT_DIR" 2>/dev/null; then
        log "Mounting modules image"
        mkdir -p "$MNT_DIR" || return 1
        chmod 0755 "$MNT_DIR" 2>/dev/null || true
        chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null
        mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR" || {
            log ERROR "Failed to mount modules image"
            return 1
        }
        log "Image mounted successfully at $MNT_DIR"
    else
        log "Image already mounted at $MNT_DIR"
    fi
    return 0
}

# Determine whether this module should be moved into the ext4 image
module_requires_overlay_move() {
    if [ -f "$MODPATH/skip_mount" ]; then
        log "skip_mount flag detected; keeping files under /data/adb/modules"
        return 1
    fi

    for part in system vendor product system_ext odm oem; do
        if [ -d "$MODPATH/$part" ]; then
            return 0
        fi
    done

    log "No overlay dirs found; keeping module in /data/adb/modules"
    return 1
}

# Copy SELinux contexts from src tree to destination by mirroring each entry
copy_selinux_contexts() {
    command -v chcon >/dev/null 2>&1 || return 0

    SRC="$1"
    DST="$2"

    if [ -z "$SRC" ] || [ -z "$DST" ] || [ ! -e "$SRC" ] || [ ! -e "$DST" ]; then
        return 0
    fi

    CHCON_FLAG=""
    if [ -L "$SRC" ]; then
        CHCON_FLAG="-h"
    fi
    chcon $CHCON_FLAG --reference="$SRC" "$DST" 2>/dev/null || true

    find "$SRC" -print 2>/dev/null | while IFS= read -r PATH_SRC; do
        if [ "$PATH_SRC" = "$SRC" ]; then
            continue
        fi
        REL_PATH="${PATH_SRC#"${SRC}/"}"
        PATH_DST="$DST/$REL_PATH"
        if [ -e "$PATH_DST" ] || [ -L "$PATH_DST" ]; then
            CHCON_FLAG=""
            if [ -L "$PATH_SRC" ]; then
                CHCON_FLAG="-h"
            fi
            chcon $CHCON_FLAG --reference="$PATH_SRC" "$PATH_DST" 2>/dev/null || true
        fi
    done
}

# Check for file conflicts with other installed modules
check_conflicts() {
    log "Scanning for potential file conflicts..."
    local temp_conflicts="/data/local/tmp/overlayfsx_conflicts_$$.tmp"
    rm -f "$temp_conflicts"

    find "$MODPATH" -type f 2>/dev/null | while IFS= read -r FILE; do
        REL_PATH="${FILE#"$MODPATH/"}"

        case "$REL_PATH" in
            system/*|vendor/*|product/*|system_ext/*|odm/*|oem/*)
                for OTHER_MOD_DIR in "$MNT_DIR"/*/; do
                    [ ! -d "$OTHER_MOD_DIR" ] && continue

                    OTHER_MOD="$(basename "$OTHER_MOD_DIR")"

                    [ "$OTHER_MOD" = "$MODID" ] && continue
                    [ "$OTHER_MOD" = "lost+found" ] && continue
                    [ "$OTHER_MOD" = "${MODID}_update" ] && continue

                    if [ -f "$OTHER_MOD_DIR/$REL_PATH" ]; then
                        FILENAME="$(basename "$REL_PATH")"
                        echo "$OTHER_MOD|$FILENAME" >> "$temp_conflicts"
                    fi
                done
                ;;
        esac
    done

    if [ -f "$temp_conflicts" ]; then
        log "File conflicts detected at the exact same mount path!"

        awk -F'|' '{
            mod=$1
            file=$2
            if (!seen[mod, file]) {
                seen[mod, file] = 1
                count[mod]++
                if (count[mod] <= 3) {
                    files_arr[mod, count[mod]] = file
                }
            }
        } END {
            for (mod in count) {
                print "  [ " mod " ] - " count[mod] " file(s)"

                for (i = 1; i <= count[mod] && i <= 3; i++) {
                    if (i == count[mod] || (i == 3 && count[mod] == 3)) {
                        print "   └── " files_arr[mod, i]
                    } else if (i == 3 && count[mod] > 3) {
                        print "   ├── " files_arr[mod, i]
                        print "   └── ...and " (count[mod] - 3) " more"
                    } else {
                        print "   ├── " files_arr[mod, i]
                    }
                }
            }
        }' "$temp_conflicts" | while IFS= read -r log_line; do
            log "$log_line"
        done

        log "Note: Both exist in their module folders, but the last one mounted will shadow (overwrite) the other."
        rm -f "$temp_conflicts"
    else
        log "No file conflicts found."
    fi
}

# Post-installation: stage module payload securely
post_install_to_image() {
    log "Moving module content to image"

    if [ -d "$MNT_DIR" ]; then
        chmod 755 "$MNT_DIR" 2>/dev/null || true
    fi

    log "Staging payload to ${MODID}_update."
    MOD_IMG_DIR="$MNT_DIR/${MODID}_update"

    rm -rf "$MOD_IMG_DIR"
    mkdir -p "$MOD_IMG_DIR"
    chmod 755 "$MOD_IMG_DIR" 2>/dev/null || true

    for partition in system vendor product system_ext odm oem; do
        SRC_DIR="$MODPATH/$partition"
        if [ -d "$SRC_DIR" ]; then
            log "Copying $partition/ to staging area"

            cp -af "$SRC_DIR" "$MOD_IMG_DIR/" || {
                log "Failed to copy $partition"
                continue
            }

            DEST_DIR="$MOD_IMG_DIR/$partition"
            copy_selinux_contexts "$SRC_DIR" "$DEST_DIR"
        fi
    done

    log "Module content staged to image successfully"
}

mark_replace() {
    replace_target="$1"
    mkdir -p "$replace_target"
    setfattr -n trusted.overlay.opaque -v y "$replace_target" 2>/dev/null || true
}

chooseport() {
  [ "$1" ] && local delay=$1 || local delay=10
  local retry_count=0
  local max_retries=2
  if [ -z "$TMPDIR" ]; then TMPDIR="/data/local/tmp"; fi
  mkdir -p "$TMPDIR"
  while true; do
    local count=0
    while true; do
      timeout $delay /system/bin/getevent -lqc 1 2>&1 > "$TMPDIR/events" &
      sleep 0.5; count=$((count + 1))
      if grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR/events"; then
        return 0
      elif grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR/events"; then
        return 1
      fi
      [ "$count" -gt 12 ] && break
    done
    retry_count=$((retry_count + 1))
    if [ "$retry_count" -gt "$max_retries" ]; then
      echo "  > Volume key not detected after $max_retries attempts. Auto-selecting Current Option."
      return 0
    else
      echo "  > Volume key not detected. Attempt $retry_count of $max_retries. Try again"
    fi
  done
}
