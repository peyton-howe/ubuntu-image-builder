#!/usr/bin/env bash
# Put locally built camera packages into build/debs/: rk3588-camera-overlays and
# rk3588-camera-dkms, and libcamera built for the Ubuntu release being built.
# This is for trying packages that are not published to the apt repository yet
# (the images otherwise install them from it, see setup-camera-apt.sh). Point
# RK3588_CAMERA_DEBS_DIR at the directories holding them, colon separated, for
# example the build output of a local rk3588-cameras checkout:
#   RK3588_CAMERA_DEBS_DIR=~/rk3588-cameras/build/debs:~/rk3588-cameras/build/libcamera/stonking
#
# Usage: use-local-camera-debs.sh <release>
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=camera-apt.conf
source "${REPO_ROOT}/scripts/camera-apt.conf"
# shellcheck source=common.sh
source "${REPO_ROOT}/scripts/common.sh"

RELEASE="${1:?release (questing, resolute, stonking)}"
OUT_DIR="${REPO_ROOT}/build/debs"
mkdir -p "${OUT_DIR}"

# The package names to install, and the file name each is found under: the
# architecture-independent ones by name, the libcamera ones by the release in
# their version.
declare -a names=()
read -r -a names <<< "$(camera_packages)"

pattern_for() {
    case "$1" in
        rk3588-camera-*) echo "$1_*_all.deb" ;;
        *) echo "$1_*~${RELEASE}_*.deb" ;;
    esac
}

# Newest first-match among file names read from stdin.
newest() { sort -V | tail -1; }

use_local_debs() {
    local name pattern found dir candidates
    local -a dirs
    IFS=: read -r -a dirs <<< "${RK3588_CAMERA_DEBS_DIR}"
    for name in "${names[@]}"; do
        pattern="$(pattern_for "${name}")"
        candidates=""
        for dir in "${dirs[@]}"; do
            # shellcheck disable=SC2086
            candidates+="$(compgen -G "${dir}/${pattern}" || true)"$'\n'
        done
        found="$(printf '%s' "${candidates}" | sed '/^$/d' | newest)"
        if [[ -z ${found} ]]; then
            handle_missing "${name}"
            continue
        fi
        rm -f "${OUT_DIR}/${name}_"*.deb
        cp -v "${found}" "${OUT_DIR}/"
    done
}

# libcamera is built per release; an image for a release without a build still
# works, it just has no libcamera. The other packages are required.
handle_missing() {
    case "$1" in
        rk3588-camera-*)
            echo "Error: no $1 package found" >&2
            exit 1 ;;
        *)
            echo "Warning: no $1 build for ${RELEASE}; the image will not include it" >&2 ;;
    esac
}

[[ -n ${RK3588_CAMERA_DEBS_DIR:-} ]] || { echo "Error: RK3588_CAMERA_DEBS_DIR is not set" >&2; exit 1; }
echo "[+] Camera packages from ${RK3588_CAMERA_DEBS_DIR}"
use_local_debs
