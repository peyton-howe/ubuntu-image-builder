#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run ./build.sh (it uses a user namespace) or sudo $0"
    exit 1
fi

ROOT_DIR=$(pwd)

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

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
# shellcheck source=/dev/null
source scripts/common.sh
require_cmds make git aarch64-linux-gnu-gcc

OUT_BIN="$(uboot_bin_path "${BOARD}")"
mkdir -p build/u-boot "$(dirname "${OUT_BIN}")"
cd build/u-boot

if [ ! -d u-boot ]; then
    git clone --depth=1 --progress -b v2026.07 https://github.com/u-boot/u-boot.git
fi
if [ ! -d rkbin ]; then
    git clone --depth=1 --progress https://github.com/rockchip-linux/rkbin.git
fi

cd u-boot

# Board-specific patches on the shared source tree: apply for 5B, reverse
# for every other board so a previous 5B build does not leave the defconfig
# behind.
OPI5B_PATCH="${ROOT_DIR}/patches/0001-Add-Orange-Pi-5b-defconfig.patch"
if [[ -f ${OPI5B_PATCH} ]]; then
    if [[ ${BOARD} == "orangepi-5b" ]]; then
        if ! git apply --reverse --check "${OPI5B_PATCH}" 2>/dev/null; then
            echo "[+] Applying Orange Pi 5B u-boot patch..."
            git apply "${OPI5B_PATCH}"
        else
            echo "[+] Orange Pi 5B u-boot patch already applied, skipping."
        fi
    else
        if git apply --reverse --check "${OPI5B_PATCH}" 2>/dev/null; then
            echo "[+] Reverting Orange Pi 5B u-boot patch for ${BOARD}..."
            git apply --reverse "${OPI5B_PATCH}"
        fi
    fi
fi

make clean
make CROSS_COMPILE=aarch64-linux-gnu- \
     ROCKCHIP_TPL=../rkbin/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.24.bin \
     BL31=../rkbin/bin/rk35/rk3588_bl31_v1.56.elf \
     "${UBOOT_RULES_TARGET}" all -j"$(nproc)"

cp -f u-boot-rockchip.bin "${ROOT_DIR}/${OUT_BIN}"
echo "[+] Installed ${OUT_BIN}"
