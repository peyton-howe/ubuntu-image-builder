#!/usr/bin/env bash
# Build this board's camera port overlays (files/ports/*.dtso) into OUT.
# They are compiled against the dt-bindings headers of the same kernel the
# board DTS comes from, so the constants match the base DTB.
#
# Only the dt-bindings headers are needed (sparse clone, shared with
# build-dtb.sh through WORK).
set -euo pipefail

OUT="${1:?output directory}"
WORK="${2:?work dir}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DTS_KERNEL_REF="${DTS_KERNEL_REF:-v7.3-rc4}"
DTS_KERNEL_URL="${DTS_KERNEL_URL:-https://github.com/torvalds/linux.git}"

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

mkdir -p "${OUT}"
for dtso in "${HERE}"/ports/*.dtso; do
    name="$(basename "${dtso}" .dtso)"
    gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P \
        -I "${src}/include" "${dtso}" \
        | dtc -q -@ -I dts -O dtb -o "${OUT}/${name}.dtbo" -
    echo "Built ${OUT}/${name}.dtbo"
done
