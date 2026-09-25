#!/usr/bin/env bash
# ROCK 5B+ stock-ISO path: minimal stub — extend when mainline firmware set is known.
set -euo pipefail
OVERLAY="${1:?}"
DEST="${2:?}"
mkdir -p "${DEST}/usr/share/rk3588-board-rock-5b-plus"
# Placeholder so the package always ships something board-specific.
printf 'ROCK 5B+ firmware install stub (overlay=%s)\n' "${OVERLAY}" \
  > "${DEST}/usr/share/rk3588-board-rock-5b-plus/firmware-status.txt"
