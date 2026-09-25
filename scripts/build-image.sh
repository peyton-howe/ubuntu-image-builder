#!/usr/bin/env bash
set -eE
trap 'echo "Error in $0 on line $LINENO"; cleanup_loopdev "$loop"' ERR

### =========================
### Helper Functions
### =========================

cleanup_loopdev() {
    local loop="$1"
    if [ -z "$loop" ] || [ ! -b "$loop" ]; then
        return
    fi

    sync
    sleep 1

    for part in "${loop}"p*; do
        if mnt=$(findmnt -n -o target -S "$part"); then
            umount -lf "$mnt" || true
        fi
    done

    losetup -d "$loop" 2>/dev/null || true
}

wait_loopdev() {
    local loop="$1"
    local seconds="$2"
    until test $((seconds--)) -eq 0 -o -b "${loop}"; do sleep 1; done
    ((++seconds))
    ls -l "${loop}" &> /dev/null
}

### =========================
### Check preconditions
### =========================
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run ./build.sh (it uses a user namespace) or sudo $0"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
# shellcheck source=/dev/null
source scripts/common.sh
require_cmds parted mkfs.ext4 dd tar xz

ROOT_DIR=$(pwd)
KERNEL_DIR="${ROOT_DIR}/build/kernel"
BLOBS_DIR="${ROOT_DIR}/build/u-boot"

rootfs_tar=$(readlink -f build/rootfs/ubuntu-${RELEASE}-preinstalled-${FLAVOR}-arm64.tar.gz)
if [[ ! -f "$rootfs_tar" ]]; then
    echo "Rootfs tarball not found: $rootfs_tar"
    exit 1
fi

# Output directories
cd "$(dirname "$0")"/..
mkdir -p build images
cd build

### =========================
### Create disk image
### =========================
echo "[+] Creating empty image..."
IMG="../images/$(basename "${rootfs_tar}" .tar.gz)-${BOARD}.img"
# Size off the *uncompressed* rootfs, not the gzip'd tarball -- a desktop
# rootfs commonly gzips down to ~1/2 its real size, so sizing off the
# compressed number left the partition smaller than the data going into it
# ("No space left on device" partway through extraction). The extracted
# directory build-rootfs.sh made the tarball from is still on disk; fall
# back to a generous multiple of the compressed size if it isn't.
rootfs_dir="$(dirname "${rootfs_tar}")/${RELEASE}-${FLAVOR}"
if [[ -d "${rootfs_dir}" ]]; then
    size="$(du -sm "${rootfs_dir}" | cut -f1)"
else
    size="$(( $(wc -c < "${rootfs_tar}") * 3 / 1024 / 1024 ))"
fi
truncate -s "$(( size + 1024 ))M" "${IMG}"

mount_point=/tmp/mnt
mkdir -p ${mount_point}
ROOTFS_OFFSET=$((16 * 1024 * 1024))
DISK_MODE=loop
loop=""

echo "[+] Partitioning image..."
parted --script "${IMG}" \
    mklabel gpt \
    mkpart primary ext4 16MiB 100%

root_uuid=$(cat /proc/sys/kernel/random/uuid)

if loop="$(losetup -f --show -P "${IMG}" 2>/dev/null)"; then
    echo "[+] Using loop device ${loop}"
    disk="${loop}"
    trap 'cleanup_loopdev "$loop"' EXIT
    partition_char="$(if [[ ${loop: -1} =~ [0-9] ]]; then echo p; fi)"
    wait_loopdev "${disk}${partition_char}1" 60 || {
        echo "Failure to create ${disk}${partition_char}1 in time"
        exit 1
    }
    echo "[+] Creating filesystems..."
    # Create filesystems on partitions
    mkfs.ext4 -U "${root_uuid}" -L desktop-rootfs "${disk}${partition_char}1"
    
    # Mount partitions
    mkdir -p ${mount_point}/writable
    mount "${disk}${partition_char}1" ${mount_point}/writable
else
    echo "[+] Loop devices unavailable; using fuse2fs at 16MiB offset"
    require_cmds fuse2fs
    DISK_MODE=fuse
    disk=""
    echo "[+] Creating filesystems..."
    mkfs.ext4 -F -U "${root_uuid}" -L desktop-rootfs -E "offset=${ROOTFS_OFFSET}" "${IMG}"
    mkdir -p ${mount_point}/writable
    fuse2fs -o "fakeroot,rw+,offset=${ROOTFS_OFFSET}" "${IMG}" ${mount_point}/writable
    trap 'fusermount -u ${mount_point}/writable 2>/dev/null || umount ${mount_point}/writable 2>/dev/null || true' EXIT
fi

### =========================
### Extract rootfs
### =========================
echo "[+] Extracting rootfs..."
tar -xpf "$rootfs_tar" -C ${mount_point}/writable

