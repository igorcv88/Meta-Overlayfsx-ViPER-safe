// Constants for KernelSU module mounting

// Metadata follows KernelSU's module directory, while mutable content lives in
// persistent storage outside the metamodule directory so module updates cannot
// be blocked by a live mountpoint below /data/adb/modules/<metamodule-id>.
pub const MODULE_METADATA_DIR: &str = "/data/adb/modules/";
pub const MODULE_CONTENT_DIR: &str = "/data/adb/overlayfsx-data/mnt/";

// Legacy constant (for backwards compatibility)
pub const _MODULE_DIR: &str = "/data/adb/modules/";

// Status marker files
pub const DISABLE_FILE_NAME: &str = "disable";
pub const _REMOVE_FILE_NAME: &str = "remove";
pub const SKIP_MOUNT_FILE_NAME: &str = "skip_mount";

// System directories
pub const SYSTEM_RW_DIR: &str = "/data/adb/modules/.rw/";
pub const KSU_OVERLAY_SOURCE: &str = "KSU";
