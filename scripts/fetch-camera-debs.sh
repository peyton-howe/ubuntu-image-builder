#!/usr/bin/env bash
# Put the prebuilt camera packages into build/debs/: rk3588-camera-overlays and
# rk3588-camera-dkms, and libcamera built for the Ubuntu release being built. They come from the rk3588-cameras repository
# (https://github.com/peyton-howe/rk3588-cameras); see scripts/camera-debs.conf
# for the pinned release. Safe to run repeatedly.
#
# Usage: fetch-camera-debs.sh <release>
#
# To use packages that are not released yet, point RK3588_CAMERA_DEBS_DIR at
# the directories holding them (colon separated), for example the build
# output of a local rk3588-cameras checkout:
#   RK3588_CAMERA_DEBS_DIR=~/rk3588-cameras/build/debs:~/rk3588-cameras/build/libcamera/resolute
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=camera-debs.conf
source "${REPO_ROOT}/scripts/camera-debs.conf"
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

fetch_from_dirs() {
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

fetch_from_release() {
    [[ -n ${CAMERA_TAG} && -n ${CAMERA_SUMS_SHA256} ]] || {
        echo "Error: no camera release is pinned in scripts/camera-debs.conf." >&2
        echo "       Set RK3588_CAMERA_DEBS_DIR to use locally built packages." >&2
        exit 1
    }
    command -v python3 >/dev/null || { echo "Error: python3 is needed to read the release" >&2; exit 1; }
    local api="https://api.github.com/repos/${CAMERA_REPO}" tmp assets sums name pattern file id sha
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' RETURN

    curl -fsSL --retry 5 --retry-all-errors "${api}/releases/tags/${CAMERA_TAG}" -o "${tmp}/release.json"
    # "<asset name> <asset id>" per line.
    assets="$(python3 -I -c '
import json, sys
for a in json.load(open(sys.argv[1]))["assets"]:
    print(a["name"], a["id"])' "${tmp}/release.json")"

    asset_id() { awk -v n="$1" '$1 == n { print $2 }' <<< "${assets}"; }
    download() { # asset id, destination
        curl -fsSL --retry 5 --retry-all-errors -H 'Accept: application/octet-stream' \
            -o "$2" "${api}/releases/assets/$1"
    }

    id="$(asset_id SHA256SUMS)"
    [[ -n ${id} ]] || { echo "Error: release ${CAMERA_TAG} has no SHA256SUMS asset" >&2; exit 1; }
    download "${id}" "${tmp}/SHA256SUMS"
    echo "${CAMERA_SUMS_SHA256}  ${tmp}/SHA256SUMS" | sha256sum -c --quiet - \
        || { echo "Error: SHA256SUMS of ${CAMERA_TAG} does not match the pinned hash" >&2; exit 1; }
    sums="${tmp}/SHA256SUMS"

    for name in "${names[@]}"; do
        pattern="$(pattern_for "${name}")"
        # shellcheck disable=SC2254
        file="$(awk '{ print $2 }' "${sums}" | sed 's/^\*//' | while read -r f; do
            case "${f}" in ${pattern}) echo "${f}" ;; esac
        done | newest)"
        if [[ -z ${file} ]]; then
            handle_missing "${name}"
            continue
        fi
        sha="$(awk -v f="${file}" '{ n = $2; sub(/^\*/, "", n); if (n == f) print $1 }' "${sums}")"
        if [[ -f ${OUT_DIR}/${file} ]] && echo "${sha}  ${OUT_DIR}/${file}" | sha256sum -c --quiet - 2>/dev/null; then
            continue
        fi
        echo "[+] Downloading ${file}"
        id="$(asset_id "${file}")"
        [[ -n ${id} ]] || { echo "Error: ${file} is in SHA256SUMS but not a release asset" >&2; exit 1; }
        download "${id}" "${tmp}/${file}"
        echo "${sha}  ${tmp}/${file}" | sha256sum -c --quiet - \
            || { echo "Error: ${file} does not match SHA256SUMS" >&2; exit 1; }
        rm -f "${OUT_DIR}/${name}_"*.deb
        mv -f "${tmp}/${file}" "${OUT_DIR}/${file}"
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

if [[ -n ${RK3588_CAMERA_DEBS_DIR:-} ]]; then
    echo "[+] Camera packages from ${RK3588_CAMERA_DEBS_DIR}"
    fetch_from_dirs
else
    echo "[+] Camera packages from ${CAMERA_REPO} ${CAMERA_TAG:-<unpinned>}"
    fetch_from_release
fi
