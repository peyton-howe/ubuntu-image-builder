# shellcheck shell=bash

reexec_as_userns_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if [ "${BUILDSH_USERNS:-}" = 1 ]; then
        echo "Error: still not uid 0 after unshare."
        echo "Enable unprivileged user namespaces, or run with sudo."
        exit 1
    fi
    if ! command -v unshare >/dev/null; then
        echo "Error: unshare not found (util-linux). Install it or run with sudo."
        exit 1
    fi
    echo "[+] Re-executing in a user namespace (no sudo)..."
    export BUILDSH_USERNS=1
    # --pid --mount-proc: inherited host /proc is locked to init_user_ns and
    # cannot be bind-mounted into the chroot ("bad superblock on /proc").
    exec unshare --map-root-user --mount --pid --fork --mount-proc -- \
        "$(readlink -f -- "$0")" "$@"
}

# User-ns CAP_SYS_ADMIN cannot mount on a host-owned superblock (e.g. /home).
# Bind the tree onto itself first so stacked mounts (proc/sys/dev) are allowed.
prepare_chroot_mounts() {
    local root="$1"
    mkdir -p "${root}/proc" "${root}/sys" "${root}/dev" "${root}/run"

    __chroot_self_bind=""
    if ! findmnt -n "${root}" >/dev/null 2>&1; then
        mount --bind "${root}" "${root}"
        mount --make-private "${root}" 2>/dev/null || true
        __chroot_self_bind="${root}"
    fi

    if ! mountpoint -q "${root}/proc"; then
        if ! mount -t proc -o nosuid,noexec,nodev proc "${root}/proc" 2>/dev/null; then
            mount --rbind /proc "${root}/proc"
        fi
    fi
    if ! mountpoint -q "${root}/sys"; then
        mount --rbind /sys "${root}/sys"
        mount --make-rslave "${root}/sys" 2>/dev/null || true
    fi
    if ! mountpoint -q "${root}/dev"; then
        mount --rbind /dev "${root}/dev"
        mount --make-rslave "${root}/dev" 2>/dev/null || true
    fi
    if ! mountpoint -q "${root}/run"; then
        mount --rbind /run "${root}/run"
        mount --make-rslave "${root}/run" 2>/dev/null || true
    fi
}

teardown_chroot_mounts() {
    local root="$1"
    umount -lf "${root}/proc" 2>/dev/null || true
    umount -lf "${root}/sys" 2>/dev/null || true
    umount -lf "${root}/dev" 2>/dev/null || true
    umount -lf "${root}/run" 2>/dev/null || true
    if [ -n "${__chroot_self_bind:-}" ]; then
        umount -lf "${__chroot_self_bind}" 2>/dev/null || true
        __chroot_self_bind=""
    fi
}

require_cmds() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Error: missing host commands: ${missing[*]}"
        echo "Install them once with apt, then re-run ./build.sh (no sudo needed for the build itself)."
        exit 1
    fi
}

# Map BOARD → rk3588-board-* package name (empty if unknown).
board_support_package() {
    case "${1:-}" in
        orangepi-5) echo "rk3588-board-orangepi-5" ;;
        orangepi-5b) echo "rk3588-board-orangepi-5b" ;;
        rock-5b-plus) echo "rk3588-board-rock-5b-plus" ;;
        *) echo "" ;;
    esac
}

# True when we keep the ISO's kernel and install our board/camera debs.
is_stock_kernel() {
    [[ "${KERNEL_TYPE:-stock}" == "stock" ]]
}
