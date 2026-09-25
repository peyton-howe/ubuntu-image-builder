#!/bin/bash
# Grows the root partition to fill whatever disk it landed on (the image is
# built to just fit the rootfs, but SD cards/eMMC modules are almost always
# bigger). systemd-growfs-root.service then grows the ext4 filesystem to
# match, via the x-systemd.growfs fstab option already set on / -- this only
# has to widen the partition table entry first.
set -e

root_src="$(findmnt -no SOURCE /)"
part_base="$(basename "${root_src}")"
disk_name=""
part_num=""

# Pure string parsing -- no dependency on lsblk or /sys being fully
# populated this early in boot (lsblk -no PKNAME/PARTN proved unreliable
# here, on both a dev VM and real hardware).
if [[ "${part_base}" =~ ^(.+[0-9])p([0-9]+)$ ]]; then
    # mmcblk0p1, nvme0n1p1 -- disk name ends in a digit, needs a 'p' separator
    disk_name="${BASH_REMATCH[1]}"
    part_num="${BASH_REMATCH[2]}"
elif [[ "${part_base}" =~ ^([a-zA-Z]+)([0-9]+)$ ]]; then
    # sda1, vda1 -- plain letters then digits, no separator
    disk_name="${BASH_REMATCH[1]}"
    part_num="${BASH_REMATCH[2]}"
fi
root_disk="/dev/${disk_name}"

if [[ -z "${root_src}" || -z "${disk_name}" || ! "${part_num}" =~ ^[0-9]+$ ]]; then
    echo "growpart-root: could not determine root disk/partition from '${root_src}', skipping"
    exit 0
fi

# growpart exits 1 both on real failures and on "already at max size" -- it's
# idempotent and safe to just ignore either way after the first successful run.
growpart "${root_disk}" "${part_num}" || true
