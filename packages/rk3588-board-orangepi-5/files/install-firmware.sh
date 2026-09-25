#!/usr/bin/env bash
# Copy mainline-oriented AP6275P WiFi firmware into the package staging dir.
set -euo pipefail
OVERLAY="${1:?}"
DEST="${2:?}"
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
