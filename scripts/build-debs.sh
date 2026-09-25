#!/usr/bin/env bash
# Build packages under packages/rk3588-* into build/debs/
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
# shellcheck source=/dev/null
source scripts/common.sh

REPO_ROOT="$(pwd)"
OUT_DIR="${REPO_ROOT}/build/debs"
mkdir -p "${OUT_DIR}"

require_cmds dpkg-buildpackage dtc
# debhelper / dh_dkms are invoked by debian/rules; surface a clear error early.
if ! dpkg -s debhelper >/dev/null 2>&1; then
    echo "Error: debhelper not installed (apt install debhelper dh-dkms device-tree-compiler dpkg-dev)"
    exit 1
fi

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

produced=()
for name in "${PACKAGES[@]}"; do
    src="${REPO_ROOT}/packages/${name}"
    if [[ ! -d ${src}/debian ]]; then
        echo "Error: missing package tree ${src}"
        exit 1
    fi
    echo "[+] Building ${name}..."
    (
        cd "${src}"
        # Clean prior debian staging leftovers
        rm -rf debian/"${name}" debian/.debhelper debian/files debian/*.substvars debian/*.debhelper.log 2>/dev/null || true
        dpkg-buildpackage -us -uc -b
    )
    shopt -s nullglob
    debs=( "${REPO_ROOT}/packages/${name}_"*.deb )
    shopt -u nullglob
    if [[ ${#debs[@]} -eq 0 ]]; then
        echo "Error: dpkg-buildpackage did not produce ${name}_*.deb"
        exit 1
    fi
    for f in "${debs[@]}"; do
        mv -v "${f}" "${OUT_DIR}/"
        produced+=("$(basename "${f}")")
    done
    mv -v "${REPO_ROOT}/packages/${name}_"*.buildinfo "${OUT_DIR}/" 2>/dev/null || true
    mv -v "${REPO_ROOT}/packages/${name}_"*.changes "${OUT_DIR}/" 2>/dev/null || true
done

echo "[✓] Packages in ${OUT_DIR}:"
for f in "${produced[@]}"; do
    ls -la "${OUT_DIR}/${f}"
done
