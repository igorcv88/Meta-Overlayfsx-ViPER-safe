## v1.3.4-viper-safe.2 - Persistent late-load ViPER mounts

### ViPER4Android RE (AIDL)

- Relabels the merged `lib*/soundfx` mirror recursively to the SELinux context of the live target before bind mounting it.
- Fails closed if the target context cannot be derived, `chcon` fails, or staged/live context validation does not match.
- Preserves directory ownership and mode and verifies `libv4a_aidl.so` after the live bind.
- Applies the same target-derived, fail-hard SELinux labeling to individually bound `audio_effects*.xml` / `audio_effects*.conf` files.
- Removes the unsupported `chcon --reference=... || true` behavior that allowed `system_file` mirrors to replace Samsung `vendor_file` soundfx trees.
- Fixes `post-mount.sh` to derive the metamodule path from `MODDIR` instead of the stale `/data/adb/modules/overlayfsx` ID.

## v1.3.4-viper-safe.1 - Granular ViPER mounts

### ViPER4Android RE (AIDL)

- Excludes `ViPER4Android-RE-AIDL` from the normal partition-root OverlayFS pass.
- Keeps `/vendor` and `/system` on their original mounts instead of overlaying the entire partition for ViPER.
- Bind-mounts patched `audio_effects*.xml` / `audio_effects*.conf` files individually.
- Builds a complete stock + ViPER mirror of each existing `lib*/soundfx` directory and bind-mounts only that directory.
- Allows only the known `system/vendor -> ../vendor` compatibility symlink; unexpected ViPER partition payloads fail closed instead of falling back to a broad root overlay.
- Skips the unused 32-bit `soundfx` payload when the live device has no corresponding directory.
- Detects already-active ViPER granular mounts to avoid stacking mounts across repeated soft reboots.
- Refuses activation over a stale legacy ViPER `/vendor` or `/system` root overlay and requires a full reboot first.
- Removed the upstream `updateJson` from `module.prop` so an automatic update cannot replace this fork with the non-ViPER-safe build.

## v1.3.4 - Kernel Inspector & Next-Gen WebUI

### ✨ New Features

- **Kernel Mount Inspector (`inspect`):** New subcommand that reads `/proc/mounts` directly from the kernel to report active overlays and file conflicts. Supports JSON output (`-r`) for WebUI integration.
- **Staged Module Updates:** Module payloads are now staged to `_update` folders and atomically swapped at boot to prevent VFS cache corruption.
- **First-Time Module Sync:** Interactive option during initial install to auto-sync existing modules into the ext4 image using volume key selection.
- **Unified Logging:** Shell scripts now use leveled `INFO`/`WARN`/`ERROR` logging with consistent prefixes in `overlayfsx.log`.

### 🎨 WebUI Redesign

- Complete glass-morphism visual overhaul with Google Fonts (Outfit + DM Mono)
- SVG donut chart showing per-partition storage with glow filters
- Module info modal with conflict visualization and clickable path details
- Log viewer with color-coded levels

### 🛠️ Improvements

- `utils.sh`: Added `modify_prop()`, `chooseport()`, tree-style conflict output
- `metamount.sh`: Staged update swaps, binary output redirected to log file
- `customize.sh`: First-time sync with self-exclusion logic
- `uninstall.sh`: Now disables modules instead of removing them
