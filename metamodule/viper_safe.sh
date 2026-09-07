#!/system/bin/sh
# ViPER4Android-RE-AIDL granular mount support for OverlayFSx.
# Sourced by metamount.sh after META_DIR/MNT_DIR/MODULE_METADATA_DIR_REAL are set.

# ViPER4Android RE (AIDL) is handled specially. Mounting its vendor/ payload
# through the normal partition-root OverlayFS path makes /vendor itself an
# overlay. On late-loaded KernelSU devices this can invalidate GL/EGL state
# inherited by a newly restarted zygote and make Chromium's GPU process fail.
# Keep Overlayfsx behavior unchanged for every other module, but apply ViPER's
# payload only at the files/directories it actually changes.
V4A_ID="ViPER4Android-RE-AIDL"
V4A_WORK_BASE="$MODULE_METADATA_DIR_REAL/$V4A_ID"
V4A_WORK_MOUNT="$V4A_WORK_BASE/work_mount"
V4A_WORK_CFG="$V4A_WORK_BASE/work_cfg"
V4A_TMP_BASE="/data/local/tmp/overlayfsx-viper-safe.$$"
V4A_TMP_META="$V4A_TMP_BASE/metadata"
V4A_CONFIG_MAP="$V4A_TMP_BASE/config-map"
V4A_SOUNDFX_MAP="$V4A_TMP_BASE/soundfx-map"

cleanup_v4a_tmp() {
    rm -rf "$V4A_TMP_BASE" 2>/dev/null
}
trap cleanup_v4a_tmp EXIT INT TERM

mountinfo_for() {
    local target="$1"
    awk -v p="$target" '$5 == p {print; exit}' /proc/self/mountinfo 2>/dev/null
}

v4a_mount_already_active() {
    local target="$1"
    local line
    line="$(mountinfo_for "$target")"
    [ -n "$line" ] || return 1

    if echo "$line" | grep -F "$V4A_ID" >/dev/null 2>&1; then
        return 0
    fi

    log ERROR "ViPER target is already mounted by another source: $target"
    log ERROR "Refusing to stack a second mount on the same path"
    return 2
}

v4a_enabled() {
    [ -d "$MODULE_METADATA_DIR_REAL/$V4A_ID" ] || return 1
    [ -f "$MODULE_METADATA_DIR_REAL/$V4A_ID/disable" ] && return 1
    [ -f "$MODULE_METADATA_DIR_REAL/$V4A_ID/skip_mount" ] && return 1
    [ -d "$MNT_DIR/$V4A_ID" ] || return 1
    return 0
}

