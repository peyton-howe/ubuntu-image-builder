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
    echo "Please run as root"
    exit 1
fi

ROOT_DIR=$(pwd)
KERNEL_DIR="${ROOT_DIR}/build/kernel"
BLOBS_DIR="${ROOT_DIR}/build/u-boot"

rootfs_tar=$(readlink -f build/rootfs/ubuntu-${RELEASE}-${FLAVOR}-arm64.tar.gz)
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
IMG="../images/$(basename "${rootfs_tar}" .tar)-rk3588.img"
size="$(( $(wc -c < "${rootfs_tar}" ) / 1024 / 1024 ))"
truncate -s "$(( size + 4096 ))M" "${IMG}"

echo "[+] Creating loop device..."
loop="$(losetup -f)"
losetup -P "${loop}" "${IMG}"
disk="${loop}"

# Cleanup on exit
trap 'cleanup_loopdev "$loop"' EXIT

# Ensure disk is not mounted
mount_point=/tmp/mnt
umount "${disk}"* 2> /dev/null || true
umount ${mount_point}/* 2> /dev/null || true
mkdir -p ${mount_point}

### =========================
### Partition image (Josh’s logic)
### =========================
dd if=/dev/zero of="${disk}" count=4096 bs=512
parted --script "${disk}" \
    mklabel gpt \
    mkpart primary ext4 16MiB 100%

# Create partitions
{
    echo "t"
    echo "1"
    echo "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    echo "w"
} | fdisk "${disk}" &> /dev/null || true

partprobe "${disk}"
partition_char="$(if [[ ${loop: -1} =~ [0-9] ]]; then echo p; fi)"

sleep 1

wait_loopdev "${disk}${partition_char}1" 60 || {
        echo "Failure to create ${disk}${partition_char}1 in time"
        exit 1
}

sleep 1

# Generate random uuid for rootfs
root_uuid=$(cat /proc/sys/kernel/random/uuid)

echo "[+] Creating filesystems..."
# Create filesystems on partitions
dd if=/dev/zero of="${disk}${partition_char}1" bs=1KB count=10 > /dev/null
mkfs.ext4 -U "${root_uuid}" -L desktop-rootfs "${disk}${partition_char}1"

# Mount partitions
mkdir -p ${mount_point}/writable
mount "${disk}${partition_char}1" ${mount_point}/writable

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
dd if="${BLOBS_DIR}/idbloader.img" of="$loop" seek=64 conv=notrunc
dd if="${BLOBS_DIR}/u-boot.itb" of="$loop" seek=16384 conv=notrunc

# if [ -f "{$BLOBS_DIR}/trust.img" ]; then
#     dd if=blobs/trust.img of="$loop" seek=24576 conv=notrunc
# fi

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
chroot ${mount_point}/writable /bin/bash -c "
set -e
# Ensure /etc/default/u-boot exists
mkdir -p /etc/default

# Remove any previous CMDLINE definition to avoid duplicates
sed -i '/^U_BOOT_PARAMETERS=/d' /etc/default/u-boot || true

# Add new parameters (you can append others as needed)
cat >> /etc/default/u-boot <<EOF
U_BOOT_PARAMETERS=\"console=ttyS2,1500000 console=tty1 root=UUID=${root_uuid,,} rw rootwait quiet splash plymouth.ignore-serial-consoles cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory\"
EOF
"

chroot ${mount_point}/writable/ u-boot-update

sync --file-system
sync

### =========================
### Cleanup and compress
### =========================

# Umount partitions
umount "${disk}${partition_char}1"
umount "${disk}${partition_char}2" 2> /dev/null || true

# Remove loop device
losetup -d "${loop}"

# Exit trap is no longer needed
trap '' EXIT

echo "[+] Compressing image..."
xz -T0 -v -z -f "$IMG"

echo "[✓] Image built and compressed: ${IMG}.xz"
