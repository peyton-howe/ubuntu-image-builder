#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run ./build.sh (it uses a user namespace) or sudo $0"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
# shellcheck source=/dev/null
source scripts/common.sh
REPO_ROOT="$(pwd)"
mkdir -p build/kernel && cd build/kernel

if compgen -G "linux-image-*.deb" > /dev/null; then
    echo "already built kernel, exiting"
    exit 0
fi

# shellcheck source=/dev/null
if [[ -n ${RELEASE} ]]; then
    source "../../configs/releases/${RELEASE}.sh"
fi

# shellcheck disable=SC2046
export $(dpkg-architecture -aarm64)
export CROSS_COMPILE=aarch64-linux-gnu-
export LANG=C

KERNEL_TYPE=${KERNEL_TYPE:-vendor}
require_cmds make git gcc aarch64-linux-gnu-gcc

if [[ "${KERNEL_TYPE}" == "mainline" ]]; then
    MAINLINE_KERNEL_REPO=${MAINLINE_KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}

    latest_linux_stable_tag() {
        git ls-remote --tags --refs "${1}" 'v*' \
            | awk '{print $2}' \
            | sed 's#refs/tags/##' \
            | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' \
            | sort -V \
            | tail -1
    }

    if [[ -z ${MAINLINE_KERNEL_BRANCH} ]]; then
        echo "[+] Resolving latest linux-stable tag (no -rc)..."
        MAINLINE_KERNEL_BRANCH="$(latest_linux_stable_tag "${MAINLINE_KERNEL_REPO}")"
        if [[ -z ${MAINLINE_KERNEL_BRANCH} ]]; then
            echo "Error: could not determine latest linux-stable tag from ${MAINLINE_KERNEL_REPO}"
            exit 1
        fi
    fi
    echo "[+] Mainline kernel: ${MAINLINE_KERNEL_BRANCH} from ${MAINLINE_KERNEL_REPO}"

    require_cmds make git bc bison flex gcc rsync python3 \
        aarch64-linux-gnu-gcc dpkg-buildpackage

    SRC_DIR="$(pwd)/linux-mainline"
    BUILD_DIR="$(pwd)/linux-mainline-build"

    if [ -d "${SRC_DIR}/.git" ]; then
        origin_url="$(git -C "${SRC_DIR}" remote get-url origin 2>/dev/null || true)"
        if [[ "${origin_url}" != "${MAINLINE_KERNEL_REPO}" ]]; then
            echo "[+] Kernel tree origin changed (${origin_url} -> ${MAINLINE_KERNEL_REPO}), recloning..."
            rm -rf "${SRC_DIR}"
        fi
    fi

    if [ -d "${SRC_DIR}/.git" ]; then
        git -C "${SRC_DIR}" fetch --depth=1 origin tag "${MAINLINE_KERNEL_BRANCH}"
        git -C "${SRC_DIR}" checkout -f "${MAINLINE_KERNEL_BRANCH}"
        # checkout -f only resets tracked files; it leaves untracked ones (like
        # new files a previous patch run created via git apply) in place. Without
        # this, reapplying a patch that adds a file fails with "already exists in
        # working directory" even though it's really just stale debris from last
        # time, not an upstream conflict.
        git -C "${SRC_DIR}" clean -fdx
    else
        rm -rf "${SRC_DIR}"
        git clone --progress --depth=1 -b "${MAINLINE_KERNEL_BRANCH}" \
            "${MAINLINE_KERNEL_REPO}" "${SRC_DIR}"
    fi

    SERIES="${REPO_ROOT}/patches/kernel/mainline/series"
    if [[ -f "${SERIES}" ]]; then
        echo "[+] Applying mainline camera patches from ${SERIES}"
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ -z ${line} || ${line} == \#* ]] && continue
            patch="${REPO_ROOT}/patches/kernel/mainline/${line}"
            if [[ ! -f ${patch} ]]; then
                echo "Error: missing patch ${patch}"
                exit 1
            fi
            echo "[+] Applying ${line}..."
            git -C "${SRC_DIR}" apply --whitespace=nowarn "${patch}"
        done < "${SERIES}"
    fi

    mkdir -p "${BUILD_DIR}"

    # Base config — mainline arm64 uses defconfig, not rockchip_defconfig
    make -C "${SRC_DIR}" O="${BUILD_DIR}" \
        ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
        defconfig

    # Ubuntu / systemd requirements
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable CONFIG_MEMCG \
        --enable CONFIG_BPF_SYSCALL \
        --enable CONFIG_CGROUP_BPF \
        --module CONFIG_BINFMT_MISC \
        --enable CONFIG_FW_LOADER_COMPRESS \
        --enable CONFIG_FW_LOADER_COMPRESS_ZSTD

    # Filesystems
    # LZO and XATTR support are needed for snapd's own squashfs-backed snaps
    # (ships by default on Ubuntu desktop) -- without them the kernel can't
    # decompress LZO-compressed snaps or read their xattrs, and snapd retries
    # the failed mount on a timer forever ("Filesystem uses lzo compression.
    # This is not supported" / "Xattrs in filesystem, these will be ignored").
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable CONFIG_SQUASHFS \
        --enable CONFIG_SQUASHFS_XZ \
        --enable CONFIG_SQUASHFS_LZO \
        --enable CONFIG_SQUASHFS_XATTR \
        --enable CONFIG_OVERLAY_FS \
        --module CONFIG_XFS_FS \
        --module CONFIG_EROFS_FS \
        --module CONFIG_F2FS_FS \
        --module CONFIG_EXFAT_FS \
        --module CONFIG_ISO9660_FS

    # Wireless — Broadcom (AP6275P on Orange Pi 5 / 5B) and Realtek (RTL8852BE)
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable CONFIG_WLAN \
        --enable CONFIG_WLAN_VENDOR_BROADCOM \
        --module CONFIG_BRCMUTIL \
        --module CONFIG_BRCMFMAC \
        --enable CONFIG_BRCMFMAC_PROTO_BCDC \
        --enable CONFIG_BRCMFMAC_PROTO_MSGBUF \
        --enable CONFIG_BRCMFMAC_USB \
        --enable CONFIG_BRCMFMAC_PCIE \
        --enable CONFIG_WLAN_VENDOR_REALTEK \
        --module CONFIG_RTW89 \
        --module CONFIG_RTW89_CORE \
        --module CONFIG_RTW89_PCI \
        --module CONFIG_RTW89_8825B \
        --module CONFIG_RTW89_8852BE

    # V4L2 / media framework — gate symbols and streaming infrastructure
    # These are "depends on" gates; drivers are silently skipped without them
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable CONFIG_MEDIA_SUPPORT \
        --enable CONFIG_MEDIA_CAMERA_SUPPORT \
        --enable CONFIG_MEDIA_CONTROLLER \
        --enable CONFIG_VIDEO_DEV \
        --enable CONFIG_VIDEO_V4L2_SUBDEV_API \
        --enable CONFIG_V4L_PLATFORM_DRIVERS \
        --enable CONFIG_V4L_MEM2MEM_DRIVERS \
        --enable CONFIG_V4L2_FWNODE \
        --enable CONFIG_V4L2_MEM2MEM_DEV \
        --enable CONFIG_VIDEOBUF2_DMA_CONTIG \
        --enable CONFIG_VIDEOBUF2_DMA_SG \
        --enable CONFIG_VIDEOBUF2_VMALLOC \
        --module CONFIG_V4L2_ISP

    # Rockchip media platform — MIPI PHY, CIF capture, ISP2, RGA 2D engine
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable CONFIG_PHY_ROCKCHIP_INNO_CSIDPHY \
        --module CONFIG_PHY_ROCKCHIP_SAMSUNG_DCPHY \
        --enable CONFIG_VIDEO_DW_MIPI_CSI2RX \
        --enable CONFIG_GENERIC_PHY_MIPI_DPHY \
        --enable CONFIG_UDMABUF \
        --module CONFIG_VIDEO_ROCKCHIP_CIF \
        --module VIDEO_ROCKCHIP_ISP2 \
        --module CONFIG_VIDEO_ROCKCHIP_RGA

    # Camera sensors
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --module CONFIG_VIDEO_IMX219 \
        --module CONFIG_VIDEO_IMX415 \
        --module CONFIG_VIDEO_IMX708

    # GPU and display — Panthor (Mali G610 CSF on RK3588), Rockchip VOP2/HDMI pipeline
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --module CONFIG_DRM_PANTHOR \
        --module CONFIG_DRM_ROCKCHIP \
        --module CONFIG_PHY_ROCKCHIP_SAMSUNG_HDPTX \
        --module CONFIG_ROCKCHIP_LVDS \
        --module CONFIG_DW_HDMI

    # NPU accelerator
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable CONFIG_DRM_ACCEL \
        --module CONFIG_DRM_ACCEL_ROCKET

    # Debug / test drivers (VKMS, vivid, V4L test framework)
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable CONFIG_DYNAMIC_DEBUG \
        --enable CONFIG_WATCHDOG_SYSFS \
        --enable CONFIG_PM_DEBUG \
        --module CONFIG_DRM_VKMS \
        --module CONFIG_VIDEO_VIVID \
        --enable CONFIG_V4L_TEST_DRIVERS \
        --enable CONFIG_MEDIA_TEST_SUPPORT

    # Resolve any new symbol dependencies introduced by the overrides
    make -C "${SRC_DIR}" O="${BUILD_DIR}" \
        ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
        olddefconfig

    # Build and produce .deb packages in build/kernel/
    # Output lands in ${BUILD_DIR}/.. = build/kernel/ (standard bindeb-pkg behaviour)
    make -C "${SRC_DIR}" O="${BUILD_DIR}" \
        ARCH=arm64 \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CC=aarch64-linux-gnu-gcc \
        KBUILD_IMAGE=arch/arm64/boot/Image \
        KBUILD_DEBARCH=arm64 \
        LOCALVERSION=-mainline-rk3588 \
        KDEB_PKGVERSION=1 \
        KDEB_COMPRESS=xz \
        DPKG_FLAGS=-d \
        -j"$(nproc)" \
        bindeb-pkg
else
    export KERNEL_BRANCH=dev-6.1
    export CC=aarch64-linux-gnu-gcc

    if [ -d linux-rockchip ]; then
        git -C linux-rockchip pull || true
    else
        git clone --progress --depth=1 -b "${KERNEL_BRANCH}" https://github.com/peyton-howe/linux-rockchip.git linux-rockchip
    fi

    cd linux-rockchip
    git checkout "${KERNEL_BRANCH}"

    fakeroot debian/rules clean binary-headers binary-rockchip do_mainline_build=true
fi