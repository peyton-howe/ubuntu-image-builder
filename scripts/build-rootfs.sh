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

# The extracted rootfs directory is what build-image.sh copies into the image.
# The stamp is written last, so an interrupted build leaves no stamp and the
# next run starts over. A shared tarball (no board package) is reused: this
# script installs the requested board's deb into it instead of repeating the
# ISO download and apt.
ROOTFS_STAMP="${RELEASE}-${FLAVOR}.done"
ROOTFS_DIR="${RELEASE}-${FLAVOR}"
TARBALL="$(rootfs_tarball_name)"
KERNEL_TYPE="${KERNEL_TYPE:-stock}"
BOARD_PKG="$(board_support_package "${BOARD:-}")"
DEBS_DIR="${ROOT_DIR}/build/debs"

# Install BOARD's package into a rootfs that was built with no board. The
# board package postinst rebuilds the initramfs.
install_board_into_shared_rootfs() {
    local pkg fetched
    if [[ -z ${BOARD_PKG} ]]; then
        echo "Error: no board support package mapping for BOARD=${BOARD:-unset}"
        exit 1
    fi
    if ! deb_is_current "${BOARD_PKG}"; then
        echo "Error: ${BOARD_PKG} $(package_version "${BOARD_PKG}") not in ${DEBS_DIR}; run ./scripts/build-debs.sh ${BOARD_PKG} first"
        exit 1
    fi
    mkdir -p "${ROOTFS_DIR}/tmp/rk3588-debs"
    cp -v "${DEBS_DIR}/${BOARD_PKG}_$(package_version "${BOARD_PKG}")_"*.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
    fetched="$(board_fetched_debs "${BOARD}")"
    if [[ -n ${fetched} ]]; then
        "${ROOT_DIR}/scripts/fetch-aic8800-debs.sh"
        for pkg in ${fetched}; do
            if ! compgen -G "${DEBS_DIR}/${pkg}_"*.deb > /dev/null; then
                echo "Error: ${pkg} not in ${DEBS_DIR}"
                exit 1
            fi
            cp -v "${DEBS_DIR}/${pkg}_"*.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
        done
    fi

    rm -f "${ROOTFS_DIR}/etc/resolv.conf"
    tee "${ROOTFS_DIR}/etc/resolv.conf" >/dev/null <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    if [[ "$(uname -m)" != "aarch64" ]]; then
        cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"
    fi
    prepare_chroot_mounts "${ROOTFS_DIR}"
    chroot "${ROOTFS_DIR}" /bin/bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
BOARD_PKG='${BOARD_PKG}'
echo '[+] Installing '\${BOARD_PKG}' into the shared rootfs...'
dpkg -i /tmp/rk3588-debs/*.deb || apt-get -f install -y
rm -rf /tmp/rk3588-debs
if ! dpkg-query -W -f='\${Status}' \${BOARD_PKG} 2>/dev/null | grep -q 'install ok installed'; then
    echo \"Error: \${BOARD_PKG} did not install\" >&2
    exit 1
fi
"
    teardown_chroot_mounts "${ROOTFS_DIR}"
    if [[ "$(uname -m)" != "aarch64" ]]; then
        rm -f "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"
    fi
    rm -f "${ROOTFS_DIR}/etc/resolv.conf"
    if [[ -e "${ROOTFS_DIR}/run/systemd/resolve/stub-resolv.conf" ]] || [[ -d "${ROOTFS_DIR}/lib/systemd" ]]; then
        ln -sf ../run/systemd/resolve/stub-resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
    fi
}

# Archive the shared tree. The ISO is removed first: the archive is a second
# full copy, and a runner does not have room for the ISO, the tree, and the
# tarball together. The extracted tree is removed after the archive is in
# place; image jobs extract the archive again.
pack_shared_rootfs_tarball() {
    local iso
    shopt -s nullglob
    for iso in *.iso; do
        rm -f "${iso}"
    done
    shopt -u nullglob
    rm -f SHA256SUMS
    if mountpoint -q iso-mnt 2>/dev/null; then
        umount iso-mnt || true
    fi
    rm -rf iso-mnt
    echo "[+] Packing shared rootfs ${TARBALL}"
    rm -f "${TARBALL}" "${TARBALL}.partial"
    # -T0 uses every core. A partial name keeps a killed pack from looking done.
    set -o pipefail
    tar -cf - "${ROOTFS_DIR}" "${ROOTFS_STAMP}" | xz -T0 -c > "${TARBALL}.partial"
    set +o pipefail
    mv -f "${TARBALL}.partial" "${TARBALL}"
    rm -rf "${ROOTFS_DIR}"
    echo "[✓] Shared rootfs: $(pwd)/${TARBALL}"
}

if [[ -z ${BOARD} && -f ${TARBALL} ]]; then
    echo "[+] Shared rootfs tarball present: ${TARBALL}"
    exit 0
fi

if rootfs_is_current "${ROOTFS_STAMP}" && [[ -d ${ROOTFS_DIR} ]]; then
    echo "[+] Rootfs already built for $(rootfs_stamp_id): ${RELEASE}-${FLAVOR}"
    if [[ -z ${BOARD} && ! -f ${TARBALL} ]]; then
        pack_shared_rootfs_tarball
    fi
    exit 0
fi

# A board image with the release tarball available starts from that archive
# instead of the ISO. A stale archive (camera package versions changed) falls
# through and is rebuilt.
if [[ -n ${BOARD} && -f ${TARBALL} ]]; then
    if [[ -d ${ROOTFS_DIR} ]] && ! rootfs_shared_is_current "${ROOTFS_STAMP}"; then
        echo "[+] Replacing rootfs built for $(cat "${ROOTFS_STAMP}" 2>/dev/null || echo unknown)"
        rm -rf "${ROOTFS_DIR}"
        rm -f "${ROOTFS_STAMP}"
    fi
    if [[ ! -d ${ROOTFS_DIR} ]]; then
        echo "[+] Extracting shared rootfs ${TARBALL}"
        tar -xJf "${TARBALL}"
    fi
    if rootfs_shared_is_current "${ROOTFS_STAMP}"; then
        install_board_into_shared_rootfs
        rootfs_stamp_id > "${ROOTFS_STAMP}"
        # The image pack needs the extracted tree, not a second copy of it.
        rm -f "${TARBALL}"
        echo "[✓] Rootfs: $(pwd)/${ROOTFS_DIR}"
        exit 0
    fi
    if rootfs_is_current "${ROOTFS_STAMP}" && [[ -d ${ROOTFS_DIR} ]]; then
        rm -f "${TARBALL}"
        echo "[+] Rootfs already built for $(rootfs_stamp_id): ${RELEASE}-${FLAVOR}"
        exit 0
    fi
    echo "[+] Shared rootfs ${TARBALL} does not match this checkout; rebuilding from the ISO"
    rm -rf "${ROOTFS_DIR}"
    rm -f "${ROOTFS_STAMP}" "${TARBALL}"
fi

if [[ -f ${ROOTFS_STAMP} ]]; then
    echo "[+] Rootfs was built for $(cat "${ROOTFS_STAMP}"), need $(rootfs_stamp_id); rebuilding"
fi
rm -f "${ROOTFS_STAMP}"

if [[ "${FLAVOR}" == "desktop" ]]; then
    ISO_URL="${UBUNTU_DESKTOP_ISO_URL:?Set UBUNTU_DESKTOP_ISO_URL in configs/releases/${RELEASE}.sh}"
    SHA256SUMS_URL="${UBUNTU_DESKTOP_SHA256SUMS_URL:-${UBUNTU_SHA256SUMS_URL:-}}"
else
    ISO_URL="${UBUNTU_SERVER_ISO_URL:?Set UBUNTU_SERVER_ISO_URL in configs/releases/${RELEASE}.sh}"
    SHA256SUMS_URL="${UBUNTU_SERVER_SHA256SUMS_URL:-${UBUNTU_SHA256SUMS_URL:-}}"
fi

ISO_NAME="$(basename "${ISO_URL}")"
ISO_PATH="$(pwd)/${ISO_NAME}"
ISO_MNT="$(pwd)/iso-mnt"
KERNEL_DIR="${ROOT_DIR}/build/kernel"

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

download_iso() {
    echo "[+] Downloading ${ISO_NAME}..."
    if command -v wget >/dev/null; then
        wget -c --progress=dot:giga -O "${ISO_PATH}" "${ISO_URL}"
    else
        curl -L --continue-at - -o "${ISO_PATH}" "${ISO_URL}"
    fi
}

verify_iso() {
    grep " ${ISO_NAME}$\| \*${ISO_NAME}$" SHA256SUMS | sha256sum -c -
}

if [[ -n "${SHA256SUMS_URL}" ]]; then
    wget -q -O SHA256SUMS "${SHA256SUMS_URL}"
    if [[ -f ${ISO_PATH} ]] && verify_iso >/dev/null 2>&1; then
        echo "[+] ${ISO_NAME} already downloaded and matches SHA256SUMS"
    else
        download_iso
        echo "[+] Verifying SHA256..."
        if ! verify_iso; then
            # Daily ISOs get respun in place; resuming appends the new image
            # onto the old one. Start over once from scratch.
            echo "[+] Checksum mismatch (ISO respun upstream?), re-downloading from scratch..."
            rm -f "${ISO_PATH}"
            download_iso
            verify_iso
        fi
    fi
else
    download_iso
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
    for pkg in $(stock_packages); do
        if ! deb_is_current "${pkg}"; then
            echo "Error: ${pkg} $(package_version "${pkg}") not in ${DEBS_DIR}; run ./scripts/build-debs.sh first"
            exit 1
        fi
    done
    cp -v "${DEBS_DIR}/rk3588-camera-overlays_$(package_version "rk3588-camera-overlays")_"*.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
    cp -v "${DEBS_DIR}/rk3588-camera-dkms_$(package_version "rk3588-camera-dkms")_"*.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
    if [[ -n ${BOARD_PKG} ]]; then
        cp -v "${DEBS_DIR}/${BOARD_PKG}_$(package_version "${BOARD_PKG}")_"*.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
    elif [[ -n ${BOARD} ]]; then
        echo "Warning: no board support package mapping for BOARD=${BOARD}"
    fi
    if [[ -n $(board_fetched_debs "${BOARD:-}") ]]; then
        "${ROOT_DIR}/scripts/fetch-aic8800-debs.sh"
        for pkg in $(board_fetched_debs "${BOARD:-}"); do
            cp -v "${DEBS_DIR}/${pkg}_"*_all.deb "${ROOTFS_DIR}/tmp/rk3588-debs/"
        done
    fi
else
    echo "[+] Custom kernel path (${KERNEL_TYPE}): staging kernel debs from ${KERNEL_DIR}"
    if compgen -G "${KERNEL_DIR}/*.deb" > /dev/null; then
        cp "${KERNEL_DIR}"/*.deb "${ROOTFS_DIR}/tmp/kernel-debs/"
    fi
fi

prepare_chroot_mounts "${ROOTFS_DIR}"

# Ubuntu 25.10+ → dracut; older → initramfs-tools (board packages support both).
if release_uses_dracut; then
    INITRAMFS_PKG=dracut
else
    INITRAMFS_PKG=initramfs-tools
fi
echo "[+] Initramfs generator for ${RELEASE} (${RELASE_VERSION:-unknown}): ${INITRAMFS_PKG}"

# =========================
# 4. Configure rootfs inside chroot
# =========================
chroot "${ROOTFS_DIR}" /bin/bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
KERNEL_TYPE='${KERNEL_TYPE}'
BOARD_PKG='${BOARD_PKG}'
INITRAMFS_PKG='${INITRAMFS_PKG}'

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
# Ubuntu 25.10+ defaults to dracut (Conflicts: initramfs-tools). Older
# releases keep initramfs-tools. Board packages ship hooks for both.
apt-get install -y u-boot-menu u-boot-tools linux-base ${INITRAMFS_PKG}

if [[ \"\${KERNEL_TYPE}\" == stock ]]; then
    echo '[+] Installing headers for DKMS (stock ISO kernel)...'
    apt-get install -y dkms
    # Headers must match the ISO's kernel, not the archive's newest one
    # (linux-headers-generic), or DKMS has nothing to build against when a
    # daily ISO lags the archive.
    for kver in \$(ls /lib/modules); do
        apt-get install -y linux-headers-\${kver} \\
            || echo \"Warning: no linux-headers-\${kver} in the archive; DKMS modules won't build for it\" >&2
    done

    if compgen -G '/tmp/rk3588-debs/*.deb' > /dev/null; then
        echo '[+] Installing RK3588 board/camera packages...'
        # DKMS may fail to build under qemu/foreign chroot; sources still
        # register and AUTOINSTALL on first boot with real headers.
        dpkg -i /tmp/rk3588-debs/*.deb || apt-get -f install -y || true
        rm -rf /tmp/rk3588-debs
        # The board package is what makes the image bootable (kernel unwrap,
        # initramfs MMC modules, u-boot defaults); don't let the tolerance
        # above hide it failing to install.
        if [[ -n \${BOARD_PKG} ]] && ! dpkg-query -W -f='\${Status}' \${BOARD_PKG} 2>/dev/null | grep -q 'install ok installed'; then
            echo \"Error: \${BOARD_PKG} did not install\" >&2
            exit 1
        fi
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

rootfs_stamp_id > "${ROOTFS_STAMP}"
if [[ -z ${BOARD} ]]; then
    pack_shared_rootfs_tarball
else
    echo "[✓] Rootfs: $(pwd)/${ROOTFS_DIR}"
fi