# Create fstab entries
echo "# <file system>     <mount point>  <type>  <options>   <dump>  <fsck>" > ${mount_point}/writable/etc/fstab
echo "UUID=${root_uuid,,} /              ext4    defaults,x-systemd.growfs    0       1" >> ${mount_point}/writable/etc/fstab

### =========================
### Write bootloader / optional trust.img
### =========================
echo "[+] Writing bootloader..."
# dd if="${BLOBS_DIR}/idbloader.img" of="$loop" seek=64 conv=notrunc
# dd if="${BLOBS_DIR}/u-boot.itb" of="$loop" seek=16384 conv=notrunc

# if [ -f "${BLOBS_DIR}/idbloader.img" ]; then
#     echo "writing idbloader.img"
#     dd if="${BLOBS_DIR}/idbloader.img" of="$loop" seek=64 conv=notrunc
# fi

# if [ -f "${BLOBS_DIR}/u-boot.itb" ]; then
#     echo "writing u-boot.itb"
#     dd if="${BLOBS_DIR}/u-boot.itb" of="$loop" seek=16384 conv=notrunc
# fi

dd if="${BLOBS_DIR}/u-boot-rockchip.bin" of="${IMG}" bs=32k seek=1 conv=notrunc status=none

prepare_chroot_mounts "${mount_point}/writable"

# Grow the root partition to fill whatever disk it's flashed to on first boot
# (the image is only sized to fit the rootfs) -- x-systemd.growfs in fstab
# already grows the filesystem to match once the partition itself is bigger.
echo "[+] Enabling first-boot partition auto-resize..."
mkdir -p "${mount_point}/writable/usr/lib/scripts"
cp "${ROOT_DIR}/overlay/usr/lib/scripts/growpart-root.sh" "${mount_point}/writable/usr/lib/scripts/growpart-root.sh"
cp "${ROOT_DIR}/overlay/usr/lib/systemd/system/growpart-root.service" "${mount_point}/writable/usr/lib/systemd/system/growpart-root.service"
chroot "${mount_point}/writable" systemctl enable growpart-root.service

# gnome-initial-setup's first-run user only gets accountsservice's "admin"
# group set, not video/audio/render -- fine for local GNOME sessions (udev's
# uaccess tags already grant those over the active seat) but not SSH access.
echo "[+] Enabling first-boot user media-group fixup..."
cp "${ROOT_DIR}/overlay/usr/lib/scripts/fixup-user-media-groups.sh" "${mount_point}/writable/usr/lib/scripts/fixup-user-media-groups.sh"
cp "${ROOT_DIR}/overlay/usr/lib/systemd/system/fixup-user-media-groups.service" "${mount_point}/writable/usr/lib/systemd/system/fixup-user-media-groups.service"
chroot "${mount_point}/writable" systemctl enable fixup-user-media-groups.service

# Source board-specific configuration
if [[ -f "${ROOT_DIR}/configs/boards/${BOARD}.sh" ]]; then
    source "${ROOT_DIR}/configs/boards/${BOARD}.sh"
else
    echo "Warning: No board config found for ${BOARD}"
fi

# Run build image hook to handle board specific changes
if [[ $(type -t build_image_hook__${BOARD}) == function ]]; then
    echo "[+] Writing image changes..."
    build_image_hook__${BOARD} "${ROOT_DIR}/overlay" "${mount_point}/writable" "${SUITE}" "${root_uuid}"
fi

# =========================
# Configure u-boot defaults (add quiet splash)
# =========================
echo "[+] Configuring u-boot defaults..."
KERNEL_TYPE="${KERNEL_TYPE:-stock}"
if [[ "${KERNEL_TYPE}" == "mainline" && -n "${U_BOOT_FDT_MAINLINE}" ]]; then
    FDT_REL="${U_BOOT_FDT_MAINLINE}"
elif [[ "${KERNEL_TYPE}" == "stock" && -n "${U_BOOT_FDT_MAINLINE}" ]]; then
    # Stock Ubuntu ships mainline-style rockchip DTBs under linux-image-*.
    FDT_REL="${U_BOOT_FDT_MAINLINE}"
else
    FDT_REL="${U_BOOT_FDT}"
fi
BOARD_OVERLAYS="${U_BOOT_FDT_OVERLAYS:-}"
chroot ${mount_point}/writable /bin/bash -c "
set -e
# Ensure /etc/default/u-boot exists
mkdir -p /etc/default

# Remove any previous CMDLINE definition to avoid duplicates
sed -i '/^U_BOOT_PARAMETERS=/d' /etc/default/u-boot || true
rm -f /etc/default/u-boot

