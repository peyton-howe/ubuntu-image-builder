#!/usr/bin/env bash
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run ./build.sh (it uses a user namespace) or sudo $0"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
# shellcheck source=/dev/null
source scripts/common.sh
mkdir -p build/rootfs
ROOT_DIR="$(pwd)"
cd build/rootfs

if [[ -z ${RELEASE} ]]; then
    echo "Error: RELEASE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "${ROOT_DIR}/configs/releases/${RELEASE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "${ROOT_DIR}/configs/flavors/${FLAVOR}.sh"

TARBALL="ubuntu-${RELEASE}-preinstalled-${FLAVOR}-arm64.tar.gz"
if [[ -f ${TARBALL} ]]; then
    echo "[+] Rootfs tarball already exists: ${TARBALL}"
    exit 0
fi

if [[ "${FLAVOR}" == "desktop" ]]; then
    ISO_URL="${UBUNTU_DESKTOP_ISO_URL:?Set UBUNTU_DESKTOP_ISO_URL in configs/releases/${RELEASE}.sh}"
    SHA256SUMS_URL="${UBUNTU_DESKTOP_SHA256SUMS_URL:-${UBUNTU_SHA256SUMS_URL:-}}"
else
    ISO_URL="${UBUNTU_SERVER_ISO_URL:?Set UBUNTU_SERVER_ISO_URL in configs/releases/${RELEASE}.sh}"
    SHA256SUMS_URL="${UBUNTU_SERVER_SHA256SUMS_URL:-${UBUNTU_SHA256SUMS_URL:-}}"
fi

ISO_NAME="$(basename "${ISO_URL}")"
ISO_PATH="$(pwd)/${ISO_NAME}"
ROOTFS_DIR="${RELEASE}-${FLAVOR}"
ISO_MNT="$(pwd)/iso-mnt"
KERNEL_DIR="${ROOT_DIR}/build/kernel"
DEBS_DIR="${ROOT_DIR}/build/debs"
KERNEL_TYPE="${KERNEL_TYPE:-stock}"
BOARD_PKG="$(board_support_package "${BOARD:-}")"

cleanup_iso() {
    if mountpoint -q "${ISO_MNT}" 2>/dev/null; then
        umount "${ISO_MNT}" || true
    fi
}
trap 'cleanup_iso; echo Error: in $0 on line $LINENO' ERR

require_cmds unsquashfs sha256sum
if ! command -v wget >/dev/null && ! command -v curl >/dev/null; then
    echo "Error: need wget or curl"
    exit 1
fi

echo "[+] Downloading ${ISO_NAME}..."
if command -v wget >/dev/null; then
    wget -c --progress=dot:giga -O "${ISO_PATH}" "${ISO_URL}"
else
    curl -L --continue-at - -o "${ISO_PATH}" "${ISO_URL}"
fi

if [[ -n "${SHA256SUMS_URL}" ]]; then
    echo "[+] Verifying SHA256..."
    wget -q -O SHA256SUMS "${SHA256SUMS_URL}"
    grep " ${ISO_NAME}$\| \*${ISO_NAME}$" SHA256SUMS | sha256sum -c -
fi

mkdir -p "${ISO_MNT}"
ISO_LOOP_MOUNTED=0
if mount -o loop,ro "${ISO_PATH}" "${ISO_MNT}" 2>/dev/null; then
    ISO_LOOP_MOUNTED=1
else
    echo "[+] Could not loop-mount ISO; extracting with bsdtar..."
    require_cmds bsdtar
    bsdtar -xf "${ISO_PATH}" -C "${ISO_MNT}"
fi

if [[ -d ${ROOTFS_DIR} ]]; then
    rm -rf "${ROOTFS_DIR}"
fi

CASPER="${ISO_MNT}/casper"
layers=()
if [[ "${FLAVOR}" == "desktop" ]]; then
    # Installed desktop = minimal + standard (+ English langpack). Skip *.live.*
    for name in minimal.squashfs minimal.standard.squashfs minimal.standard.en.squashfs minimal.en.squashfs; do
        [[ -f "${CASPER}/${name}" ]] && layers+=("${CASPER}/${name}")
    done
else
    for name in ubuntu-server-minimal.squashfs ubuntu-server-minimal.ubuntu-server.squashfs; do
        [[ -f "${CASPER}/${name}" ]] && layers+=("${CASPER}/${name}")
    done
fi
if [[ ${#layers[@]} -eq 0 && -f "${CASPER}/filesystem.squashfs" ]]; then
    layers+=("${CASPER}/filesystem.squashfs")
fi
if [[ ${#layers[@]} -eq 0 ]]; then
    echo "Error: no squashfs layers found in ${CASPER}"
    ls -la "${CASPER}" || true
    exit 1
fi

# Device nodes in the squashfs (console, null, ...) need CAP_MKNOD in the
# initial namespace. In a user namespace that fails; udev/devtmpfs recreates
# them on the board and we bind-mount /dev for chroot.
unsquashfs_flags=(-d "${ROOTFS_DIR}")
if unsquashfs -help 2>&1 | grep -q -- '-ignore-errors'; then
    unsquashfs_flags+=(-ignore-errors -no-exit-code)
fi

unsquashfs_layer() {
    local extra=("${unsquashfs_flags[@]}")
    extra+=("$@")
    if unsquashfs "${extra[@]}"; then
        return 0
    fi
    local rc=$?
    if [[ -e "${ROOTFS_DIR}/etc/os-release" || -e "${ROOTFS_DIR}/usr/lib/os-release" ]]; then
        echo "[!] unsquashfs exited ${rc} (character devices in user namespace); continuing"
        return 0
    fi
    echo "Error: unsquashfs failed (${rc}) and rootfs looks empty"
    return "${rc}"
}

first=1
for sq in "${layers[@]}"; do
    echo "[+] Extracting $(basename "${sq}")..."
    if [[ ${first} -eq 1 ]]; then
        unsquashfs_layer "${sq}"
        first=0
    else
        unsquashfs_layer -f "${sq}"
    fi
done

cleanup_iso
trap 'echo Error: in $0 on line $LINENO' ERR

if [[ "$(uname -m)" != "aarch64" ]]; then
    cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"
fi

# =========================
# 2. Setup chroot environment
# =========================
echo "[+] Preparing chroot networking..."

rm -f "${ROOTFS_DIR}/etc/resolv.conf"
tee "${ROOTFS_DIR}/etc/resolv.conf" >/dev/null <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# =========================
# 3. Stage .debs for chroot install
# =========================
mkdir -p "${ROOTFS_DIR}/tmp/kernel-debs" "${ROOTFS_DIR}/tmp/rk3588-debs"

if is_stock_kernel; then
    echo "[+] Stock kernel path: staging board/camera packages from ${DEBS_DIR}"
    if ! compgen -G "${DEBS_DIR}/rk3588-camera-overlays_*.deb" > /dev/null \
        || ! compgen -G "${DEBS_DIR}/rk3588-camera-dkms_*.deb" > /dev/null; then
        echo "Error: missing camera .debs in ${DEBS_DIR}; run ./scripts/build-debs.sh first"
        exit 1
    fi
    cp -v "${DEBS_DIR}/rk3588-camera-overlays_"*.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
    cp -v "${DEBS_DIR}/rk3588-camera-dkms_"*.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
    if [[ -n ${BOARD_PKG} ]]; then
        if ! compgen -G "${DEBS_DIR}/${BOARD_PKG}_*.deb" > /dev/null; then
            echo "Error: missing ${BOARD_PKG} .deb in ${DEBS_DIR}"
            exit 1
        fi
        cp -v "${DEBS_DIR}/${BOARD_PKG}_"*.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
    else
        echo "Warning: no board support package mapping for BOARD=${BOARD:-unset}"
    fi
else
    echo "[+] Custom kernel path (${KERNEL_TYPE}): staging kernel debs from ${KERNEL_DIR}"
    if compgen -G "${KERNEL_DIR}/*.deb" > /dev/null; then
        cp "${KERNEL_DIR}"/*.deb "${ROOTFS_DIR}/tmp/kernel-debs/"
    fi
fi

prepare_chroot_mounts "${ROOTFS_DIR}"

# =========================
# 4. Configure rootfs inside chroot
# =========================
chroot "${ROOTFS_DIR}" /bin/bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
KERNEL_TYPE='${KERNEL_TYPE}'

# The live image ships a cdrom source (installer normally drops this
# post-install); there's no /cdrom mount here so apt-get update fails on it.
rm -f /etc/apt/sources.list.d/cdrom.sources

# u-boot-menu's postinst (u-boot-update) hard-fails without /etc/fstab, but
# the real one (with the board's root UUID) isn't written until build-image.sh
# partitions the image. Stub it so the package configures; it gets overwritten.
if [[ ! -e /etc/fstab ]]; then
    echo '# placeholder, replaced by build-image.sh' > /etc/fstab
fi

# DMA-BUF heap drivers (system_heap, cma_heap) are built as modules, not
# built-in, and nothing hot-plug-triggers them since they're not tied to any
# discoverable device -- without this they never load, so /dev/dma_heap/*
# never appears and userspace DMA-BUF allocators (libcamera, gstreamer, GPU
# stacks) fail with 'Could not open any dma-buf provider'.
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/dma-heaps.conf <<'EOF2'
system_heap
cma_heap
EOF2

# The dma-heap driver's devnode() callback only sets the device path, not a
# mode, so /dev/dma_heap/* nodes get the kernel's own restrictive default
# (root-only) instead of a udev-assigned one -- and unlike video4linux/sound/
# drm, there's no packaged udev rule granting group or uaccess permission on
# them at all (only /dev/udmabuf, a different node, has one).
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-dma-heap.rules <<'EOF2'
SUBSYSTEM==\"dma_heap\", GROUP=\"video\", MODE=\"0660\"
SUBSYSTEM==\"dma_heap\", TAG+=\"uaccess\"
EOF2

echo '[+] Updating apt sources...'
apt-get update
apt-get install -y u-boot-menu u-boot-tools initramfs-tools linux-base

if [[ \"\${KERNEL_TYPE}\" == stock ]]; then
    echo '[+] Installing headers for DKMS (stock ISO kernel)...'
    apt-get install -y dkms linux-headers-generic || apt-get install -y dkms linux-headers-arm64 || true

    if compgen -G '/tmp/rk3588-debs/*.deb' > /dev/null; then
        echo '[+] Installing RK3588 board/camera packages...'
        # DKMS may fail to build under qemu/foreign chroot; sources still
        # register and AUTOINSTALL on first boot with real headers.
        dpkg -i /tmp/rk3588-debs/*.deb || apt-get -f install -y || true
        rm -rf /tmp/rk3588-debs
    fi
else
    if compgen -G '/tmp/kernel-debs/*.deb' > /dev/null; then
        echo '[+] Installing custom kernel debs...'
        dpkg -i /tmp/kernel-debs/*.deb || apt-get -f install -y
        rm -rf /tmp/kernel-debs
    fi
fi

if [[ -d /etc/gdm3 ]]; then
    echo '[+] Preparing GNOME Initial Setup...'
    rm -rf /var/lib/AccountsService/users/*
    rm -rf /var/lib/gnome-initial-setup
    mkdir -p /var/lib/gnome-initial-setup
    touch /var/lib/gnome-initial-setup/force-new-user
    sed -i '/AutomaticLogin/d' /etc/gdm3/custom.conf || true
    sed -i '/AutomaticLoginEnable/d' /etc/gdm3/custom.conf || true
fi

: > /etc/machine-id
mkdir -p /var/lib/dbus
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

update-initramfs -u -k all || true
"

teardown_chroot_mounts "${ROOTFS_DIR}"

echo "[+] Restoring resolv.conf for systemd-resolved..."
rm -f "${ROOTFS_DIR}/etc/resolv.conf"
if [[ -e "${ROOTFS_DIR}/run/systemd/resolve/stub-resolv.conf" ]] || [[ -d "${ROOTFS_DIR}/lib/systemd" ]]; then
    ln -sf ../run/systemd/resolve/stub-resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
    rm -f "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"
fi

# =========================
# 5. Compress result
# =========================
echo "[+] Compressing to tar..."
# --one-file-system: teardown_chroot_mounts only unmounts the top-level
# proc/sys/dev/run binds, not everything --rbind recursively dragged in under
# them (e.g. the host's cgroup2/debugfs/tracefs, or OrbStack's /dev/.lxc
# proc+sysfs snapshot). Those are on a different device than the rootfs, so
# -one-file-system skips them instead of archiving unreadable pseudo-files.
tar --one-file-system -czf "${TARBALL}" -C "${ROOTFS_DIR}" .
echo "[✓] Rootfs: ${TARBALL}"
