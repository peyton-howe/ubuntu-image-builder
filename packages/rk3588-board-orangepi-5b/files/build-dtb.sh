#!/usr/bin/env bash
# Build rk3588s-orangepi-5b.dtb with our board changes (AP6275P WiFi on
# pcie2x1l2, Bluetooth on uart9) for stock Ubuntu kernels, whose own 5B DTB
# lacks them. Those changes live in the rk3588s-orangepi-5b.dts hunk of
# patches/kernel/mainline/0006; they edit the base DTS rather than add an
# overlay, and Ubuntu's DTBs carry no __symbols__, so ship a whole DTB.
#
# Only the rockchip DTS and dt-bindings headers are fetched (sparse clone).
set -euo pipefail

PATCH="${1:?patch file}"
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
git -C "${src}" checkout -q -- "${DTS}"
git -C "${src}" apply --include="${DTS}" "${PATCH}"
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
echo "Built ${OUT} from ${DTS_KERNEL_REF} + $(basename "${PATCH}") (5B hunk) + local fixups"
