#!/system/bin/sh
# ViPER4Android RE (AIDL) lifecycle repair for late-mounted audio effects.
# Sourced by metamount.sh after utils.sh and viper_safe.sh.

v4a_effect_factory_pid() {
    local pid

    pid="$(
        dumpsys --pid android.hardware.audio.effect.IFactory/default 2>/dev/null |
            grep -oE '[0-9]+' |
            head -n 1
    )"

    if [ -z "$pid" ]; then
        pid="$(pidof audiohalservice.qti 2>/dev/null | awk '{print $1}')"
    fi

    [ -n "$pid" ] && printf '%s\n' "$pid"
}

v4a_cleanup_deleted_binds() {
    local targets target failed

    targets="$(
        awk -v id="$V4A_ID" '
            index($0, id) && (index($0, "//deleted") || index($0, "(deleted)")) {
                print $5
            }
        ' /proc/self/mountinfo 2>/dev/null |
            sort -u
    )"

    [ -n "$targets" ] || return 0

    failed=0
    for target in $targets; do
        log WARN "Stale deleted-backed ViPER bind detected: $target"
        if umount "$target" 2>/dev/null; then
            log INFO "Removed stale ViPER bind: $target"
        else
            log ERROR "Failed to remove stale ViPER bind: $target"
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}

v4a_reload_audio_stack_if_needed() {
    local old_hal new_hal old_af new_af i

    # During a normal early boot the vendor HAL may not exist yet. In that
    # case it will parse the already-mounted ViPER configuration when it starts.
    if [ "$(getprop init.svc.vendor.audio-hal-aidl 2>/dev/null)" != "running" ]; then
        log INFO "Audio HAL not running yet; no ViPER reload required"
        return 0
    fi

    old_hal="$(v4a_effect_factory_pid)"

    # Idempotence: if the live Factory already maps ViPER, restarting the audio
    # stack only creates needless disruption.
    if [ -n "$old_hal" ] && [ -r "/proc/$old_hal/maps" ] &&
        grep -F "libv4a_aidl.so" "/proc/$old_hal/maps" >/dev/null 2>&1; then
        log INFO "ViPER AIDL library already loaded by audio HAL pid=$old_hal; reload not required"
        return 0
    fi

    log INFO "Restarting QTI audio effect factory after ViPER mounts"
    setprop ctl.restart vendor.audio-hal-aidl || {
        log ERROR "Failed to request vendor.audio-hal-aidl restart"
        return 1
    }

    new_hal=""
    i=0
    while [ "$i" -lt 20 ]; do
        new_hal="$(v4a_effect_factory_pid)"
        if [ -n "$new_hal" ] && [ -d "/proc/$new_hal" ] &&
            { [ -z "$old_hal" ] || [ "$new_hal" != "$old_hal" ]; }; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ -z "$new_hal" ] || { [ -n "$old_hal" ] && [ "$new_hal" = "$old_hal" ]; }; then
        log ERROR "QTI audio HAL did not restart after ViPER mount"
        return 1
    fi

    i=0
    while [ "$i" -lt 10 ]; do
        if [ -r "/proc/$new_hal/maps" ] &&
            grep -F "libv4a_aidl.so" "/proc/$new_hal/maps" >/dev/null 2>&1; then
            log INFO "ViPER AIDL library loaded by audio HAL pid=$new_hal"
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ ! -r "/proc/$new_hal/maps" ] ||
        ! grep -F "libv4a_aidl.so" "/proc/$new_hal/maps" >/dev/null 2>&1; then
        log ERROR "Audio HAL restarted but ViPER AIDL library was not loaded"
        return 1
    fi

    if [ "$(getprop init.svc.audioserver 2>/dev/null)" = "running" ]; then
        old_af="$(pidof audioserver 2>/dev/null | awk '{print $1}')"
        log INFO "Restarting audioserver after ViPER HAL reload"

        setprop ctl.restart audioserver || {
            log ERROR "Failed to request audioserver restart"
            return 1
        }

        new_af=""
        i=0
        while [ "$i" -lt 15 ]; do
            new_af="$(pidof audioserver 2>/dev/null | awk '{print $1}')"
            if [ -n "$new_af" ] && { [ -z "$old_af" ] || [ "$new_af" != "$old_af" ]; }; then
                log INFO "audioserver restarted pid=${old_af:-none}->$new_af"
                break
            fi
            sleep 1
            i=$((i + 1))
        done

        if [ -z "$new_af" ] || { [ -n "$old_af" ] && [ "$new_af" = "$old_af" ]; }; then
            log ERROR "audioserver did not restart after ViPER HAL reload"
            return 1
        fi
    fi

    return 0
}
