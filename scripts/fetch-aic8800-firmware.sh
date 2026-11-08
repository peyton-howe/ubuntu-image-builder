#!/bin/bash
# Download Radxa's aic8800-firmware .deb into build/debs/, pinned by release
# asset and checked against its SHA-256. The ROCK 5C image installs it next to
# rk3588-aic8800-dkms, which depends on it. Safe to run repeatedly.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/build/debs"

# radxa-pkg/aic8800 release 5.0+git20260123.5f7be68d-10. The API asset URL is
# used because github.com's release download URLs often time out.
VERSION="5.0+git20260123.5f7be68d-10"
ASSET_ID=633428182
SHA256="0b7c5e229a4214f738e260cfdca45dc934abb5079890c709346577126dba94f8"
FILE="aic8800-firmware_${VERSION}_all.deb"

mkdir -p "${OUT_DIR}"
if [[ -f ${OUT_DIR}/${FILE} ]] && echo "${SHA256}  ${OUT_DIR}/${FILE}" | sha256sum -c --quiet - 2>/dev/null; then
    exit 0
fi

echo "[+] Downloading ${FILE}"
tmp="$(mktemp "${OUT_DIR}/.${FILE}.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
curl -fsSL --retry 5 --retry-all-errors -H 'Accept: application/octet-stream' \
    -o "${tmp}" "https://api.github.com/repos/radxa-pkg/aic8800/releases/assets/${ASSET_ID}"
echo "${SHA256}  ${tmp}" | sha256sum -c --quiet - \
    || { echo "Error: ${FILE} does not match the pinned SHA-256"; exit 1; }
mv -f "${tmp}" "${OUT_DIR}/${FILE}"
trap - EXIT
