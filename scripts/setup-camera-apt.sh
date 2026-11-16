#!/usr/bin/env bash
# Add the Tachyn Labs apt repository to a rootfs: its archive key (checked
# against the fingerprint in camera-apt.conf) and a sources entry for the
# release. The image keeps it, so `apt upgrade` updates the camera packages.
#
# Usage: setup-camera-apt.sh <rootfs dir> <release>
# Fails for a release the repository has no suite for: an image without the
# camera packages is not one we build.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=camera-apt.conf
source "${REPO_ROOT}/scripts/camera-apt.conf"
# shellcheck source=common.sh
source "${REPO_ROOT}/scripts/common.sh"

ROOTFS="${1:?rootfs directory}"
RELEASE="${2:?release (questing, resolute, stonking)}"

if ! camera_apt_has_suite "${RELEASE}"; then
    echo "Error: ${CAMERA_APT_URL} has no ${RELEASE} suite (suites: ${CAMERA_APT_SUITES})" >&2
    exit 1
fi
for tool in curl gpg; do
    command -v "${tool}" > /dev/null || { echo "Error: ${tool} is needed to set up the camera apt repository" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL --retry 5 --retry-all-errors "${CAMERA_APT_KEY_URL}" -o "${tmp}/key.gpg"
# The first fpr record is the primary key's.
fpr="$(GNUPGHOME="${tmp}" gpg --batch --show-keys --with-colons --fingerprint "${tmp}/key.gpg" 2> /dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
if [[ ${fpr} != "${CAMERA_APT_KEY_FPR}" ]]; then
    echo "Error: the key at ${CAMERA_APT_KEY_URL} has fingerprint '${fpr:-none}', expected ${CAMERA_APT_KEY_FPR}" >&2
    exit 1
fi

install -D -m 0644 "${tmp}/key.gpg" "${ROOTFS}/usr/share/keyrings/tachyn.gpg"
install -d "${ROOTFS}/etc/apt/sources.list.d"
echo "deb [signed-by=/usr/share/keyrings/tachyn.gpg] ${CAMERA_APT_URL} ${RELEASE} main" \
    > "${ROOTFS}/etc/apt/sources.list.d/tachyn.list"
echo "[+] ${CAMERA_APT_URL} ${RELEASE} added (key ${CAMERA_APT_KEY_FPR: -16})"
