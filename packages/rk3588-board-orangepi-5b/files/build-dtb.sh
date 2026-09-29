#!/usr/bin/env bash
# Build rk3588s-orangepi-5b.dtb with our board changes for stock Ubuntu
# kernels, whose own 5B DTB lacks them:
#   0006: rk3588s-orangepi-5b.dts hunk (AP6275P WiFi on pcie2x1l2, BT on uart9)
#   0002: rk3588-base.dtsi hunk (disabled ISP nodes the camera overlays enable)
# They edit base DTS files rather than add overlays, and Ubuntu's DTBs carry
# no __symbols__, so ship a whole DTB (built with -@ so overlays can apply).
#
# Only the rockchip DTS and dt-bindings headers are fetched (sparse clone).
set -euo pipefail

PATCH_DIR="${1:?kernel patch dir}"
OUT="${2:?output dtb}"
WORK="${3:?work dir}"
# Upstream ref matching the Ubuntu kernel's DTS (7.3.0-* is built from 7.3-rc).
DTS_KERNEL_REF="${DTS_KERNEL_REF:-v7.3-rc4}"
# git.kernel.org ignores partial-clone filters (full ~300MB fetch); the GitHub
# mirror honours them, so this pulls ~16MB.
DTS_KERNEL_URL="${DTS_KERNEL_URL:-https://github.com/torvalds/linux.git}"
DTS=arch/arm64/boot/dts/rockchip/rk3588s-orangepi-5b.dts

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
# patch -> the one file whose hunk we take from it
declare -A HUNKS=(
    [0006-arm64-dts-rockchip-imx708-camera-overlays.patch]="${DTS}"
    [0002-media-rockchip-rkisp2.patch]="${ROCKCHIP}/rk3588-base.dtsi"
)
for patch in "${!HUNKS[@]}"; do
    git -C "${src}" checkout -q -- "${HUNKS[$patch]}"
    git -C "${src}" apply --include="${HUNKS[$patch]}" "${PATCH_DIR}/${patch}"
done
# Board-package-only fixups layered on top of the 0006 hunk.
for frag in "$(dirname "$0")"/rk3588s-orangepi-5b-*.dtsi; do
    cp "${frag}" "${src}/arch/arm64/boot/dts/rockchip/"
    echo "#include \"$(basename "${frag}")\"" >> "${src}/${DTS}"
done

mkdir -p "$(dirname "${OUT}")"
gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "${src}/include" -I "${src}/arch/arm64/boot/dts/rockchip" \
    "${src}/${DTS}" \
    | dtc -q -@ -I dts -O dtb -o "${OUT}" -
echo "Built ${OUT} from ${DTS_KERNEL_REF} + DTS hunks of ${!HUNKS[*]} + local fixups"