# ViPER's installer can retain the traditional Magisk system/vendor alias.
# Canonicalize payload paths back to the live /vendor tree when appropriate.
v4a_map_live_path() {
    local part="$1"
    local rel="$2"

    if [ "$part" = "system" ] && [ -L /system/vendor ]; then
        case "$rel" in
            vendor/*)
                echo "/vendor/${rel#vendor/}"
                return 0
                ;;
        esac
    fi

    echo "/$part/$rel"
}

v4a_add_config() {
    local dst="$1"
    local src="$2"
    local old_line old_src

    if [ -f "$V4A_CONFIG_MAP" ]; then
        old_line="$(grep -F "$dst|" "$V4A_CONFIG_MAP" 2>/dev/null | head -n 1)"
        if [ -n "$old_line" ]; then
            old_src="${old_line#*|}"
            if cmp -s "$old_src" "$src"; then
                return 0
            fi
            log ERROR "Duplicate ViPER config target has different contents: $dst"
            return 1
        fi
    fi

    echo "$dst|$src" >> "$V4A_CONFIG_MAP"
    return 0
}

v4a_add_soundfx() {
    local dst="$1"
    local src="$2"
    local new_map="$V4A_SOUNDFX_MAP.new"
    local found=0 old_dst old_srcs

    : > "$new_map"

    if [ -f "$V4A_SOUNDFX_MAP" ]; then
        while IFS='|' read -r old_dst old_srcs; do
            [ -n "$old_dst" ] || continue
            if [ "$old_dst" = "$dst" ]; then
                found=1
                case ":$old_srcs:" in
                    *:"$src":*) echo "$old_dst|$old_srcs" >> "$new_map" ;;
                    *) echo "$old_dst|$old_srcs:$src" >> "$new_map" ;;
                esac
            else
                echo "$old_dst|$old_srcs" >> "$new_map"
            fi
        done < "$V4A_SOUNDFX_MAP"
    fi

    [ "$found" -eq 1 ] || echo "$dst|$src" >> "$new_map"
    mv "$new_map" "$V4A_SOUNDFX_MAP"
    return 0
}

v4a_validate_and_plan() {
    local vroot="$MNT_DIR/$V4A_ID"
    local part srcroot src rel dst base parent link_target

    mkdir -p "$V4A_TMP_BASE" || return 1
    : > "$V4A_CONFIG_MAP"
    : > "$V4A_SOUNDFX_MAP"
    rm -f "$V4A_TMP_BASE/error"

    log INFO "Validating $V4A_ID payload for granular mounting"

    for part in $PARTITIONS; do
        srcroot="$vroot/$part"
        [ -d "$srcroot" ] || continue

        find "$srcroot" \( -type f -o -type l \) -print 2>/dev/null | while IFS= read -r src; do
            [ -n "$src" ] || continue
            rel="${src#"$srcroot/"}"

            if [ -L "$src" ]; then
                # The AIDL module currently ships exactly this compatibility
                # alias. Allow only this known symlink and reject all others.
                if [ "$part" = "system" ] && [ "$rel" = "vendor" ]; then
                    link_target="$(readlink "$src" 2>/dev/null)"
                    if [ "$link_target" = "../vendor" ]; then
                        log INFO "Allowing known ViPER alias: system/vendor -> ../vendor"
                        continue
                    fi
                fi

                log ERROR "Unsupported symlink in ViPER payload: $part/$rel"
                echo 1 > "$V4A_TMP_BASE/error"
                continue
            fi

            dst="$(v4a_map_live_path "$part" "$rel")"
            base="${dst##*/}"
            parent="${dst%/*}"

            case "$base" in
                audio_effects*.xml|audio_effects*.conf)
                    v4a_add_config "$dst" "$src" || echo 1 > "$V4A_TMP_BASE/error"
                    ;;
                *)
                    case "$parent" in
                        */lib/soundfx|*/lib64/soundfx)
                            v4a_add_soundfx "$parent" "${src%/*}" || echo 1 > "$V4A_TMP_BASE/error"
                            ;;
                        *)
                            log ERROR "Unexpected ViPER partition file: $part/$rel"
                            log ERROR "Broad /system or /vendor fallback is intentionally disabled"
                            echo 1 > "$V4A_TMP_BASE/error"
                            ;;
                    esac
                    ;;
            esac
        done
    done

    [ -f "$V4A_TMP_BASE/error" ] && return 1
    return 0
}

v4a_prepare_soundfx_bind() {
    local dst="$1"
    local srcs="$2"
    local rel work src mode rc

    # The AIDL stack on some 64-bit-only devices has no /vendor/lib/soundfx.
    # A 32-bit payload for an absent live directory is harmless and should not
    # force creation of a new vendor path.
    if [ ! -d "$dst" ]; then
        log WARN "Skipping ViPER soundfx payload because live directory is absent: $dst"
        return 0
    fi

    v4a_mount_already_active "$dst"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log INFO "ViPER soundfx mount already active at $dst; not stacking"
        return 0
    elif [ "$rc" -eq 2 ]; then
        return 1
    fi

    rel="${dst#/}"
    work="$V4A_WORK_MOUNT/$rel"
    rm -rf "$work"
    mkdir -p "$work" || return 1

    # Build a complete mirror: stock libraries first, then ViPER's additions.
    # Binding a complete directory avoids OverlayFS on /vendor while preserving
    # every Samsung/Qualcomm sound effect library.
    cp -af "$dst/." "$work/" || {
        log ERROR "Failed to mirror stock soundfx directory: $dst"
        return 1
    }

    OLD_IFS="$IFS"
    IFS=':'
    for src in $srcs; do
        [ -d "$src" ] || continue
        cp -af "$src/." "$work/" || {
            IFS="$OLD_IFS"
            log ERROR "Failed to merge ViPER soundfx payload from $src"
            return 1
        }
    done
    IFS="$OLD_IFS"

    mode="$(stat -c '%a' "$dst" 2>/dev/null)"
    [ -n "$mode" ] && chmod "$mode" "$work" 2>/dev/null
    chcon --reference="$dst" "$work" 2>/dev/null || true

    log INFO "Bind mounting merged ViPER soundfx directory: $dst"
    mount -o bind "$work" "$dst" || {
        log ERROR "Failed to bind merged soundfx directory: $dst"
        return 1
    }

    return 0
}

