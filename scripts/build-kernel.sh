#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build/kernel && cd build/kernel

if [[ -z ${RELEASE} ]]; then
    echo "Error: RELEASE is not set"
    exit 1
fi

if compgen -G "linux-image-*.deb" > /dev/null; then
    echo "already built kernel, exiting"
    exit 0
fi

# shellcheck source=/dev/null
source "../../configs/releases/${RELEASE}.sh"

# shellcheck disable=SC2046
export $(dpkg-architecture -aarm64)
export CROSS_COMPILE=aarch64-linux-gnu-
export LANG=C

KERNEL_TYPE=${KERNEL_TYPE:-vendor}

if [[ "${KERNEL_TYPE}" == "mainline" ]]; then
    MAINLINE_KERNEL_REPO=${MAINLINE_KERNEL_REPO:-https://git.ideasonboard.com/epaul/linux}
    MAINLINE_KERNEL_BRANCH=${MAINLINE_KERNEL_BRANCH:-epaul/v7.0/rk3588/rkisp2/upstream}

    # Host build dependencies required by dpkg-buildpackage (called by bindeb-pkg)
    apt-get install -y \
        bc bison flex \
        libdw-dev libelf-dev libssl-dev \
        dwarves rsync swig python3-dev \
        gnutls-dev python3-pyelftools cpio

    SRC_DIR="$(pwd)/linux-mainline"
    BUILD_DIR="$(pwd)/linux-mainline-build"

    if [ -d "${SRC_DIR}" ]; then
        git -C "${SRC_DIR}" pull || true
    else
        git clone --progress --depth=1 -b "${MAINLINE_KERNEL_BRANCH}" "${MAINLINE_KERNEL_REPO}" "${SRC_DIR}"
    fi

    # rkisp2 Kconfig is missing 'select V4L2_ISP' — modpost fails without it
    # (rkisp1 has this select; rkisp2 doesn't — V4L2_ISP is a hidden tristate
    #  so olddefconfig resets it to n unless something selects it)
    RKISP2_KCONFIG="${SRC_DIR}/drivers/media/platform/rockchip/rkisp2/Kconfig"
    if ! grep -q "select V4L2_ISP" "${RKISP2_KCONFIG}"; then
        sed -i '/select GENERIC_PHY_MIPI_DPHY/a \\tselect V4L2_ISP' "${RKISP2_KCONFIG}"
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
        --module CONFIG_BINFMT_MISC

    # Filesystems
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --enable CONFIG_SQUASHFS \
        --enable CONFIG_SQUASHFS_XZ \
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
        --enable CONFIG_GENERIC_PHY_MIPI_DPHY \
        --enable CONFIG_UDMABUF \
        --module CONFIG_VIDEO_ROCKCHIP_CIF \
        --module CONFIG_VIDEO_ROCKCHIP_ISP2 \
        --module CONFIG_VIDEO_ROCKCHIP_RGA

    # Camera sensors
    "${SRC_DIR}/scripts/config" --file "${BUILD_DIR}/.config" \
        --module CONFIG_VIDEO_IMX219 \
        --module CONFIG_VIDEO_IMX415 \
        --module CONFIG_VIDEO_IMX708

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