#!/system/bin/sh

MODDIR="${0%/*}"
ksud kernel nuke-ext4-sysfs "$MODDIR/mnt"