v4a_prepare_config_bind() {
    local dst="$1"
    local src="$2"
    local safe_name work_file mode rc

    [ -f "$dst" ] || {
        log ERROR "Stock audio effects config disappeared: $dst"
        return 1
    }

    v4a_mount_already_active "$dst"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log INFO "ViPER config mount already active at $dst; not stacking"
        return 0
    elif [ "$rc" -eq 2 ]; then
        return 1
    fi

    mkdir -p "$V4A_WORK_CFG" || return 1
    safe_name="$(echo "$dst" | sed 's#/#_#g')"
    work_file="$V4A_WORK_CFG/$safe_name"

    rm -f "$work_file"
    cp -af "$src" "$work_file" || {
        log ERROR "Failed to stage ViPER config: $dst"
        return 1
    }

    mode="$(stat -c '%a' "$dst" 2>/dev/null)"
    [ -n "$mode" ] && chmod "$mode" "$work_file" 2>/dev/null
    chcon --reference="$dst" "$work_file" 2>/dev/null || true

    log INFO "Bind mounting ViPER config: $dst"
    mount -o bind "$work_file" "$dst" || {
        log ERROR "Failed to bind ViPER config: $dst"
        return 1
    }

    return 0
}

v4a_mount_granular() {
    local dst srcs src

    v4a_validate_and_plan || return 1
    mkdir -p "$V4A_WORK_BASE" || return 1

    while IFS='|' read -r dst srcs; do
        [ -n "$dst" ] || continue
        v4a_prepare_soundfx_bind "$dst" "$srcs" || return 1
    done < "$V4A_SOUNDFX_MAP"

    while IFS='|' read -r dst src; do
        [ -n "$dst" ] || continue
        v4a_prepare_config_bind "$dst" "$src" || return 1
    done < "$V4A_CONFIG_MAP"

    log INFO "Granular ViPER mounting completed without partition-root overlays"
    return 0
}

build_filtered_metadata() {
    local entry name

    mkdir -p "$V4A_TMP_META" || return 1

    # The Overlayfsx binary sees every enabled module except ViPER. This avoids
    # touching persistent disable/skip_mount state and keeps normal behavior for
    # all other modules.
    for entry in "$MODULE_METADATA_DIR_REAL"/*; do
        [ -d "$entry" ] || continue
        name="${entry##*/}"
        [ "$name" = "$V4A_ID" ] && continue
        ln -s "$entry" "$V4A_TMP_META/$name" 2>/dev/null || return 1
    done

    return 0
}

v4a_check_stale_root_overlay() {
    if grep -E "^KSU /(vendor|system) overlay .*${V4A_ID}" /proc/mounts >/dev/null 2>&1; then
        log ERROR "Legacy ViPER /vendor or /system root overlay is still active"
        log ERROR "Perform a full reboot before activating the ViPER-safe build"
        return 75
    fi
    return 0
}

v4a_warn_other_root_overlays() {
    if grep -E '^KSU /(vendor|system) overlay ' /proc/mounts >/dev/null 2>&1; then
        log WARN "A partition-root /vendor or /system overlay from another module is already active"
    fi
}
