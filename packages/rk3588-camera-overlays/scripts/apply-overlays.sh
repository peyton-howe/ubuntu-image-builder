#!/usr/bin/env bash
# Merge /etc/rk3588-camera/overlays.conf into /etc/default/u-boot and refresh
# the extlinux menu. Preserves any overlays already listed in U_BOOT_FDT_OVERLAYS.
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

if [[ -z ${RK3588_CAMERA_OVERLAYS:-} ]]; then
    echo "RK3588_CAMERA_OVERLAYS empty; overlays installed but not enabled"
    exit 0
fi

paths=()
for name in ${RK3588_CAMERA_OVERLAYS}; do
    name="${name%.dtbo}"
    f="${OVERLAY_DIR}/${name}.dtbo"
    if [[ ! -f ${f} ]]; then
        echo "WARNING: missing overlay ${f}" >&2
        continue
    fi
    paths+=("${f}")
done

if [[ ${#paths[@]} -eq 0 ]]; then
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

merged=()
for item in ${existing} "${paths[@]}"; do
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

echo "Enabled overlays: ${merged[*]}"
