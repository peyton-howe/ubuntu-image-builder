#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

ROOT_DIR=$(pwd)

if [[ -z ${UBOOT_RULES_TARGET} ]]; then
    echo "Error: UBOOT_CONFIG is not set"
    # Source board-specific configuration
    if [[ -f "${ROOT_DIR}/configs/boards/${BOARD}.sh" ]]; then
        source "${ROOT_DIR}/configs/boards/${BOARD}.sh"
    else
        echo "Warning: No board config found for ${BOARD}"
        exit
    fi
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build/u-boot && cd build/u-boot

if [ ! -d u-boot ]; then
    git clone --depth=1 --progress -b v2026.04 https://github.com/u-boot/u-boot.git
fi
if [ ! -d rkbin ]; then
    git clone --depth=1 --progress https://github.com/rockchip-linux/rkbin.git
fi

cd u-boot

# Apply board-specific patches if present
if [[ "${BOARD}" == "orangepi-5b" ]] && [ -f "${ROOT_DIR}/patches/0001-Add-Orange-Pi-5b-defconfig.patch" ]; then
    git apply "${ROOT_DIR}/patches/0001-Add-Orange-Pi-5b-defconfig.patch" || true
fi

make clean
make CROSS_COMPILE=aarch64-linux-gnu- \
     ROCKCHIP_TPL=../rkbin/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.19.bin \
     BL31=../rkbin/bin/rk35/rk3588_bl31_v1.51.elf \
     "${UBOOT_RULES_TARGET}" all -j"$(nproc)"

cp u-boot-rockchip.bin ..

