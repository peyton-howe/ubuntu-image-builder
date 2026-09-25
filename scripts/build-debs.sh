#!/usr/bin/env bash
# Build all packages under packages/rk3588-* into build/debs/
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
# shellcheck source=/dev/null
source scripts/common.sh

REPO_ROOT="$(pwd)"
OUT_DIR="${REPO_ROOT}/build/debs"
mkdir -p "${OUT_DIR}"

require_cmds dpkg-buildpackage

PACKAGES=(
    rk3588-camera-overlays
    rk3588-camera-dkms
    rk3588-board-orangepi-5
    rk3588-board-orangepi-5b
    rk3588-board-rock-5b-plus
)

if [[ $# -gt 0 ]]; then
    PACKAGES=("$@")
fi

for name in "${PACKAGES[@]}"; do
    src="${REPO_ROOT}/packages/${name}"
    if [[ ! -d ${src}/debian ]]; then
        echo "Error: missing package tree ${src}"
        exit 1
    fi
    echo "[+] Building ${name}..."
    (
        cd "${src}"
        # native packages: binary + no orig tarball dance
        dpkg-buildpackage -us -uc -b --host-arch arm64 || dpkg-buildpackage -us -uc -b
    )
    # dpkg-buildpackage drops .deb one level above the package dir
    mv -v "${REPO_ROOT}/packages/${name}_"*.deb "${OUT_DIR}/" 2>/dev/null || true
    mv -v "${REPO_ROOT}/packages/${name}_"*.buildinfo "${OUT_DIR}/" 2>/dev/null || true
    mv -v "${REPO_ROOT}/packages/${name}_"*.changes "${OUT_DIR}/" 2>/dev/null || true
done

echo "[✓] Packages in ${OUT_DIR}:"
ls -la "${OUT_DIR}"/*.deb 2>/dev/null || echo "(no .deb produced — check build deps)"
