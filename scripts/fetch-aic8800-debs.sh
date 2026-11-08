#!/bin/bash
# Download Radxa's prebuilt AIC8800 .debs into build/debs/, pinned by release
# asset and checked against their SHA-256: aic8800-usb-dkms (the Wi-Fi and
# Bluetooth driver, built by DKMS on the board) and the aic8800-firmware it
# depends on. The ROCK 5C image installs both. Safe to run repeatedly.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/build/debs"

# radxa-pkg/aic8800 release 5.0+git20260123.5f7be68d-10. The API asset URL is
# used because github.com's release download URLs often time out.
VERSION="5.0+git20260123.5f7be68d-10"
# <file name>:<release asset id>:<sha256>
ASSETS=(
    "aic8800-firmware_${VERSION}_all.deb:633428182:0b7c5e229a4214f738e260cfdca45dc934abb5079890c709346577126dba94f8"
    "aic8800-usb-dkms_${VERSION}_all.deb:633428189:50f73e0113c7fbc41502a7d5740b98d001a662df57ef0c0dceca5cb9a9503e13"
)

mkdir -p "${OUT_DIR}"
for asset in "${ASSETS[@]}"; do
    IFS=: read -r file id sha256 <<< "${asset}"
    if [[ -f ${OUT_DIR}/${file} ]] && echo "${sha256}  ${OUT_DIR}/${file}" | sha256sum -c --quiet - 2>/dev/null; then
        continue
    fi
    echo "[+] Downloading ${file}"
    tmp="$(mktemp "${OUT_DIR}/.${file}.XXXXXX")"
    trap 'rm -f "${tmp}"' EXIT
    curl -fsSL --retry 5 --retry-all-errors -H 'Accept: application/octet-stream' \
        -o "${tmp}" "https://api.github.com/repos/radxa-pkg/aic8800/releases/assets/${id}"
    echo "${sha256}  ${tmp}" | sha256sum -c --quiet - \
        || { echo "Error: ${file} does not match the pinned SHA-256"; exit 1; }
    mv -f "${tmp}" "${OUT_DIR}/${file}"
    trap - EXIT
done
