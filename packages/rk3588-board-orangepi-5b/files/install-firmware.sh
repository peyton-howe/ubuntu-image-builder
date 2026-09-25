#!/usr/bin/env bash
# Copy mainline-oriented AP6275P WiFi firmware into the package staging dir.
# Expects overlay/firmware from a local Armbian firmware checkout when present:
#   git clone --depth 1 https://github.com/armbian/firmware.git overlay/firmware
set -euo pipefail
OVERLAY="${1:?}"
DEST="${2:?}"

if [[ ! -d ${OVERLAY}/firmware ]]; then
  echo "WARNING: ${OVERLAY}/firmware missing — skipping firmware packaging"
  echo "         Clone https://github.com/armbian/firmware.git to overlay/firmware if WiFi blobs are needed"
  mkdir -p "${DEST}/usr/share/rk3588-board-orangepi-5b"
  printf 'firmware not packaged (overlay/firmware absent)\n' \
    > "${DEST}/usr/share/rk3588-board-orangepi-5b/firmware-status.txt"
  exit 0
fi

mkdir -p "${DEST}/lib/firmware/brcm" "${DEST}/lib/firmware/ap6275p"
if [[ -f ${OVERLAY}/firmware/brcm/brcmfmac43752-pcie.bin ]]; then
  cp "${OVERLAY}/firmware/brcm/brcmfmac43752-pcie.bin" "${DEST}/lib/firmware/brcm/"
  cp "${OVERLAY}/firmware/brcm/brcmfmac43752-pcie.clm_blob" "${DEST}/lib/firmware/brcm/"
fi
if [[ -f ${OVERLAY}/firmware/ap6275p/nvram_AP6275P.txt ]]; then
  cp "${OVERLAY}/firmware/ap6275p/nvram_AP6275P.txt" \
     "${DEST}/lib/firmware/brcm/brcmfmac43752-pcie.txt"
  cp -a "${OVERLAY}/firmware/ap6275p/." "${DEST}/lib/firmware/ap6275p/"
fi
