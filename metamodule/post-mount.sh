#!/system/bin/sh

# Hide the ext4 backing mount from sysfs using the new external state path.
ksud kernel nuke-ext4-sysfs "/data/adb/overlayfsx-data/mnt"
