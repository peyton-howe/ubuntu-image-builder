#!/usr/bin/env bash
# Sync /etc/rk3588-camera/overlays.conf into /etc/default/u-boot and refresh
# the extlinux menu. overlays.conf is the full list of camera overlays:
# entries already in U_BOOT_FDT_OVERLAYS that come from this package are
# replaced; other overlays (board GPU, etc.) are kept.
set -euo pipefail

CONF=/etc/rk3588-camera/overlays.conf
UBOOT_DEFAULT=/etc/default/u-boot
OVERLAY_DIR=/usr/share/rk3588-camera/overlays

if [[ ! -f ${CONF} ]]; then
    echo "No ${CONF}; nothing to apply"
    exit 0
fi

# shellcheck disable=SC1090
source "${CONF}"

paths=()
for name in ${RK3588_CAMERA_OVERLAYS:-}; do
    name="${name%.dtbo}"
    f="${OVERLAY_DIR}/${name}.dtbo"
    if [[ ! -f ${f} ]]; then
        echo "WARNING: missing overlay ${f}" >&2
        continue
    fi
    paths+=("${f}")
done

if [[ -n ${RK3588_CAMERA_OVERLAYS:-} && ${#paths[@]} -eq 0 ]]; then
    echo "No valid overlays to enable" >&2
    exit 1
fi

mkdir -p "$(dirname "${UBOOT_DEFAULT}")"
touch "${UBOOT_DEFAULT}"

existing=""
if grep -q '^U_BOOT_FDT_OVERLAYS=' "${UBOOT_DEFAULT}"; then
    existing="$(grep '^U_BOOT_FDT_OVERLAYS=' "${UBOOT_DEFAULT}" | tail -n1 \
        | sed 's/^U_BOOT_FDT_OVERLAYS=//; s/^"//; s/"$//')"
fi

# Drop any previously managed camera/ISP overlay; keep everything else.
kept=()
for item in ${existing}; do
    [[ -z ${item} ]] && continue
    base="$(basename "${item}")"
    base="${base%.dtbo}.dtbo"
    if [[ -f ${OVERLAY_DIR}/${base} ]]; then
        continue
    fi
    kept+=("${item}")
done

# Camera overlays reference &isp0/&isp1, which stock kernels' DTBs lack.
# rk3588-isp.dtbo adds them; U-Boot applies overlays in list order and merges
# each one's labels into the base, so it must come first when any camera
# overlay is selected.
merged=()
if [[ ${#paths[@]} -gt 0 ]]; then
    isp="${OVERLAY_DIR}/rk3588-isp.dtbo"
    [[ -f ${isp} ]] && merged+=("${isp}")
fi
for item in "${kept[@]:-}" "${paths[@]:-}"; do
    [[ -z ${item} ]] && continue
    skip=0
    for m in "${merged[@]:-}"; do
        if [[ ${m} == "${item}" ]]; then
            skip=1
            break
        fi
    done
    [[ ${skip} -eq 1 ]] && continue
    merged+=("${item}")
done

overlay_line="U_BOOT_FDT_OVERLAYS=\"${merged[*]}\""

if grep -q '^U_BOOT_FDT_OVERLAYS=' "${UBOOT_DEFAULT}"; then
    sed -i "s|^U_BOOT_FDT_OVERLAYS=.*|${overlay_line}|" "${UBOOT_DEFAULT}"
else
    printf '\n# Managed by rk3588-camera-overlays\n%s\n' "${overlay_line}" \
        >> "${UBOOT_DEFAULT}"
fi

if command -v u-boot-update >/dev/null; then
    u-boot-update
fi

if [[ ${#paths[@]} -eq 0 ]]; then
    echo "Camera overlays cleared; U_BOOT_FDT_OVERLAYS=${merged[*]:-<empty>}"
else
    echo "Enabled overlays: ${merged[*]}"
fi
