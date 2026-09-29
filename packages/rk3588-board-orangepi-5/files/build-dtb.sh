#!/usr/bin/env bash
# Build rk3588s-orangepi-5.dtb for stock Ubuntu kernels. Ubuntu's copy is
# compiled without __symbols__, so camera overlays cannot apply; ship a
# whole DTB built with -@. No board DTS patches: the Orange Pi 5 has no
# onboard WiFi/BT to enable. ISP nodes come from rk3588-isp.dtbo at boot.
#
# Only the rockchip DTS and dt-bindings headers are fetched (sparse clone).
set -euo pipefail

OUT="${1:?output dtb}"
WORK="${2:?work dir}"
# Upstream ref matching the Ubuntu kernel's DTS (7.3.0-* is built from 7.3-rc).
DTS_KERNEL_REF="${DTS_KERNEL_REF:-v7.3-rc4}"
# git.kernel.org ignores partial-clone filters (full ~300MB fetch); the GitHub
# mirror honours them, so this pulls ~16MB.
DTS_KERNEL_URL="${DTS_KERNEL_URL:-https://github.com/torvalds/linux.git}"
DTS=arch/arm64/boot/dts/rockchip/rk3588s-orangepi-5.dts

src="${WORK}/linux-${DTS_KERNEL_REF}"
if [[ ! -d ${src}/.git ]]; then
    rm -rf "${src}"
    git clone -q --depth 1 --filter=blob:none --no-checkout -b "${DTS_KERNEL_REF}" \
        "${DTS_KERNEL_URL}" "${src}"
    # input.h includes linux-event-codes.h, a symlink into include/uapi.
    git -C "${src}" sparse-checkout set --no-cone \
        /arch/arm64/boot/dts/rockchip/ \
        /include/dt-bindings/ \
        /include/uapi/linux/input-event-codes.h
    git -C "${src}" checkout -q "${DTS_KERNEL_REF}"
fi
ROCKCHIP=arch/arm64/boot/dts/rockchip
# The checkout is cached in WORK; reset so a previous run's edits don't linger.
git -C "${src}" checkout -q -- "${ROCKCHIP}"

mkdir -p "$(dirname "${OUT}")"
gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "${src}/include" -I "${src}/arch/arm64/boot/dts/rockchip" \
    "${src}/${DTS}" \
    | dtc -q -@ -I dts -O dtb -o "${OUT}" -
echo "Built ${OUT} from ${DTS_KERNEL_REF} (symbols enabled)"
