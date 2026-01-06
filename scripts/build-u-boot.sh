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
mkdir -p build && cd build
mkdir -p u-boot && cd u-boot

git clone --depth=1 --progress -b v2026.01 https://github.com/u-boot/u-boot.git
git clone --depth=1 --progress https://github.com/rockchip-linux/rkbin.git

cd u-boot

git apply "${ROOT_DIR}/patches/0001-Add-Orange-Pi-5b-defconfig.patch"

make clean
make CROSS_COMPILE=aarch64-linux-gnu- \
     ROCKCHIP_TPL=../rkbin/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.19.bin \
     BL31=../rkbin/bin/rk35/rk3588_bl31_v1.51.elf \
     ${UBOOT_RULES_TARGET} all -j${nproc}  

# cp idbloader.img ..
# cp u-boot.itb ..
cp u-boot-rockchip.bin ..

