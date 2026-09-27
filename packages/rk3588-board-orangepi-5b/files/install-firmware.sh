#!/usr/bin/env bash
# Copy mainline-oriented AP6275P WiFi/BT firmware into the package staging dir.
# Uses overlay/firmware (a local Armbian firmware checkout) when present;
# otherwise sparse-fetches just the AP6275P files from armbian/firmware.
set -euo pipefail
OVERLAY="${1:?}"
DEST="${2:?}"
WORK="${3:?}"

FW_URL="${FW_URL:-https://github.com/armbian/firmware.git}"
FILES=(
  brcm/brcmfmac43752-pcie.bin
  brcm/brcmfmac43752-pcie.clm_blob
  brcm/BCM4362A2.hcd
  ap6275p/nvram_AP6275P.txt
)

fw="${OVERLAY}/firmware"
if [[ ! -d ${fw} ]]; then
  fw="${WORK}/armbian-firmware"
  if [[ ! -d ${fw}/.git ]]; then
    rm -rf "${fw}"
    git clone -q --depth 1 --filter=blob:none --no-checkout "${FW_URL}" "${fw}"
    git -C "${fw}" sparse-checkout set --no-cone "${FILES[@]/#//}"
    git -C "${fw}" checkout -q
  fi
fi

mkdir -p "${DEST}/lib/firmware/brcm"
install -m 0644 "${fw}/brcm/brcmfmac43752-pcie.bin" "${DEST}/lib/firmware/brcm/"
install -m 0644 "${fw}/brcm/brcmfmac43752-pcie.clm_blob" "${DEST}/lib/firmware/brcm/"
# Upstream brcmfmac wants the module's calibrated nvram under its own name.
install -m 0644 "${fw}/ap6275p/nvram_AP6275P.txt" "${DEST}/lib/firmware/brcm/brcmfmac43752-pcie.txt"
# hci_bcm requests brcm/<chip>.hcd; AP6275P's BT half reports as BCM4362A2.
install -m 0644 "${fw}/brcm/BCM4362A2.hcd" "${DEST}/lib/firmware/brcm/"