# Resolve the installed kernel's dtb path dynamically instead of hardcoding
# a kernel version string that goes stale on every rebuild.
FDT_BASENAME=\$(basename \"${FDT_REL}\")
FDT_ABS_PATH=\$(find /usr/lib/linux-image-*/ /lib/linux-image-*/ /lib/firmware/*/device-tree/ /boot/dtbs/*/ \\
    -name \"\${FDT_BASENAME}\" 2>/dev/null | grep -E 'mainline-rk3588|rockchip|linux-image' | head -1 || true)
if [ -z \"\${FDT_ABS_PATH}\" ]; then
    FDT_ABS_PATH=\$(find /usr/lib/linux-image-*/ /lib/linux-image-*/ /lib/firmware/*/device-tree/ /boot/dtbs/*/ \\
        -name \"\${FDT_BASENAME}\" 2>/dev/null | head -1 || true)
fi
if [ -z \"\${FDT_ABS_PATH}\" ]; then
    echo \"ERROR: could not find \${FDT_BASENAME} under linux-image or firmware dtb dirs\" >&2
    echo \"Installed linux-image packages:\" >&2
    dpkg -l 'linux-image-*' 2>/dev/null >&2 || true
    find /usr/lib/linux-image-* /lib/linux-image-* -name '*.dtb' 2>/dev/null | head -20 >&2 || true
    exit 1
fi
FDT_OVERLAYS_DIR=\$(dirname \"\${FDT_ABS_PATH}\")

# Seed board overlays from board config (panthor etc.); camera overlays
# package may append more via apply-overlays.sh below.
BOARD_OVERLAYS_ABS=\"\"
for ov in ${BOARD_OVERLAYS}; do
    [[ -z \$ov ]] && continue
    base=\$(basename \"\$ov\")
    found=\$(find \"\${FDT_OVERLAYS_DIR}\" /usr/share/rk3588-camera/overlays /lib/firmware -name \"\${base}\" 2>/dev/null | head -1 || true)
    if [ -n \"\${found}\" ]; then
        BOARD_OVERLAYS_ABS=\"\${BOARD_OVERLAYS_ABS} \${found}\"
    else
        echo \"WARNING: board overlay \${base} not found on rootfs\" >&2
    fi
done
BOARD_OVERLAYS_ABS=\$(echo \"\${BOARD_OVERLAYS_ABS}\" | xargs)

# Add new parameters (you can append others as needed)
cat >> /etc/default/u-boot <<EOF
# /etc/default/u-boot - configuration file for u-boot-update(8)

#U_BOOT_UPDATE=\"true\"

#U_BOOT_ALTERNATIVES=\"default recovery\"
#U_BOOT_DEFAULT=\"l0\"
#U_BOOT_PROMPT=\"1\"
#U_BOOT_ENTRIES=\"all\"
#U_BOOT_MENU_LABEL=\"Debian GNU/Linux\"
U_BOOT_PARAMETERS=\"console=ttyS2,1500000 console=tty1 root=UUID=${root_uuid,,} rw rootwait quiet splash plymouth.ignore-serial-consoles cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory\"
#U_BOOT_ROOT=\"\"
#U_BOOT_TIMEOUT=\"50\"
U_BOOT_FDT=\"\${FDT_ABS_PATH}\"
#U_BOOT_FDT_DIR=\"/lib/firmware/\"
U_BOOT_FDT_OVERLAYS=\"\${BOARD_OVERLAYS_ABS}\"
#U_BOOT_FDT_OVERLAYS_DIR=\"\${FDT_OVERLAYS_DIR}/\"
#U_BOOT_SYNC_DTBS=\"false\"
EOF

# Only run when the user has selected camera overlays; empty default is fine.
if [ -x /usr/lib/rk3588-camera/apply-overlays.sh ] \\
    && [ -f /etc/rk3588-camera/overlays.conf ] \\
    && grep -q '^RK3588_CAMERA_OVERLAYS=\"[^[:space:]]' /etc/rk3588-camera/overlays.conf; then
    /usr/lib/rk3588-camera/apply-overlays.sh || true
fi
"

chroot ${mount_point}/writable/ u-boot-update

teardown_chroot_mounts "${mount_point}/writable"

sync --file-system
sync

### =========================
### Cleanup and compress
### =========================

# Umount partitions
if [[ "${DISK_MODE}" == "loop" ]]; then
    umount "${disk}${partition_char}1"
    umount "${disk}${partition_char}2" 2>/dev/null || true
    
    # Remove loop device
    losetup -d "${loop}"
else
    fusermount -u ${mount_point}/writable 2>/dev/null || umount ${mount_point}/writable
fi

# Exit trap is no longer needed
trap '' EXIT

if [[ "${COMPRESS:-Y}" == "Y" ]]; then
    echo "[+] Compressing image..."
    xz -T0 -v -z -f "$IMG"
    # xz -z without --keep removes the source on success; be explicit in case
    # a future xz flag change leaves the .img behind.
    if [[ -f ${IMG}.xz && -f ${IMG} ]]; then
        rm -f "$IMG"
    fi
    echo "[✓] Image built and compressed: ${IMG}.xz"
else
    echo "[✓] Image built: ${IMG}"
fi